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
/// 改用 **macOS Services**。Services 基于 Finder 提供的文件路径经响应链派发，与目录归属无关，
/// 因此也可出现在云盘文件夹的右键「服务 / Services」子菜单里。
/// 主 App 非沙箱，故 Service 处理器可直接复用 `FinderRightService` 的现有逻辑（无需 IPC）。
///
/// ## 局限
/// 本机 Google Drive 实测：空白处也可能把当前目录作为输入传入，但并非每次右键都显示服务。
/// 未显示时，可在上一级选中目标文件夹，调用「粘贴到此文件夹」或「在此文件夹新建文件」。
///
/// 方法名（如 `copyPath`）对应 Info.plist 中每个 service 的 `NSMessage`，
/// 实际 selector 为 `copyPath:userData:error:`。
final class ServicesProvider: NSObject {

    /// 复用主 App 端的业务逻辑处理器（与 IPCWatcher 用的是同一套）
    private let service = FinderRightService()

    /// 压缩 / 解压等会 fork 子进程并 `waitUntilExit`，放后台串行队列，避免阻塞 Finder 主线程
    private let workQueue = DispatchQueue(label: "com.finderright.app.services", qos: .userInitiated)
    private var isConfirmingCutPaste = false
    private var isShowingFileActionPrompt = false
    private let showDirectoryPrompt: () -> Void

    private init(showDirectoryPrompt: @escaping () -> Void) {
        self.showDirectoryPrompt = showDirectoryPrompt
        super.init()
    }

    /// 强引用，防止被释放（即便 `servicesProvider` 语义变化也安全）
    private static var sharedInstance: ServicesProvider?

    /// 注册为应用的 Services 提供器，并刷新系统 Services 缓存。
    /// 在 `applicationDidFinishLaunching` 中调用一次。
    static func register(showDirectoryPrompt: @escaping () -> Void) {
        let provider = ServicesProvider(showDirectoryPrompt: showDirectoryPrompt)
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

    /// 终端工作目录：选中项是文件夹则用它本身，否则用其所在目录
    private func directory(for url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    /// 剪切 / 粘贴 / 压缩 / 解压会以 FDA 身份读写文件，而 Services 可被任何 App 程序化调用；
    /// 仅直接受理访达前台调用；剪切 / 粘贴另处理提供程序被系统激活的情况，要求用户确认。
    private func isInvokedFromFinder(_ service: String) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: frontmost) else {
            NSLog("[ServicesProvider] 拒绝 \(service)：前台应用为 \(frontmost ?? "nil")，不是访达")
            return false
        }
        return true
    }

    // MARK: - Services（selector：<name>:userData:error:）

    @objc func copyPath(_ pboard: NSPasteboard,
                        userData: String?,
                        error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        SharedConfig.shared.reload()
        let joined = PathFormatter.string(for: items, format: SharedConfig.shared.copyPathFormat,
                                          home: IPCBridge.realUserHomeDirectory.path)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(joined, forType: .string) else {
            showAlert(NSLocalizedString("无法写入剪贴板", comment: "service"))
            return
        }
        ClipboardToast.showCopied()
        NSLog("[ServicesProvider] copyPath: \(items.count) item(s)")
    }

    @objc func copyFileName(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.copyFileName) else {
            showAlert(NSLocalizedString("复制文件名功能已关闭，请在设置中启用", comment: "service"))
            return
        }
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        let names = PathFormatter.string(for: items, format: .name, home: IPCBridge.realUserHomeDirectory.path)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(names, forType: .string) else {
            showAlert(NSLocalizedString("无法写入剪贴板", comment: "service"))
            return
        }
        ClipboardToast.showCopied()
    }

    @objc func goToDirectory(_ pboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.goToDirectory) else {
            showAlert(NSLocalizedString("前往目录功能已关闭，请在设置中启用", comment: "service"))
            return
        }
        DispatchQueue.main.async(execute: showDirectoryPrompt)
    }

    @objc func newFile(_ pboard: NSPasteboard,
                       userData: String?,
                       error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard canStartFileAction(MenuFeatureCatalog.newFile, error: error) else { return }
        guard let destination = ServiceInvocationPolicy.pasteDestination(for: fileURLs(from: pboard)) else {
            showAlert(NSLocalizedString("请选择一个目标文件夹，再调用新建文件服务", comment: "service"))
            return
        }
        // 同步读取服务剪贴板，返回派发后再显示交互界面，避免占用 Services 的同步超时。
        DispatchQueue.main.async { [self] in
            SharedConfig.shared.reload()
            let customTemplates = SharedConfig.shared.customFileTemplates
            let textTemplates = BuiltInFileTemplates.text + customTemplates
            let officeTemplates = OfficeTemplate.allCases
            let choices = BuiltInFileTemplates.text.map { NSLocalizedString($0.name, comment: "service") }
                + customTemplates.map { $0.name.isEmpty ? ".\($0.fileExtension)" : "\($0.name) (.\($0.fileExtension))" }
                + officeTemplates.map { NSLocalizedString($0.titleKey, comment: "service") }
            guard let index = chooseFileAction(title: "在此文件夹新建文件…", details: destination.path,
                                              choices: choices, button: "创建") else { return }
            var payload: [String: AnyJSON] = ["directory": .string(destination.path), "baseName": .string("untitled")]
            if textTemplates.indices.contains(index) {
                let template = textTemplates[index]
                payload["ext"] = .string(template.fileExtension)
                payload["content"] = .string(template.content)
            } else {
                payload["template"] = .string(officeTemplates[index - textTemplates.count].rawValue)
            }
            performFileAction(IPCRequest(id: UUID().uuidString, action: "createFile", payload: payload), feature: MenuFeatureCatalog.newFile)
        }
    }

    @objc func moveToFavorite(_ pboard: NSPasteboard,
                              userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        transferToFavorite(pboard, mode: .move, error: error)
    }

    @objc func copyToFavorite(_ pboard: NSPasteboard,
                              userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        transferToFavorite(pboard, mode: .copy, error: error)
    }

    private func transferToFavorite(_ pboard: NSPasteboard, mode: FileTransferCheck.Mode,
                                     error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let feature = mode == .move ? MenuFeatureCatalog.moveTo : MenuFeatureCatalog.copyTo
        guard canStartFileAction(feature, error: error) else { return }
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else {
            showAlert(NSLocalizedString("请先选中要移动或复制的项目", comment: "service"))
            return
        }
        let favorites = SharedConfig.shared.favoriteDirectories
        guard !favorites.isEmpty else {
            showAlert(NSLocalizedString("尚未添加常用目录，请在设置中添加", comment: "service"))
            return
        }
        DispatchQueue.main.async { [self] in
            let names = FavoriteDirectories.displayNames(for: favorites, home: IPCBridge.realUserHomeDirectory.path)
            let choices = zip(names, favorites).map { "\($0) — \($1)" }
            let details = String(format: NSLocalizedString("已选 %d 个项目：", comment: "service"), items.count)
                + "\n" + items.prefix(5).map(\.path).joined(separator: "\n") + (items.count > 5 ? "\n…" : "")
            guard let index = chooseFileAction(title: mode == .move ? "移动到常用目录…" : "复制到常用目录…",
                                              details: details, choices: choices, button: mode == .move ? "移动" : "复制") else { return }
            performFileAction(IPCRequest(id: UUID().uuidString, action: "transferItems", payload: [
                "items": .stringArray(items.map(\.path)), "destination": .string(favorites[index]), "mode": .string(mode.rawValue)
            ]), feature: feature)
        }
    }

    private func canStartFileAction(_ feature: String, error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard ServiceInvocationPolicy.acceptsInteractiveService(
            frontmostBundleId: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            providerBundleId: Bundle.main.bundleIdentifier) else {
            error?.pointee = NSLocalizedString("请从访达调用文件服务", comment: "service") as NSString
            return false
        }
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(feature) else {
            showAlert(NSLocalizedString("此功能已关闭，请在设置中启用", comment: "service"))
            return false
        }
        return true
    }

    private func chooseFileAction(title: String, details: String, choices: [String], button: String) -> Int? {
        guard !isShowingFileActionPrompt else { return nil }
        isShowingFileActionPrompt = true
        defer { isShowingFileActionPrompt = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(title, comment: "service")
        alert.informativeText = details
        alert.addButton(withTitle: NSLocalizedString(button, comment: "service"))
        alert.addButton(withTitle: NSLocalizedString("取消", comment: "service"))
        let choice = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
        // 逐项添加：addItems(withTitles:) 会合并同名项，自定义模板与内置模板重名时下标会错位
        choices.forEach { choice.menu?.addItem(NSMenuItem(title: $0, action: nil, keyEquivalent: "")) }
        choice.setAccessibilityLabel(NSLocalizedString("模板或目标目录", comment: "service"))
        alert.accessoryView = choice
        guard alert.runModal() == .alertFirstButtonReturn, choices.indices.contains(choice.indexOfSelectedItem) else { return nil }
        return choice.indexOfSelectedItem
    }

    private func performFileAction(_ request: IPCRequest, feature: String) {
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(feature) else { return }
        FinderRightService.backgroundJobs.run(on: workQueue) { [service] in
            let response = service.handle(request)
            guard !response.success else { return }
            self.showAlert(NSLocalizedString("文件操作失败", comment: "service"), message: response.message ?? "")
        }
    }

    /// 访达不展示服务返回的 error，面向用户的提示由本 App 弹窗给出。
    /// 调用方校验失败（非访达调用）仍只写 error，避免其他 App 借服务反复弹窗。
    private func showAlert(_ title: String, message: String = "") {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.runModal()
        }
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

    /// 解析默认编辑器：与设置页「默认编辑器」同一套规则（见 EditorCatalog.resolvedDefault）
    private func resolvedEditorBundleId() -> String {
        let config = SharedConfig.shared
        config.reload()
        return EditorCatalog.resolvedDefault(
            preferred: config.preferredEditor,
            custom: config.customEditors,
            hidden: config.hiddenEditors,
            isInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
    }

    @objc func openEditor(_ pboard: NSPasteboard,
                          userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        let paths = items.map(\.path)
        let bundleId = resolvedEditorBundleId()
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
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // 云盘目录里系统会先激活本 App 再派发服务，此时访达不在前台，需用户确认后才写入剪切队列
        let needsConfirmation = ServiceInvocationPolicy.requiresServiceConfirmation(
            frontmostBundleId: frontmost, providerBundleId: Bundle.main.bundleIdentifier)
        guard ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: frontmost)
                || needsConfirmation else {
            error?.pointee = NSLocalizedString("请从访达调用剪切服务", comment: "service") as NSString
            return
        }
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.cut) else {
            showAlert(NSLocalizedString("剪切功能已关闭，请在设置中启用", comment: "service"))
            return
        }
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        let request = IPCRequest(
            id: UUID().uuidString,
            action: "cutFiles",
            payload: ["paths": .stringArray(items.map(\.path))])
        guard needsConfirmation else {
            performFileAction(request, feature: MenuFeatureCatalog.cut)
            return
        }
        // 确认框放到服务返回之后，避免模态等待占用 Services 的同步超时
        DispatchQueue.main.async { [self] in
            if confirmCut(items) {
                performFileAction(request, feature: MenuFeatureCatalog.cut)
            }
        }
    }

    /// 云盘目录没有剪切角标，确认框同时充当「剪切了哪些文件」的反馈
    private func confirmCut(_ items: [URL]) -> Bool {
        guard !isConfirmingCutPaste else { return false }
        isConfirmingCutPaste = true
        defer { isConfirmingCutPaste = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("剪切文件", comment: "service")
        alert.informativeText = String(format: NSLocalizedString("已选 %d 个项目：", comment: "service"), items.count)
            + "\n" + items.prefix(5).map(\.path).joined(separator: "\n") + (items.count > 5 ? "\n…" : "")
            + "\n\n" + NSLocalizedString("确认后在目标文件夹调用「粘贴」即可移动。", comment: "service")
        alert.addButton(withTitle: NSLocalizedString("剪切", comment: "service"))
        alert.addButton(withTitle: NSLocalizedString("取消", comment: "service"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func pasteFiles(_ pboard: NSPasteboard,
                          userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let needsConfirmation = ServiceInvocationPolicy.requiresServiceConfirmation(
            frontmostBundleId: frontmost, providerBundleId: Bundle.main.bundleIdentifier)
        guard ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: frontmost)
                || needsConfirmation else {
            error?.pointee = NSLocalizedString("请从访达调用粘贴服务", comment: "service") as NSString
            return
        }
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.paste) else {
            showAlert(NSLocalizedString("粘贴功能已关闭，请在设置中启用", comment: "service"))
            return
        }
        guard let destination = ServiceInvocationPolicy.pasteDestination(for: fileURLs(from: pboard)) else {
            showAlert(NSLocalizedString("请选择一个目标文件夹，再调用粘贴服务", comment: "service"))
            return
        }
        // 确认框与移动都放到服务返回之后：模态等待和云盘大文件移动不能占用 Services 的同步超时。
        DispatchQueue.main.async { [self] in
            if needsConfirmation && !confirmPaste(into: destination) { return }
            performFileAction(IPCRequest(
                id: UUID().uuidString,
                action: "pasteFiles",
                payload: ["destination": .string(destination.path)]), feature: MenuFeatureCatalog.paste)
        }
    }

    private func confirmPaste(into destination: URL) -> Bool {
        guard !isConfirmingCutPaste else { return false }
        isConfirmingCutPaste = true
        defer { isConfirmingCutPaste = false }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("粘贴已剪切的文件", comment: "service")
        alert.informativeText = String(format: NSLocalizedString(
            "将 FinderRight 剪切队列中的文件移动到：\n%@", comment: "service"), destination.path)
        alert.addButton(withTitle: NSLocalizedString("粘贴", comment: "service"))
        alert.addButton(withTitle: NSLocalizedString("取消", comment: "service"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func compressZip(_ pboard: NSPasteboard,
                           userData: String?,
                           error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard isInvokedFromFinder("compressZip") else { return }
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
        guard isInvokedFromFinder("decompress") else { return }
        // 服务对所有文件可见（受 NSFilenamesPboardType 限制无法只对压缩包显示），
        // 因此在此处过滤：只解压压缩包，普通文件忽略。
        let archives = fileURLs(from: pboard).filter { ArchiveKind.isArchive(fileName: $0.lastPathComponent) }
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
