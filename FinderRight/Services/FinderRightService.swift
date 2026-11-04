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

    /// 归档与图片处理共用串行队列：隔离耗时任务，并串行维护同一份暂存登记表。
    ///
    /// 必须为类型级（static）：本类同时被 IPCWatcher 与 ServicesProvider 各实例化一次，
    /// 若用实例属性则两个实例各持一条队列，排队互斥形同虚设。
    static let archiveQueue = DispatchQueue(label: "com.finderright.app.archive", qos: .utility)

    /// 剪切队列临界区：只保护 `cut-queue.json` 的读-改-写与取消代次，**绝不承载物理移动**。
    /// 必须类型级共享，否则「云盘 Services 剪切 + 普通目录 IPC 粘贴」并发时
    /// cut-queue.json 的读-改-写没有互斥保护。
    static let cutPasteQueue = DispatchQueue(label: "com.finderright.app.cutpaste", qos: .userInitiated)

    /// 粘贴文件移动专用串行工作队列：耗时的物理移动 I/O 在这里执行，
    /// 不再长时间占住 cutPasteQueue（否则后续 cutFiles / cancelCut 的 sync 会队头阻塞整个
    /// IPC 串行队列，扩展 10s 超时并留下孤儿 resp 文件）。
    static let pasteQueue = DispatchQueue(
        label: "com.finderright.app.paste",
        qos: .userInitiated
    )

    /// 在途的压缩 / 解压 / 粘贴 / 图片处理任务。AppDelegate 在退出前等待它们完成（见 applicationShouldTerminate）
    static let backgroundJobs = BackgroundJobs()

    /// 启动后台文件任务；退出流程已开始时返回 false，调用方应给出「正在退出」的失败结果
    static func runGuarded(on queue: DispatchQueue, work: @escaping () -> Void) -> Bool {
        backgroundJobs.run(on: queue, work)
    }

    /// 拒绝新任务时的 IPC 结果：如实告诉请求方已经退出，而不是假装已受理
    static func exitInProgressResponse(_ req: IPCRequest) -> IPCResponse {
        IPCResponse(id: req.id, success: false, message: L("FinderRight 正在退出，请稍后重试"))
    }

    /// 服务菜单等不走 IPC 的入口：拒绝新任务时同样给出提示
    static func reportExitInProgress() {
        ClipboardToast.show(message: NSLocalizedString("FinderRight 正在退出，请稍后重试", comment: "notification"), style: .failure)
    }

    /// 取消剪切代次：每次 cancelCut 自增，**只能在 cutPasteQueue 上访问**。
    ///
    /// 粘贴任务在 `takeCutQueue()` 时记下当时的代次，归还失败路径前比对：代次变了说明
    /// 用户已经点过「取消剪切」，此时必须放弃归还，否则取消会被异步的失败归还悄悄撤销
    /// （角标与「粘贴 (已剪切 N 项)」在取消之后又冒出来）。
    static var cutCancelGeneration = 0

    // MARK: - 安全白名单与校验 (B5)

    // TODO: 未来可通过 NSXPCConnection + audit token 实现进程级双向严格鉴权
    /// 校验路径是否在允许的安全范围（真实 home、/Volumes、临时目录），且不触碰 FDA 专属数据。
    /// 规则在 Kit 的 PathAccessPolicy（可单测）；这里负责展开 ~ 与解析符号链接，
    /// 让 ~/Desktop 下指向 ~/Library/Messages 的链接按真实位置判定。
    func isPathAllowed(_ rawPath: String, role: PathAccessPolicy.Role) -> Bool {
        Self.isPathAllowed(rawPath, role: role)
    }

    /// 设置页添加常用目录时也用这套规则，保证「能加进列表的目录」与「执行时放行的目录」一致
    static func isPathAllowed(_ rawPath: String, role: PathAccessPolicy.Role) -> Bool {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let path = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let home = IPCBridge.realUserHomeDirectory.resolvingSymlinksInPath().path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return PathAccessPolicy.isAllowed(path, role: role, home: home, temporaryDirectory: tmp)
    }

    /// 路由 IPCRequest 到具体的 handler
    func handle(_ req: IPCRequest) -> IPCResponse {
        // 1. 路径校验：
        //    - 写入/移动类 action 必须过安全白名单（可写范围仅 真实 home、/Volumes、tmp）
        //    - 只读类 action 不修改任何文件，只校验路径存在性即可。扩展的 FinderSync 只注册
        //      home 与已挂载卷，本身到不了 /Applications 这类系统目录；但 macOS Services
        //      路径（云盘场景，见 ServicesProvider）没有目录限制，可以在任意位置被调用，
        //      因此只读豁免依然必要，否则系统目录里点「打开终端 / 打开编辑器」会被静默拦截。
        let readOnlyActions: Set<String> = ["openTerminal", "openWithApp", "ping", "toggleHiddenFiles", BadgeReclaimIPC.action, "copyFileContent", "copyFileHash", "diskUsage", "prefetchDiskUsage", "showDiskUsageDetail", "showCutQueueDetail"]
        let needsWhitelist = !readOnlyActions.contains(req.action)

        // directory / destination 是写入目标；archive / items / paths / path 是会被读取或移动的源
        let pathKeys: [(key: String, role: PathAccessPolicy.Role)] = [
            ("directory", .destination), ("destination", .destination), ("archive", .source), ("testPath", .source), ("path", .source)
        ]
        for (key, role) in pathKeys {
            if let path = req.payload[key]?.stringValue {
                if needsWhitelist {
                    guard isPathAllowed(path, role: role) else {
                        serviceLog("路径越界被拦截 [key=\(key)]: \(path)")
                        return IPCResponse(id: req.id, success: false, message: String(format: L("路径越界：安全策略拒绝访问 %@"), path))
                    }
                } else {
                    // 只读路径仅校验存在性（防明显无效请求，不做安全边界，因为不会写入）
                    let expanded = (path as NSString).expandingTildeInPath
                    guard FileManager.default.fileExists(atPath: expanded) else {
                        serviceLog("只读路径不存在被拒绝 [key=\(key)]: \(path)")
                        return IPCResponse(id: req.id, success: false, message: String(format: L("路径不存在：%@"), path))
                    }
                }
            }
        }
        // 图片转换/缩放与哈希复制支持批量容错与逐项过滤，不因单项失效而拒绝整批
        let skipsBatchPrecheck = (req.action == "convertImage" || req.action == "scaleImage" || req.action == "copyFileHash")
        if !skipsBatchPrecheck {
            let arrayKeys: [(key: String, role: PathAccessPolicy.Role)] = [("items", .source), ("paths", .source)]
            for (key, role) in arrayKeys {
                if let paths = req.payload[key]?.stringArrayValue {
                    for path in paths {
                        if needsWhitelist {
                            guard isPathAllowed(path, role: role) else {
                                serviceLog("路径越界被拦截 [key=\(key)]: \(path)")
                                return IPCResponse(id: req.id, success: false, message: String(format: L("路径越界：安全策略拒绝访问 %@"), path))
                            }
                        } else {
                            let expanded = (path as NSString).expandingTildeInPath
                            guard FileManager.default.fileExists(atPath: expanded) else {
                                serviceLog("只读路径不存在被拒绝 [key=\(key)]: \(path)")
                                return IPCResponse(id: req.id, success: false, message: String(format: L("路径不存在：%@"), path))
                            }
                        }
                    }
                }
            }
        }

        // 2. bundleId 字符集校验（防注入）
        if let bundleId = req.payload["bundleId"]?.stringValue {
            guard BundleIdentifier.isValid(bundleId) else {
                serviceLog("非法 bundleId 被拦截: \(bundleId)")
                return IPCResponse(id: req.id, success: false, message: "非法的 bundleId: \(bundleId)")
            }
        }

        switch req.action {
        case "ping":
            return ping(req)
        case "diskUsage":
            return diskUsage(req)
        case "prefetchDiskUsage":
            return prefetchDiskUsage(req)
        case "showDiskUsageDetail":
            SharedConfig.shared.reload()
            guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.diskUsage) else {
                return IPCResponse(id: req.id, success: false, message: NSLocalizedString("此功能已关闭，请在设置中启用", comment: ""))
            }
            guard let path = req.payload["path"]?.stringValue else {
                return IPCResponse(id: req.id, success: false, message: NSLocalizedString("请选择目录", comment: ""))
            }
            DispatchQueue.main.async { DiskUsageController.shared.show(at: URL(fileURLWithPath: path)) }
            return IPCResponse(id: req.id, success: true, message: nil)
        case "showCutQueueDetail":
            SharedConfig.shared.reload()
            guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.cut) else {
                return IPCResponse(id: req.id, success: false, message: NSLocalizedString("此功能已关闭，请在设置中启用", comment: ""))
            }
            DispatchQueue.main.async { CutQueueController.shared.show() }
            return IPCResponse(id: req.id, success: true, message: nil)
        case "createFile":
            let response = createFile(req)
            if !response.success {
                RecentOperations.shared.record(OperationRecord(
                    kind: .createFile, subject: req.payload["baseName"]?.stringValue ?? L("新建文件"),
                    failure: response.message,
                    location: req.payload["directory"]?.stringValue.map { URL(fileURLWithPath: $0) }))
            }
            return response
        case "createFileFromClipboard":
            return createFileFromClipboard(req)
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
        case "transferItems":
            return transferItems(req)
        case "copyFileContent":
            return copyFileContent(req)
        case "copyProjectRelativePath", "copyDirectoryTree":
            return copyDeveloperText(req)
        case "runCustomCommand":
            return runCustomCommand(req)
        case "copyFileHash":
            return copyFileHash(req)
        case "createSymlink":
            return createSymlink(req)
        case "convertImage":
            return convertImage(req)
        case "scaleImage":
            return scaleImage(req)
        case "undoLast":
            return undoLast(req)
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

    /// 后台任务自己的计算上限。它不决定菜单等多久（那是 diskUsageResponseWait），
    /// 只决定「算到什么时候放弃」——必须给大目录留够时间，否则任务每次都被掐断，
    /// 缓存永远建不起来，表现为「大目录永远不显示大小」。
    /// 实测 ~/codes/practice（83 万文件）约 3.2 秒，这里留 30 秒上限，正常目录远用不到。
    static let diskUsageScanTimeout: TimeInterval = 30

    /// 单个请求在 IPC 上最多占用的时间（菜单侧只等 250 ms，这里与之对齐，多留一点写响应的时间）
    static let diskUsageResponseWait: TimeInterval = 0.45

    /// 结果缓存：入口是「进入目录时的预热」，右键时直接命中，才能做到立即显示数字。
    ///
    /// 有效期要覆盖「进入目录 → 停留一会儿 → 右键」这段真实使用间隔，太短会让预热白做；
    /// 太长又可能显示明显过期的数字。10 分钟是折中，期间同一目录再次进入会重新预热。
    private static let diskUsageCache = DiskUsageCache(capacity: 512)
    static let diskUsageCacheTTL: TimeInterval = 600

    private func diskUsage(_ req: IPCRequest) -> IPCResponse {
        guard let path = req.payload["path"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: nil)
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let normalized = url.standardizedFileURL.path

        if let cached = Self.diskUsageCache.value(for: normalized, ttl: Self.diskUsageCacheTTL) {
            ServicesProvider.trace("diskUsage 命中缓存 bytes=\(cached)")
            return IPCResponse(id: req.id, success: true, message: String(cached))
        }

        // 菜单最多等 diskUsageResponseWait；等不到就返回失败，但**后台继续算到底**并写入缓存，
        // 这样大目录下次右键就能立刻命中缓存（否则每次都在同一处超时，永远算不出来）。
        let scanDeadline = Date().addingTimeInterval(Self.diskUsageScanTimeout)
        let outcome = DiskUsageJob.run(
            url: url,
            path: normalized,
            scanDeadline: scanDeadline,
            waitTimeout: Self.diskUsageResponseWait,
            cache: Self.diskUsageCache,
            cacheTTL: Self.diskUsageCacheTTL
        )
        guard let outcome else {
            ServicesProvider.trace("diskUsage 超时返回 path=\((normalized as NSString).lastPathComponent)")
            return IPCResponse(id: req.id, success: false, message: nil)
        }
        return IPCResponse(id: req.id, success: true, message: String(outcome))
    }

    /// 预热一个目录下各项的占用：供扩展在用户「进入目录」时调用。
    ///
    /// 必须在后台做且立刻返回：用户浏览目录时会被频繁调用，不能占住 IPC 队列。
    /// 只预热直接子项、数量有上限，避免浏览超大目录时把机器拖慢。
    private func prefetchDiskUsage(_ req: IPCRequest) -> IPCResponse {
        guard let raw = req.payload["directory"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: nil)
        }
        let directory = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)

        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return IPCResponse(id: req.id, success: false, message: "无法读取目录")
        }
        let paths = names.prefix(Self.prefetchItemLimit).map { directory.appendingPathComponent($0).path }
        guard !paths.isEmpty else {
            let normalizedDir = directory.standardizedFileURL.path
            Self.diskUsageCache.store(0, for: normalizedDir)
            return IPCResponse(id: req.id, success: true, message: "空目录")
        }

        // 排队预热：单个任务串行跑，避免用户快速切换目录时同时开一堆扫描抢 IO
        for path in paths {
            let itemURL = URL(fileURLWithPath: path)
            let normalized = itemURL.standardizedFileURL.path
            Self.diskUsageQueueForPrefetch.async {
                if Self.diskUsageCache.value(for: normalized, ttl: Self.diskUsageCacheTTL) != nil { return }
                let bytes = DiskUsage.allocatedBytes(at: itemURL)
                if let bytes { Self.diskUsageCache.store(bytes, for: normalized) }
            }
        }

        // 预热目录本身：方便用户在空白处右键时直接命中缓存
        let normalizedDir = directory.standardizedFileURL.path
        Self.diskUsageQueueForPrefetch.async {
            if Self.diskUsageCache.value(for: normalizedDir, ttl: Self.diskUsageCacheTTL) != nil { return }
            let bytes = DiskUsage.allocatedBytes(at: directory)
            if let bytes { Self.diskUsageCache.store(bytes, for: normalizedDir) }
        }
        return IPCResponse(id: req.id, success: true, message: "\(paths.count)")
    }

    /// 预热时每个目录最多处理多少个子项（目录里项目很多时没必要全部预热）
    static let prefetchItemLimit = 80

    /// 预热专用串行队列：与右键时的实时请求分开，避免互相排队
    static let diskUsageQueueForPrefetch = DispatchQueue(
        label: "com.finderright.app.diskusage.prefetch",
        qos: .utility
    )

    func serviceLog(_ message: String) {
        NSLog("[FinderRightService] \(message)")
    }

    /// 剪切队列存储（扩展端读取同一份文件，见 CutQueueStore）
    let cutQueue = CutQueueStore()

    // MARK: - 操作对象名称

    /// 单项显示文件名，多项显示「N 个项目」
    static func subject(forPaths paths: [String]) -> String {
        if paths.count == 1, let only = paths.first {
            return URL(fileURLWithPath: only).lastPathComponent
        }
        return String(format: L("%d 个项目"), paths.count)
    }
}
