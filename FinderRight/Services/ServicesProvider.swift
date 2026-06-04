import AppKit
import FinderRightKit

/// macOS Services 提供器 —— 让右键操作在 iCloud / Google Drive 等云盘文件夹中也可用。
///
/// ## 为什么需要它
/// FinderSync 扩展（`FIFinderSync`）在 **File Provider 域**（iCloud Drive、Google Drive、
/// OneDrive、Dropbox 等）内被 macOS 架构性禁止：系统把右键菜单 / 徽章这个扩展点保留给
/// 域自身的 File Provider 扩展，第三方 Finder Sync 写进 `directoryURLs` 的云盘路径会被
/// 静默忽略，`beginObservingDirectory` / `menu(for:)` 回调永不触发（与完全磁盘访问无关，
/// 那是文件权限 / TCC，而这是扩展点路由）。
///
/// ## 解决方案
/// 改用 **macOS Services**。Services 基于「当前选中项」经响应链派发，与目录归属无关，
/// 因此在任意文件夹（含云盘）的右键「服务 / Services」子菜单里都能出现。
/// 主 App 非沙箱，故 Service 处理器可直接复用 `FinderRightService` 的现有逻辑（无需 IPC）。
///
/// ## 局限
/// Services 必须有「选中项」才会被触发，因此「新建文件」「空白处粘贴」这类无选中项的
/// 容器操作无法走此路径 —— 它们在普通目录仍由 FinderSync 扩展提供。
///
/// 方法名（如 `copyPath`）对应 Info.plist 中每个 service 的 `NSMessage`，
/// 实际 selector 为 `copyPath:userData:error:`。
final class ServicesProvider: NSObject {

    /// 复用主 App 端的业务逻辑处理器（与 IPCWatcher 用的是同一套）
    private let service = FinderRightService()

    /// 压缩 / 解压等会 fork 子进程并 `waitUntilExit`，放后台串行队列，避免阻塞 Finder 主线程
    private let workQueue = DispatchQueue(label: "com.finderright.app.services", qos: .userInitiated)

    /// 强引用，防止被释放（即便 `servicesProvider` 语义变化也安全）
    private static var sharedInstance: ServicesProvider?

    /// 注册为应用的 Services 提供器，并刷新系统 Services 缓存。
    /// 在 `applicationDidFinishLaunching` 中调用一次。
    static func register() {
        let provider = ServicesProvider()
        NSApp.servicesProvider = provider
        sharedInstance = provider
        // 强制系统重新扫描本 App 的 NSServices，确保安装 / 更新后菜单项立即可见
        NSUpdateDynamicServices()
        NSLog("[ServicesProvider] registered, services refreshed")
    }

    // MARK: - 从 pasteboard 读取选中的文件 URL

    /// Service 传入的 pasteboard 只在本次调用期间有效，必须同步读取。
    ///
    /// 服务声明的是 `NSSendTypes = NSFilenamesPboardType`（与系统里能正常出现在 Finder
    /// 右键「服务」子菜单的 Keka / iTerm2 等服务一致），所以选中的文件以
    /// `NSFilenamesPboardType`（POSIX 路径字符串数组）放入 pasteboard，优先按此读取；
    /// 再回退到文件 URL 读取，兼容个别以 URL 形式投递的情况。
    private func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pboard.propertyList(forType: filenamesType) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }

    /// 是否为可解压的压缩包（与扩展 FinderSync.isArchive 保持一致）
    private func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let suffixes = [".zip", ".tar", ".gz", ".tgz", ".bz2", ".tbz",
                        ".xz", ".txz", ".7z", ".rar"]
        return suffixes.contains { name.hasSuffix($0) }
    }

    /// 终端工作目录：选中项是文件夹则用它本身，否则用其所在目录
    private func directory(for url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    // MARK: - Services（selector：<name>:userData:error:）

    @objc func copyPath(_ pboard: NSPasteboard,
                        userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        let joined = items.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
        NSLog("[ServicesProvider] copyPath: \(items.count) item(s)")
    }

    @objc func openTerminal(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let items = fileURLs(from: pboard)
        guard let first = items.first else { return }
        let dir = directory(for: first)
        let bundleId = SharedConfig.shared.preferredTerminal
        workQueue.async { [service] in
            _ = service.handle(IPCRequest(
                id: UUID().uuidString,
                action: "openTerminal",
                payload: ["directory": .string(dir.path), "bundleId": .string(bundleId)]))
        }
    }

    @objc func openEditor(_ pboard: NSPasteboard,
                          userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        let paths = items.map(\.path)
        let bundleId = SharedConfig.shared.preferredEditor
        workQueue.async { [service] in
            _ = service.handle(IPCRequest(
                id: UUID().uuidString,
                action: "openWithApp",
                payload: ["paths": .stringArray(paths), "bundleId": .string(bundleId)]))
        }
    }

    @objc func cutFiles(_ pboard: NSPasteboard,
                        userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        let paths = items.map(\.path)
        workQueue.async { [service] in
            _ = service.handle(IPCRequest(
                id: UUID().uuidString,
                action: "cutFiles",
                payload: ["paths": .stringArray(paths)]))
        }
    }

    @objc func compressZip(_ pboard: NSPasteboard,
                           userData: String?,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        let paths = items.map(\.path)
        workQueue.async { [service] in
            _ = service.handle(IPCRequest(
                id: UUID().uuidString,
                action: "compressZip",
                payload: ["items": .stringArray(paths)]))
        }
    }

    @objc func decompress(_ pboard: NSPasteboard,
                          userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        // 服务对所有文件可见（受 NSFilenamesPboardType 限制无法只对压缩包显示），
        // 因此在此处过滤：只解压压缩包，普通文件忽略。
        let archives = fileURLs(from: pboard).filter(isArchive)
        guard !archives.isEmpty else { return }
        let paths = archives.map(\.path)
        workQueue.async { [service] in
            for path in paths {
                _ = service.handle(IPCRequest(
                    id: UUID().uuidString,
                    action: "decompress",
                    payload: ["archive": .string(path)]))
            }
        }
    }
}
