import Foundation
import AppKit
import CoreGraphics
import UserNotifications
import FinderRightKit

/// 主 App 端的 IPC 请求处理器。
///
/// 这个对象由 IPCWatcher 创建，收到 IPCRequest 后路由到对应方法。
/// 所有方法都在主 App 进程（非沙箱）里执行，借用主 App 的 TCC 权限（包括 Full Disk Access）。
final class FinderRightService {

    /// 归档（压缩/解压）专用串行队列：隔离耗时 I/O 子进程任务，避免并发争抢系统 I/O
    private let archiveQueue = DispatchQueue(label: "com.finderright.app.archive", qos: .utility)

    /// 剪切/粘贴专用串行队列：确保 staging 目录与 cut-queue.json 互斥访问，绝不并发竞态
    private let cutPasteQueue = DispatchQueue(label: "com.finderright.app.cutpaste", qos: .userInitiated)

    // MARK: - 安全白名单与校验 (B5)

    // TODO: 未来可通过 NSXPCConnection + audit token 实现进程级双向严格鉴权
    /// 校验路径是否在允许的安全范围：真实用户 home、/Volumes 或系统临时目录
    private func isPathAllowed(_ rawPath: String) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).resolvingSymlinksInPath()
        let path = url.path

        let home = IPCBridge.realUserHomeDirectory.resolvingSymlinksInPath().path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path

        if path == home || path.hasPrefix(home + "/") {
            return true
        }
        if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            return true
        }
        if path == tmp || path.hasPrefix(tmp + "/") || path.hasPrefix("/private/tmp/") || path.hasPrefix("/tmp/") {
            return true
        }
        return false
    }

    /// 校验 Bundle Identifier 字符集（仅限字母、数字、点号和横线）
    private func isValidBundleId(_ bundleId: String) -> Bool {
        guard !bundleId.isEmpty, bundleId.count <= 128 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return bundleId.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 路由 IPCRequest 到具体的 handler
    func handle(_ req: IPCRequest) -> IPCResponse {
        // 1. 路径白名单校验
        let pathKeys = ["directory", "destination", "archive", "testPath"]
        for key in pathKeys {
            if let path = req.payload[key]?.stringValue {
                guard isPathAllowed(path) else {
                    serviceLog("路径越界被拦截 [key=\(key)]: \(path)")
                    return IPCResponse(id: req.id, success: false, message: "路径越界：安全策略拒绝访问 \(path)")
                }
            }
        }
        let arrayKeys = ["items", "paths"]
        for key in arrayKeys {
            if let paths = req.payload[key]?.stringArrayValue {
                for path in paths {
                    guard isPathAllowed(path) else {
                        serviceLog("路径越界被拦截 [key=\(key)]: \(path)")
                        return IPCResponse(id: req.id, success: false, message: "路径越界：安全策略拒绝访问 \(path)")
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
        let dirURL = URL(fileURLWithPath: directory)
        let fileURL = uniqueFileURL(baseName: baseName, ext: ext, in: dirURL)
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return IPCResponse(id: req.id, success: true, message: fileURL.path)
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
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
        archiveQueue.async { [weak self] in
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
                    self?.serviceLog("compressZip failed: \(msg)")
                    self?.notifyFailure(title: "压缩失败", body: "\(dest.lastPathComponent): \(msg)")
                }
            } catch {
                if let tempStage = tempStageURL {
                    try? fileManager.removeItem(at: tempStage)
                }
                self?.serviceLog("compressZip error: \(error.localizedDescription)")
                self?.notifyFailure(title: "压缩出错", body: error.localizedDescription)
            }
        }

        return IPCResponse(id: req.id, success: true, message: "已受理压缩任务，正在后台处理")
    }

    /// 发送本地通知提醒后台操作失败
    private func notifyFailure(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
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
        archiveQueue.async { [weak self] in
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

            let proc = Process()
            proc.currentDirectoryURL = dir
            if isBareGz {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
                proc.arguments = ["-kc", archive]
            } else if isBareBz2 {
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/bunzip2")
                proc.arguments = ["-kc", archive]
            } else {
                let xzCandidates = ["/opt/homebrew/bin/xz", "/usr/local/bin/xz", "/usr/bin/xz"]
                if let xzBin = xzCandidates.first(where: { fileManager.fileExists(atPath: $0) }) {
                    proc.executableURL = URL(fileURLWithPath: xzBin)
                    proc.arguments = ["-dc", archive]
                } else {
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    proc.arguments = ["-c", "import lzma, sys, shutil; shutil.copyfileobj(lzma.open(sys.argv[1]), sys.stdout.buffer)", archive]
                }
            }

            proc.standardOutput = outHandle
            let errPipe = Pipe()
            proc.standardError = errPipe

            do {
                try proc.run()
                proc.waitUntilExit()
                try? outHandle.close()

                if proc.terminationStatus == 0 {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([targetFileURL])
                    }
                    serviceLog("decompress single file succeeded: \(targetFileURL.path)")
                } else {
                    try? fileManager.removeItem(at: targetFileURL)
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    serviceLog("decompress single file failed (exit \(proc.terminationStatus)): \(errStr)")
                    notifyFailure(title: "解压失败", body: "\(url.lastPathComponent): \(errStr.isEmpty ? "退出码 \(proc.terminationStatus)" : errStr)")
                }
            } catch {
                try? outHandle.close()
                try? fileManager.removeItem(at: targetFileURL)
                serviceLog("decompress single file error: \(error.localizedDescription)")
                notifyFailure(title: "解压出错", body: "\(url.lastPathComponent): \(error.localizedDescription)")
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
            notifyFailure(title: "解压失败", body: "创建解压目录失败: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        proc.currentDirectoryURL = targetDir
        let ext = url.pathExtension.lowercased()
        if ext == "zip" {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-x", "-k", archive, targetDir.path]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xf", archive, "-C", targetDir.path]
        }

        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([targetDir])
                }
                serviceLog("decompress archive succeeded: \(targetDir.path)")
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                serviceLog("decompress archive failed (exit \(proc.terminationStatus)): \(errStr)")
                notifyFailure(title: "解压失败", body: "\(url.lastPathComponent): \(errStr.isEmpty ? "退出码 \(proc.terminationStatus)" : errStr)")
            }
        } catch {
            serviceLog("decompress archive error: \(error.localizedDescription)")
            notifyFailure(title: "解压出错", body: "\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func openTerminal(_ req: IPCRequest) -> IPCResponse {
        guard let directory = req.payload["directory"]?.stringValue,
              let bundleId = req.payload["bundleId"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "openTerminal 参数缺失")
        }

        // 针对通过命令行参数指定工作目录的终端（如 Ghostty / Alacritty / Kitty）
        if bundleId == "com.mitchellh.ghostty" {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-b", bundleId, "--args", "--working-directory=\(directory)"]
            do {
                try proc.run()
                return IPCResponse(id: req.id, success: true, message: nil)
            } catch {
                NSLog("[FinderRightService] open ghostty via cli failed: \(error)")
            }
        } else if bundleId == "org.alacritty" {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-b", bundleId, "--args", "--working-directory", directory]
            do {
                try proc.run()
                return IPCResponse(id: req.id, success: true, message: nil)
            } catch {
                NSLog("[FinderRightService] open alacritty via cli failed: \(error)")
            }
        } else if bundleId == "net.kovidgoyal.kitty" {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-b", bundleId, "--args", "--directory", directory]
            do {
                try proc.run()
                return IPCResponse(id: req.id, success: true, message: nil)
            } catch {
                NSLog("[FinderRightService] open kitty via cli failed: \(error)")
            }
        }

        // 通用方式：NSWorkspace.open 传递目录 URL（Terminal / iTerm2 / Warp 原生支持）
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

    private func openWithApp(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue,
              let bundleId = req.payload["bundleId"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "openWithApp 参数缺失")
        }
        let cliPaths = req.payload["cliFallbackPaths"]?.stringArrayValue ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let ok = NSWorkspace.shared.open(
            urls,
            withAppBundleIdentifier: bundleId,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifiers: nil
        )
        if ok { return IPCResponse(id: req.id, success: true, message: nil) }

        if let cmd = cliPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cmd)
            proc.arguments = paths
            do {
                try proc.run()
                return IPCResponse(id: req.id, success: true, message: nil)
            } catch {
                return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
            }
        }
        return IPCResponse(id: req.id, success: false, message: "无法打开 \(bundleId)，且无 CLI fallback")
    }

    private func toggleHiddenFiles(_ req: IPCRequest) -> IPCResponse {
        serviceLog("toggleHiddenFiles requested")

        // 优先通过辅助功能权限模拟 Cmd+Shift+. 快捷键，实现 Finder 窗口不重启、不闪烁即时切换
        let checkOpts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        if AXIsProcessTrustedWithOptions(checkOpts),
           let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let pid = finder.processIdentifier
            // 不 activate Finder：postToPid 直达进程事件队列，activate 会抢焦点导致菜单栏跳变卡顿

            let src = CGEventSource(stateID: .hidSystemState)
            // kVK_ANSI_Period = 0x2F (47)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x2F, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x2F, keyDown: false)
            down?.flags = [.maskCommand, .maskShift]
            up?.flags   = [.maskCommand, .maskShift]
            down?.postToPid(pid)
            up?.postToPid(pid)

            serviceLog("sent Cmd+Shift+. to Finder pid=\(pid)")
            // 等待按键事件派发并回写配置
            usleep(100_000)
            let actual = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "AppleShowAllFiles") ?? false
            SharedConfig.shared.showHiddenFiles = actual
            return IPCResponse(id: req.id, success: true, message: "toggled via CGEvent pid=\(pid)")
        }

        // 若尚未授权，主动弹窗提示用户授权辅助功能
        let promptOpts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(promptOpts)

        // 降级走 defaults 重启方案
        return toggleHiddenFilesViaDefaults(req, newValue: "toggle")
    }

    private func serviceLog(_ message: String) {
        NSLog("[FinderRightService] \(message)")
    }

    private func toggleHiddenFilesViaDefaults(_ req: IPCRequest, newValue: String) -> IPCResponse {
        let currentBool = UserDefaults(suiteName: "com.apple.finder")?.bool(forKey: "AppleShowAllFiles") ?? false
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

            let actual = (nextVal == "YES")
            SharedConfig.shared.showHiddenFiles = actual
            return IPCResponse(id: req.id, success: true, message: "set to \(nextVal), restarted Finder")
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    // MARK: - 剪切 / 粘贴（Lazy Cut 延迟剪切）

    /// 剪切队列文件路径（存储待剪切的源文件完整路径列表）
    private var cutQueueFileURL: URL {
        IPCBridge.rootDirectory.appendingPathComponent("cut-queue.json")
    }

    /// 剪切：Lazy Cut（延迟剪切）。只记录待剪切文件路径到 cut-queue.json，
    /// 不立即移动物理文件，避免跨卷拷贝撑爆磁盘和未粘贴前文件丢失假象。
    private func cutFiles(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue, !paths.isEmpty else {
            return IPCResponse(id: req.id, success: false, message: "cutFiles 参数缺失：paths")
        }

        // 收敛到 cutPasteQueue 串行队列，确保 cut-queue.json 互斥访问
        return cutPasteQueue.sync {
            let fileManager = FileManager.default

            // 过滤出实际存在的源文件路径
            let validPaths = paths.filter { fileManager.fileExists(atPath: $0) }
            guard !validPaths.isEmpty else {
                return IPCResponse(id: req.id, success: false, message: "选中的文件均不存在")
            }

            // 读取现有剪切队列并过滤掉外部已删除的文件
            var queue = (try? Data(contentsOf: cutQueueFileURL))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] }?
                .filter { fileManager.fileExists(atPath: $0) } ?? []

            // 合并并去重
            for p in validPaths {
                if !queue.contains(p) {
                    queue.append(p)
                }
            }

            do {
                try IPCBridge.ensureDirectory()
                let data = try JSONSerialization.data(withJSONObject: queue)
                try data.write(to: cutQueueFileURL, options: .atomic)
            } catch {
                return IPCResponse(id: req.id, success: false, message: "写入剪切队列失败: \(error.localizedDescription)")
            }

            return IPCResponse(id: req.id, success: true, message: "已剪切 \(validPaths.count) 个文件")
        }
    }

    private func pasteFiles(_ req: IPCRequest) -> IPCResponse {
        guard let destPath = req.payload["destination"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "pasteFiles 参数缺失：destination")
        }
        let destDir = URL(fileURLWithPath: destPath)

        // 从 IPC 共享文件快速前置检查剪切队列
        guard let data = try? Data(contentsOf: cutQueueFileURL),
              let sourcePaths = try? JSONSerialization.jsonObject(with: data) as? [String],
              !sourcePaths.isEmpty else {
            return IPCResponse(id: req.id, success: false, message: "剪切队列为空，请先剪切文件")
        }

        // 异步派发到 cutPasteQueue 串行队列，XPC 立即返回“已受理”
        cutPasteQueue.async { [weak self] in
            self?.performPaste(destDir: destDir)
        }

        return IPCResponse(id: req.id, success: true, message: "已受理粘贴请求，正在后台移动文件")
    }

    private func performPaste(destDir: URL) {
        guard let data = try? Data(contentsOf: cutQueueFileURL),
              let sourcePaths = try? JSONSerialization.jsonObject(with: data) as? [String],
              !sourcePaths.isEmpty else {
            return
        }

        let fileManager = FileManager.default
        var firstError: String?
        var pastedPaths: [URL] = []
        var failedPaths: [String] = []

        for sourcePath in sourcePaths {
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

        // 更新剪切队列：只保留未能移动成功的路径，防止队列指向已不存在的源文件
        if failedPaths.isEmpty {
            try? fileManager.removeItem(at: cutQueueFileURL)
        } else if let updatedData = try? JSONSerialization.data(withJSONObject: failedPaths) {
            try? updatedData.write(to: cutQueueFileURL, options: .atomic)
        }

        if !pastedPaths.isEmpty {
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting(pastedPaths)
            }
        }

        if let err = firstError {
            serviceLog("pasteFiles completed with error: \(err)")
            notifyFailure(title: "粘贴文件失败", body: err)
        } else {
            serviceLog("pasteFiles succeeded: moved \(pastedPaths.count) items to \(destDir.path)")
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
