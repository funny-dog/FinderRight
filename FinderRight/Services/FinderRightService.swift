import Foundation
import AppKit
import CoreGraphics
import FinderRightKit

/// 通知文案的本地化辅助：中文做 key，主 App 的 en.lproj/Localizable.strings 提供英文。
/// 放文件级而非实例方法，便于在 [weak self] 闭包内直接调用。
private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

/// 主 App 端的 IPC 请求处理器。
///
/// 这个对象由 IPCWatcher 创建，收到 IPCRequest 后路由到对应方法。
/// 所有方法都在主 App 进程（非沙箱）里执行，借用主 App 的 TCC 权限（包括 Full Disk Access）。
final class FinderRightService {

    /// 归档（压缩/解压）专用串行队列：隔离耗时 I/O 子进程任务，避免并发争抢系统 I/O。
    ///
    /// 必须为类型级（static）：本类同时被 IPCWatcher 与 ServicesProvider 各实例化一次，
    /// 若用实例属性则两个实例各持一条队列，排队互斥形同虚设。
    private static let archiveQueue = DispatchQueue(label: "com.finderright.app.archive", qos: .utility)

    /// 剪切队列临界区：只保护 `cut-queue.json` 的读-改-写与取消代次，**绝不承载物理移动**。
    /// 必须类型级共享，否则「云盘 Services 剪切 + 普通目录 IPC 粘贴」并发时
    /// cut-queue.json 的读-改-写没有互斥保护。
    private static let cutPasteQueue = DispatchQueue(label: "com.finderright.app.cutpaste", qos: .userInitiated)

    /// 粘贴文件移动专用串行工作队列：耗时的物理移动 I/O 在这里执行，
    /// 不再长时间占住 cutPasteQueue（否则后续 cutFiles / cancelCut 的 sync 会队头阻塞整个
    /// IPC 串行队列，扩展 10s 超时并留下孤儿 resp 文件）。
    private static let pasteQueue = DispatchQueue(
        label: "com.finderright.app.paste",
        qos: .userInitiated
    )

    /// 取消剪切代次：每次 cancelCut 自增，**只能在 cutPasteQueue 上访问**。
    ///
    /// 粘贴任务在 `takeCutQueue()` 时记下当时的代次，归还失败路径前比对：代次变了说明
    /// 用户已经点过「取消剪切」，此时必须放弃归还，否则取消会被异步的失败归还悄悄撤销
    /// （角标与「粘贴 (已剪切 N 项)」在取消之后又冒出来）。
    private static var cutCancelGeneration = 0

    // MARK: - 安全白名单与校验 (B5)

    // TODO: 未来可通过 NSXPCConnection + audit token 实现进程级双向严格鉴权
    /// 校验路径是否在允许的安全范围（真实 home、/Volumes、临时目录），且不触碰 FDA 专属数据。
    /// 规则在 Kit 的 PathAccessPolicy（可单测）；这里负责展开 ~ 与解析符号链接，
    /// 让 ~/Desktop 下指向 ~/Library/Messages 的链接按真实位置判定。
    private func isPathAllowed(_ rawPath: String, role: PathAccessPolicy.Role) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let home = IPCBridge.realUserHomeDirectory.resolvingSymlinksInPath().path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return PathAccessPolicy.isAllowed(path, role: role, home: home, temporaryDirectory: tmp)
    }

    /// 校验 Bundle Identifier 字符集（仅限字母、数字、点号和横线）
    private func isValidBundleId(_ bundleId: String) -> Bool {
        guard !bundleId.isEmpty, bundleId.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return bundleId.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 路由 IPCRequest 到具体的 handler
    func handle(_ req: IPCRequest) -> IPCResponse {
        // 1. 路径校验：
        //    - 写入/移动类 action 必须过安全白名单（可写范围仅 真实 home、/Volumes、tmp）
        //    - 只读类 action 不修改任何文件，只校验路径存在性即可。扩展的 FinderSync 只注册
        //      home 与已挂载卷，本身到不了 /Applications 这类系统目录；但 macOS Services
        //      路径（云盘场景，见 ServicesProvider）没有目录限制，可以在任意位置被调用，
        //      因此只读豁免依然必要，否则系统目录里点「打开终端 / 打开编辑器」会被静默拦截。
        let readOnlyActions: Set<String> = ["openTerminal", "openWithApp", "ping", "toggleHiddenFiles", BadgeReclaimIPC.action]
        let needsWhitelist = !readOnlyActions.contains(req.action)

        // directory / destination 是写入目标；archive / items / paths 是会被读取或移动的源
        let pathKeys: [(key: String, role: PathAccessPolicy.Role)] = [
            ("directory", .destination), ("destination", .destination), ("archive", .source), ("testPath", .source)
        ]
        for (key, role) in pathKeys {
            if let path = req.payload[key]?.stringValue {
                if needsWhitelist {
                    guard isPathAllowed(path, role: role) else {
                        serviceLog("路径越界被拦截 [key=\(key)]: \(path)")
                        return IPCResponse(id: req.id, success: false, message: "路径越界：安全策略拒绝访问 \(path)")
                    }
                } else {
                    // 只读路径仅校验存在性（防明显无效请求，不做安全边界，因为不会写入）
                    let expanded = (path as NSString).expandingTildeInPath
                    guard FileManager.default.fileExists(atPath: expanded) else {
                        serviceLog("只读路径不存在被拒绝 [key=\(key)]: \(path)")
                        return IPCResponse(id: req.id, success: false, message: "路径不存在: \(path)")
                    }
                }
            }
        }
        let arrayKeys: [(key: String, role: PathAccessPolicy.Role)] = [("items", .source), ("paths", .source)]
        for (key, role) in arrayKeys {
            if let paths = req.payload[key]?.stringArrayValue {
                for path in paths {
                    if needsWhitelist {
                        guard isPathAllowed(path, role: role) else {
                            serviceLog("路径越界被拦截 [key=\(key)]: \(path)")
                            return IPCResponse(id: req.id, success: false, message: "路径越界：安全策略拒绝访问 \(path)")
                        }
                    } else {
                        let expanded = (path as NSString).expandingTildeInPath
                        guard FileManager.default.fileExists(atPath: expanded) else {
                            serviceLog("只读路径不存在被拒绝 [key=\(key)]: \(path)")
                            return IPCResponse(id: req.id, success: false, message: "路径不存在: \(path)")
                        }
                    }
                }
            }
        }

        // 2. bundleId 字符集校验（防注入）
        if let bundleId = req.payload["bundleId"]?.stringValue {
            guard isValidBundleId(bundleId) else {
                serviceLog("非法 bundleId 被拦截: \(bundleId)")
                return IPCResponse(id: req.id, success: false, message: "非法的 bundleId: \(bundleId)")
            }
        }

        switch req.action {
        case "ping":
            return ping(req)
        case "createFile":
            return createFile(req)
        case "compressZip":
            return compressZip(req)
        case "decompress":
            return decompress(req)
        case "openTerminal":
            return openTerminal(req)
        case "openWithApp":
            return openWithApp(req)
        case "toggleHiddenFiles":
            return toggleHiddenFiles(req)
        case "cutFiles":
            return cutFiles(req)
        case "pasteFiles":
            return pasteFiles(req)
        case "cancelCut":
            return cancelCut(req)
        case BadgeReclaimIPC.action:
            return BadgeOwnershipManager.shared.handle(req)
        default:
            return IPCResponse(id: req.id, success: false, message: "未知 action: \(req.action)")
        }
    }

    // MARK: - 各 handler

    private func ping(_ req: IPCRequest) -> IPCResponse {
        let testPath = req.payload["testPath"]?.stringValue ?? "~/Pictures"
        let expanded = (testPath as NSString).expandingTildeInPath
        let canRead = (try? FileManager.default.contentsOfDirectory(atPath: expanded)) != nil
        return IPCResponse(id: req.id, success: true, message: canRead ? "fda=yes" : "fda=no")
    }

    private func createFile(_ req: IPCRequest) -> IPCResponse {
        guard let directory = req.payload["directory"]?.stringValue,
              let baseName = req.payload["baseName"]?.stringValue,
              let ext = req.payload["ext"]?.stringValue,
              let content = req.payload["content"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "createFile 参数缺失")
        }
        // 白名单只校验了 directory；baseName / ext 会直接拼进路径，含 `/` 或 `..` 时
        // 可穿越到白名单之外（如 ~/Desktop/../../../../tmp/x.txt），必须单独拦截
        guard SafeFileName.isValid(baseName: baseName, ext: ext) else {
            serviceLog("非法文件名被拦截: baseName=\(baseName) ext=\(ext)")
            return IPCResponse(id: req.id, success: false, message: "非法的文件名")
        }
        let dirURL = URL(fileURLWithPath: directory)
        let data = Data(content.utf8)
        // 查重与写入之间若恰好出现同名文件，withoutOverwriting 让写入失败而不是覆盖，换下一个序号重试
        for _ in 0..<5 {
            let fileURL = uniqueFileURL(baseName: baseName, ext: ext, in: dirURL)
            do {
                try data.write(to: fileURL, options: .withoutOverwriting)
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return IPCResponse(id: req.id, success: true, message: fileURL.path)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
            }
        }
        return IPCResponse(id: req.id, success: false, message: "目标目录同名文件冲突，请重试")
    }

    private func compressZip(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, let first = items.first else {
            return IPCResponse(id: req.id, success: false, message: "compressZip 参数缺失")
        }
        let dir = URL(fileURLWithPath: first).deletingLastPathComponent()
        let name = items.count == 1
            ? URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent
            : "Archive"
        let dest = uniqueFileURL(baseName: name, ext: "zip", in: dir)

        // 异步派发到归档专用队列，XPC 立即返回“已受理”
        Self.archiveQueue.async { [weak self] in
            let fileManager = FileManager.default
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.currentDirectoryURL = dir

            var tempStageURL: URL? = nil

            if items.count == 1 {
                let itemURL = URL(fileURLWithPath: first)
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue {
                    proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", itemURL.lastPathComponent, dest.path]
                } else {
                    proc.arguments = ["-c", "-k", "--sequesterRsrc", itemURL.lastPathComponent, dest.path]
                }
            } else {
                // 多选压缩：ditto 不支持直接传多个 source，通过同目录下零拷贝临时 staging 目录打平
                let stageName = ".finderright-stage-\(UUID().uuidString)"
                let stageURL = dir.appendingPathComponent(stageName)
                do {
                    try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: true)
                    tempStageURL = stageURL
                    for item in items {
                        let srcURL = URL(fileURLWithPath: item)
                        let targetItemURL = stageURL.appendingPathComponent(srcURL.lastPathComponent)
                        // 优先 APFS clone（零开销）
                        let cpProc = Process()
                        cpProc.executableURL = URL(fileURLWithPath: "/bin/cp")
                        cpProc.arguments = ["-cR", srcURL.path, targetItemURL.path]
                        try? cpProc.run()
                        cpProc.waitUntilExit()
                        if !fileManager.fileExists(atPath: targetItemURL.path) {
                            try? fileManager.copyItem(at: srcURL, to: targetItemURL)
                        }
                    }
                    proc.arguments = ["-c", "-k", "--sequesterRsrc", stageURL.path, dest.path]
                } catch {
                    self?.serviceLog("compressZip staging failed: \(error.localizedDescription)")
                }
            }

            do {
                try proc.run()
                proc.waitUntilExit()
                if let tempStage = tempStageURL {
                    try? fileManager.removeItem(at: tempStage)
                }

                if fileManager.fileExists(atPath: dest.path) {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                    }
                    self?.serviceLog("compressZip succeeded: \(dest.path)")
                } else {
                    let msg = "ditto 退出码: \(proc.terminationStatus)"
                    self?.serviceLog("compressZip failed: \(dest.lastPathComponent): \(msg)")
                }
            } catch {
                if let tempStage = tempStageURL {
                    try? fileManager.removeItem(at: tempStage)
                }
                self?.serviceLog("compressZip error: \(error.localizedDescription)")
            }
        }

        return IPCResponse(id: req.id, success: true, message: "已受理压缩任务，正在后台处理")
    }
    private func decompress(_ req: IPCRequest) -> IPCResponse {
        guard let archive = req.payload["archive"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "decompress 参数缺失")
        }
        let url = URL(fileURLWithPath: archive)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return IPCResponse(id: req.id, success: false, message: "压缩文件不存在: \(archive)")
        }

        // 异步派发到归档专用队列，XPC 立即返回“已受理”
        Self.archiveQueue.async { [weak self] in
            self?.performDecompress(url: url)
        }

        return IPCResponse(id: req.id, success: true, message: "已受理解压任务，正在后台处理")
    }

    private func performDecompress(url: URL) {
        let fileManager = FileManager.default
        let dir = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        let lower = filename.lowercased()
        let archive = url.path

        let isTarGz = lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
        let isTarBz2 = lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz")
        let isTarXz = lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz")
        let isBareGz = lower.hasSuffix(".gz") && !isTarGz
        let isBareBz2 = lower.hasSuffix(".bz2") && !isTarBz2
        let isBareXz = lower.hasSuffix(".xz") && !isTarXz

        // 裸 .gz / .bz2 / .xz 单文件（非 tar 归档）：bsdtar 无法识别此类单文件流，使用对应流式解压工具输出到文件
        if isBareGz || isBareBz2 || isBareXz {
            let rawTargetName = (filename as NSString).deletingPathExtension
            let rawURL = URL(fileURLWithPath: rawTargetName)
            let rawBase = rawURL.deletingPathExtension().lastPathComponent
            let rawExt = rawURL.pathExtension

            var targetFileURL = dir.appendingPathComponent(rawTargetName)
            var counter = 2
            while fileManager.fileExists(atPath: targetFileURL.path) {
                let candidateName = rawExt.isEmpty ? "\(rawBase)-\(counter)" : "\(rawBase)-\(counter).\(rawExt)"
                targetFileURL = dir.appendingPathComponent(candidateName)
                counter += 1
            }

            fileManager.createFile(atPath: targetFileURL.path, contents: nil)
            guard let outHandle = try? FileHandle(forWritingTo: targetFileURL) else {
                serviceLog("无法创建解压目标文件: \(targetFileURL.path)")
                return
            }

            let tool: (executable: String, arguments: [String])
            if isBareGz {
                tool = ("/usr/bin/gunzip", ["-kc", archive])
            } else if isBareBz2 {
                tool = ("/usr/bin/bunzip2", ["-kc", archive])
            } else if let xzBin = ["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"]
                        .first(where: { fileManager.fileExists(atPath: $0) }) {
                tool = (xzBin, ["-dc", archive])
            } else {
                tool = ("/usr/bin/python3", ["-c", "import lzma, sys, shutil; shutil.copyfileobj(lzma.open(sys.argv[1]), sys.stdout.buffer)", archive])
            }

            do {
                // ProcessRunner 先读完 stderr 再等待退出：错误输出超过管道缓冲时不会死锁
                let result = try ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: tool.executable),
                    arguments: tool.arguments,
                    currentDirectoryURL: dir,
                    standardOutput: outHandle)
                try? outHandle.close()

                if result.status == 0 {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([targetFileURL])
                    }
                    serviceLog("decompress single file succeeded: \(targetFileURL.path)")
                } else {
                    try? fileManager.removeItem(at: targetFileURL)
                    serviceLog("decompress single file failed (exit \(result.status)): \(result.stderr)")
                }
            } catch {
                try? outHandle.close()
                try? fileManager.removeItem(at: targetFileURL)
                serviceLog("decompress single file error: \(error.localizedDescription)")
            }
            return
        }

        // 归档压缩包（zip、tar、tar.gz、tar.bz2、tar.xz 等）：解压到同名新文件夹
        var baseName = url.deletingPathExtension().lastPathComponent
        if isTarGz && baseName.lowercased().hasSuffix(".tar") {
            baseName = (baseName as NSString).deletingPathExtension
        } else if isTarBz2 && baseName.lowercased().hasSuffix(".tar") {
            baseName = (baseName as NSString).deletingPathExtension
        } else if isTarXz && baseName.lowercased().hasSuffix(".tar") {
            baseName = (baseName as NSString).deletingPathExtension
        }

        var targetDir = dir.appendingPathComponent(baseName, isDirectory: true)
        var counter = 2
        while fileManager.fileExists(atPath: targetDir.path) {
            targetDir = dir.appendingPathComponent("\(baseName)-\(counter)", isDirectory: true)
            counter += 1
        }

        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            serviceLog("创建解压目录失败: \(error.localizedDescription)")
            return
        }

        let isZip = url.pathExtension.lowercased() == "zip"
        let tool: (executable: String, arguments: [String]) = isZip
            ? ("/usr/bin/ditto", ["-x", "-k", archive, targetDir.path])
            : ("/usr/bin/tar", ["-xf", archive, "-C", targetDir.path])

        do {
            // 解压 Linux rootfs / Docker 层这类 tar 时每个设备节点都会报一行错，stderr 轻易超过
            // 64KB 管道缓冲；ProcessRunner 先读后等，避免死锁卡住整条 archiveQueue
            let result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: tool.executable),
                arguments: tool.arguments,
                currentDirectoryURL: targetDir)
            if result.status == 0 {
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([targetDir])
                }
                serviceLog("decompress archive succeeded: \(targetDir.path)")
            } else {
                serviceLog("decompress archive failed (exit \(result.status)): \(result.stderr)")
                // 失败时清掉刚建的目标目录：它与单文件分支行为保持一致，
                // 否则会留下空目录，且重试解压还会生成 foo-2、foo-3 等递增残留。
                // 该目录是本函数刚 unique 出来的新目录，必不预先存在，整体删除安全。
                try? fileManager.removeItem(at: targetDir)
            }
        } catch {
            serviceLog("decompress archive error: \(error.localizedDescription)")
            try? fileManager.removeItem(at: targetDir)
        }
    }

    private func openTerminal(_ req: IPCRequest) -> IPCResponse {
        guard let directory = req.payload["directory"]?.stringValue,
              let bundleId = req.payload["bundleId"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "openTerminal 参数缺失")
        }

        // 只能用命令行参数指定工作目录的终端（Ghostty / Alacritty / Kitty）。
        //
        // 关键限制：`open --args` 的参数只在**应用冷启动**时进入 main() 的 argv（见 man open）。
        // 应用已在运行时，open 只发 reopen 事件、参数被直接丢弃 —— 实测（自建 .app 图标包，
        // 记录 argv 后长驻）：首次 --args ALPHA 生效；进程存活期间 --args BETA/GAMMA 既不产生
        // 新进程、argv 也不更新。因此这里先判断终端是否在运行，未运行才走 --args 冷启动；
        // 已在运行则落到下面的通用目录 URL 路径（至少不会用一个必然被忽略的参数假装成功）。
        if let args = Self.workingDirectoryArguments(for: bundleId, directory: directory),
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-b", bundleId, "--args"] + args
            do {
                try proc.run()
                // 不在这里 waitUntilExit：open 要等应用启动完成才返回（重终端可能上百毫秒），
                // 而本方法跑在 IPC 串行队列上。退出码只在后台记录。
                DispatchQueue.global(qos: .utility).async {
                    proc.waitUntilExit()
                    if proc.terminationStatus != 0 {
                        NSLog("[FinderRightService] openTerminal: \(bundleId) --args 退出码 \(proc.terminationStatus)")
                    } else {
                        NSLog("[FinderRightService] openTerminal: \(bundleId) 冷启动并携带工作目录参数")
                    }
                }
                return IPCResponse(id: req.id, success: true, message: nil)
            } catch {
                NSLog("[FinderRightService] openTerminal: \(bundleId) --args 启动失败: \(error)，退回目录 URL 路径")
            }
        }

        // 通用方式：NSWorkspace.open 传递目录 URL（Terminal / iTerm2 / Warp 原生支持；
        // Ghostty / Kitty 已在运行时也走这里，由各自对「打开文件夹」的处理决定是否换目录）
        let url = URL(fileURLWithPath: directory)
        let success = NSWorkspace.shared.open(
            [url],
            withAppBundleIdentifier: bundleId,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifiers: nil
        )
        return IPCResponse(id: req.id, success: success,
                           message: success ? nil : "NSWorkspace.open 返回 false")
    }

    /// 终端冷启动时用来指定工作目录的命令行参数；不需要的终端返回 nil（走通用目录 URL 路径）。
    /// 参数以数组形式直接交给 `/usr/bin/open`，不经 shell，含空格/中文的路径安全。
    private static func workingDirectoryArguments(for bundleId: String, directory: String) -> [String]? {
        switch bundleId {
        case "com.mitchellh.ghostty":
            return ["--working-directory=\(directory)"]
        case "org.alacritty":
            return ["--working-directory", directory]
        case "net.kovidgoyal.kitty":
            return ["--directory", directory]
        default:
            return nil
        }
    }

    private func openWithApp(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue,
              let bundleId = req.payload["bundleId"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "openWithApp 参数缺失")
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let ok = NSWorkspace.shared.open(
            urls,
            withAppBundleIdentifier: bundleId,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifiers: nil
        )
        // 注：不接收 IPC 传入的可执行路径回退（历史 cliFallbackPaths 已移除）——
        // 该参数从未被扩展使用，且可被执行任意二进制的伪造请求利用。
        return IPCResponse(id: req.id, success: ok,
                           message: ok ? nil : "无法通过 \(bundleId) 打开")
    }

    private func toggleHiddenFiles(_ req: IPCRequest) -> IPCResponse {
        serviceLog("toggleHiddenFiles requested")

        // 优先通过辅助功能权限模拟 Cmd+Shift+. 快捷键，实现 Finder 窗口不重启、不闪烁即时切换
        let checkOpts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        if AXIsProcessTrustedWithOptions(checkOpts),
           let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let pid = finder.processIdentifier
            // 不 activate Finder：postToPid 直达进程事件队列，activate 会抢焦点导致菜单栏跳变卡顿

            // fire-and-forget：不再跟踪/回写任何状态（菜单文案已改无状态，见 FinderSync）。
            let src = CGEventSource(stateID: .hidSystemState)
            // kVK_ANSI_Period = 0x2F (47)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x2F, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x2F, keyDown: false)
            down?.flags = [.maskCommand, .maskShift]
            up?.flags   = [.maskCommand, .maskShift]
            down?.postToPid(pid)
            up?.postToPid(pid)

            serviceLog("sent Cmd+Shift+. to Finder pid=\(pid)")
            return IPCResponse(id: req.id, success: true, message: "toggled via CGEvent pid=\(pid)")
        }

        // 未授权辅助功能：降级方案要 killall Finder，会关闭所有访达窗口、可能中断正在进行的拷贝 / 移动，
        // 不能静默执行。先立即应答扩展（避免它等满 IPC 超时），再到主线程让用户明确选择。
        DispatchQueue.main.async { [weak self] in
            self?.confirmHiddenFilesFallback(req)
        }
        return IPCResponse(id: req.id, success: true, message: "no accessibility, awaiting user confirmation")
    }

    /// 只在主线程访问：防止确认框未关闭时重复右键触发，叠出多层模态框
    private static var isConfirmingHiddenFilesFallback = false

    /// 未授权辅助功能时的三选一：重启访达并切换 / 去授权 / 取消
    private func confirmHiddenFilesFallback(_ req: IPCRequest) {
        guard !Self.isConfirmingHiddenFilesFallback else { return }
        Self.isConfirmingHiddenFilesFallback = true
        defer { Self.isConfirmingHiddenFilesFallback = false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("切换隐藏文件需要重启访达")
        alert.informativeText = L("FinderRight 尚未获得「辅助功能」权限，无法无闪烁地切换。改为重启访达会关闭所有访达窗口，并可能中断正在进行的拷贝或移动。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("重启访达并切换"))
        alert.addButton(withTitle: L("授权辅助功能…"))
        alert.addButton(withTitle: L("取消"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // defaults 读写与 killall 都会同步等待子进程，放到后台，不阻塞主线程
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let resp = self.toggleHiddenFilesViaDefaults(req, newValue: "toggle")
                self.serviceLog("toggleHiddenFiles 用户确认重启访达: \(resp.message ?? "")")
            }
        case .alertSecondButtonReturn:
            // 系统授权弹窗会把 FinderRight 加进辅助功能列表，用户只需打开开关
            let promptOpts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(promptOpts)
        default:
            serviceLog("toggleHiddenFiles 用户取消（未授权辅助功能）")
        }
    }

    private func serviceLog(_ message: String) {
        NSLog("[FinderRightService] \(message)")
    }

    private func toggleHiddenFilesViaDefaults(_ req: IPCRequest, newValue: String) -> IPCResponse {
        // 用 defaults CLI 读当前值：子进程每次冷启动读盘，绕开本进程 cfprefsd 客户端缓存
        // （UserDefaults(suiteName:) 读其他 App 的域可能命中过期缓存，导致取反后写回同值、看似没切换）
        var currentBool = false
        let readProc = Process()
        let readOut = Pipe()
        readProc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        readProc.arguments = ["read", "com.apple.finder", "AppleShowAllFiles"]
        readProc.standardOutput = readOut
        readProc.standardError = FileHandle.nullDevice
        if (try? readProc.run()) != nil {
            let data = readOut.fileHandleForReading.readDataToEndOfFile()
            readProc.waitUntilExit()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            currentBool = (s == "1" || s.lowercased() == "true" || s.lowercased() == "yes")
        }
        let nextVal = !currentBool ? "YES" : "NO"
        let writeProc = Process()
        writeProc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        writeProc.arguments = ["write", "com.apple.finder", "AppleShowAllFiles", nextVal]
        try? writeProc.run()
        writeProc.waitUntilExit()

        do {
            let killProc = Process()
            killProc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killProc.arguments = ["Finder"]
            try killProc.run()
            killProc.waitUntilExit()

            return IPCResponse(id: req.id, success: true, message: "set to \(nextVal), restarted Finder")
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    // MARK: - 剪切 / 粘贴（Lazy Cut 延迟剪切）

    /// 剪切队列存储（扩展端读取同一份文件，见 CutQueueStore）
    private let cutQueue = CutQueueStore()

    /// 剪切：Lazy Cut（延迟剪切）。只记录待剪切文件路径到 cut-queue.json，
    /// 不立即移动物理文件，避免跨卷拷贝撑爆磁盘和未粘贴前文件丢失假象。
    private func cutFiles(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue, !paths.isEmpty else {
            return IPCResponse(id: req.id, success: false, message: "cutFiles 参数缺失：paths")
        }

        // 收敛到 cutPasteQueue 串行队列，确保 cut-queue.json 互斥访问
        return Self.cutPasteQueue.sync {
            let fileManager = FileManager.default

            // 过滤出实际存在的源文件路径
            let validPaths = paths.filter { fileManager.fileExists(atPath: $0) }
            guard !validPaths.isEmpty else {
                return IPCResponse(id: req.id, success: false, message: "选中的文件均不存在")
            }

            // 读取现有剪切队列并过滤掉外部已删除的文件
            var queue = cutQueue.read().filter { fileManager.fileExists(atPath: $0) }

            // 合并并去重
            for p in validPaths {
                if !queue.contains(p) {
                    queue.append(p)
                }
            }

            do {
                try cutQueue.write(queue)
            } catch {
                return IPCResponse(id: req.id, success: false, message: "写入剪切队列失败: \(error.localizedDescription)")
            }

            return IPCResponse(id: req.id, success: true, message: "已剪切 \(validPaths.count) 个文件")
        }
    }

    /// 取消剪切：清空剪切队列。
    ///
    /// 连续剪切决策上保留「累加 / 合并」语义（不改成 Windows 的替换语义），
    /// 因此需要一个显式入口让用户清空队列、让角标消失。
    /// 注意：只能取消尚未被粘贴取走的队列。已经被 takeCutQueue() 取走、正在移动的文件
    /// 无法撤回，但代次自增会让这批任务结束后不再把失败路径归还回队列（取消必须赢）。
    private func cancelCut(_ req: IPCRequest) -> IPCResponse {
        // 与剪切/粘贴共用串行队列，避免与正在执行中的粘贴互踩 cut-queue.json
        Self.cutPasteQueue.sync {
            Self.cutCancelGeneration += 1
            cutQueue.clear()
            return IPCResponse(id: req.id, success: true, message: "已取消剪切")
        }
    }

    /// 在 cutPasteQueue 短事务中一次性取走当前剪切队列，并记录取走时的取消代次
    private func takeCutQueue() -> (paths: [String], generation: Int)? {
        Self.cutPasteQueue.sync {
            guard let paths = cutQueue.take() else { return nil }
            return (paths, Self.cutCancelGeneration)
        }
    }

    private func pasteFiles(_ req: IPCRequest) -> IPCResponse {
        guard let destPath = req.payload["destination"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "pasteFiles 参数缺失：destination")
        }
        let destDir = URL(fileURLWithPath: destPath)

        guard let taken = takeCutQueue() else {
            return IPCResponse(id: req.id, success: false, message: "剪切队列为空，请先剪切文件")
        }

        // 异步派发到独立 pasteQueue 工作队列，物理移动不阻塞 cutPasteQueue 队列
        Self.pasteQueue.async { [weak self] in
            self?.performPaste(sourcePaths: taken.paths, destDir: destDir, generation: taken.generation)
        }

        return IPCResponse(id: req.id, success: true, message: "已受理粘贴请求，正在后台移动文件")
    }

    /// 在 cutPasteQueue 内将失败路径与粘贴期间新剪切路径去重合并后归还回队列。
    /// 若期间用户点过「取消剪切」（代次变化），整批丢弃并清掉 in-flight 标记。
    private func restoreFailedCutPaths(_ failedPaths: [String], generation: Int) {
        guard !failedPaths.isEmpty else { return }
        Self.cutPasteQueue.async { [weak self] in
            guard let self else { return }
            defer { self.cutQueue.finish() }
            guard generation == Self.cutCancelGeneration else {
                self.serviceLog("取消剪切已生效，丢弃 \(failedPaths.count) 条失败路径的归还")
                return
            }
            let restored = self.cutQueue.appendUnique(failedPaths)
            self.serviceLog("粘贴失败路径已归还队列: \(failedPaths.count) 条，当前队列 \(restored.count) 条")
        }
    }

    private func performPaste(sourcePaths: [String], destDir: URL, generation: Int) {
        let fileManager = FileManager.default
        var firstError: String?
        var pastedPaths: [URL] = []
        var failedPaths: [String] = []

        for sourcePath in sourcePaths {
            // 防御性校验：cut-queue.json 是普通文件，可能被其他进程直接改写；
            // 剪切时虽已校验过白名单，粘贴执行前必须对队列内容再校验一次。
            guard isPathAllowed(sourcePath, role: .source) else {
                serviceLog("粘贴源路径越界被拦截: \(sourcePath)")
                continue
            }
            let sourceURL = URL(fileURLWithPath: sourcePath)

            // 若源文件已被外部删除或不存在，则跳过且不作为待重试项保留在队列中
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }

            // 粘贴目标目录与源文件所在目录相同 → 跳过该文件（视为无操作），不生成副本，并从队列剔除
            if sourceURL.deletingLastPathComponent().path == destDir.path {
                continue
            }

            var destURL = destDir.appendingPathComponent(sourceURL.lastPathComponent)

            // 目标已存在则自动重命名避免冲突
            if fileManager.fileExists(atPath: destURL.path) {
                let base = destURL.deletingPathExtension().lastPathComponent
                let ext  = destURL.pathExtension
                var counter = 1
                repeat {
                    let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                    destURL = destDir.appendingPathComponent(numbered)
                    counter += 1
                } while fileManager.fileExists(atPath: destURL.path)
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destURL)
                pastedPaths.append(destURL)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
                failedPaths.append(sourcePath)
            }
        }

        // 移动结束：失败路径归还回剪切队列以便用户重试（归还逻辑负责清掉 in-flight 标记）；
        // 全部成功则直接清掉标记，队列保持为空。
        if failedPaths.isEmpty {
            cutQueue.finish()
        } else {
            restoreFailedCutPaths(failedPaths, generation: generation)
        }

        if !pastedPaths.isEmpty {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting(pastedPaths)
            }
        }

        if let err = firstError {
            serviceLog("pasteFiles completed with error: \(err)")
        } else {
            serviceLog("pasteFiles succeeded: moved \(pastedPaths.count) items to \(destDir.path)")
        }
    }

    /// 主 App 启动时归还上次崩溃残留的 in-flight 队列。
    ///
    /// 粘贴开始时队列会被原子改名为 in-flight 标记；若主 App 在移动过程中被杀（崩溃、强退、
    /// 断电），标记会残留在磁盘上，这里把其中的源文件并回队列，避免用户丢失剪切状态。
    /// 只保留仍存在的源文件：已经移动成功的路径不再回到队列。
    static func recoverInflightCutQueue() {
        let restored = CutQueueStore().recover(existingOnly: true)
        if !restored.isEmpty {
            NSLog("[FinderRightService] 已恢复中断粘贴的剪切队列: \(restored.count) 条")
        }
    }

    // MARK: - Helpers

    private func uniqueFileURL(baseName: String, ext: String, in directory: URL) -> URL {
        let name = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        var url = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let numbered = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            url = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return url
    }
}
