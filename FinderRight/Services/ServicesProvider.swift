import AppKit
import FinderRightKit

/// macOS Services 提供器 —— 让右键操作在 iCloud / Google Drive 等云盘文件夹中也可用。
///
/// ## 为什么需要它
/// FinderSync 扩展（`FIFinderSync`）在 **File Provider 域**（iCloud Drive、Google Drive、
/// OneDrive、Dropbox 等）内拿不到右键菜单。Apple DTS 的说明：Finder Sync 按「一个目录只归属
/// 一个扩展」设计，云盘目录归提供者自己的扩展，第三方扩展本就不应期望在其中生效
/// （https://github.com/aonez/Keka/issues/1327 中转述的 DTS 答复）。
/// 实测（macOS 27，iCloud Drive / Google Drive）：显式写进 `directoryURLs`、经安全书签
/// 授予目录访问后，`beginObservingDirectory` / `menu(for:)` 回调仍不触发。
/// 与完全磁盘访问无关：那是文件权限 / TCC，而这是扩展点按目录归属的路由。
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

    /// 最近一个非本 App 的前台应用：快捷键触发服务时系统会先激活本 App，需据此还原真实调用方
    private var previousFrontmostBundleId: String?

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
        provider.trackFrontmostApplication()
        // 强制系统重新扫描本 App 的 NSServices，确保安装 / 更新后菜单项立即可见
        NSUpdateDynamicServices()
        NSLog("[ServicesProvider] registered, services refreshed")
    }

    // MARK: - 调用方判定

    private func trackFrontmostApplication() {
        let me = Bundle.main.bundleIdentifier
        if let current = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, current != me {
            previousFrontmostBundleId = current
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier, id != me else { return }
            self?.previousFrontmostBundleId = id
        }
    }

    /// 服务的实际调用方（见 ServiceInvocationPolicy.effectiveCaller）
    private func invokingBundleId() -> String? {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let hasKeyWindow = NSApp.keyWindow?.isVisible == true
        return ServiceInvocationPolicy.effectiveCaller(
            frontmostBundleId: frontmost,
            providerBundleId: Bundle.main.bundleIdentifier,
            providerHasKeyWindow: hasKeyWindow,
            previousFrontmostBundleId: previousFrontmostBundleId)
    }

    /// 快捷键触发时系统把本 App 激活到了前台；不需要交互的服务处理完立即把前台还给访达，
    /// 否则用户接下来在访达里按的键（如紧接着的粘贴）全部落到本 App 上。
    private func returnFocusToFinderIfNeeded() {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier,
              NSApp.keyWindow?.isVisible != true else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    }

    // MARK: - 从 pasteboard 读取选中的文件 URL

    /// Service 传入的 pasteboard 只在本次调用期间有效，必须同步读取。
    ///
    /// 服务声明的是 `NSSendTypes = NSFilenamesPboardType`（与系统里能正常出现在 Finder
    /// 右键「服务」子菜单的 Keka / iTerm2 等服务一致），所以选中的文件以
    /// `NSFilenamesPboardType`（POSIX 路径字符串数组）放入 pasteboard，优先按此读取；
    /// 再回退到文件 URL 读取，兼容个别以 URL 形式投递的情况。
    /// 服务调用诊断日志（统一日志里 NSLog 内容被系统脱敏，排查快捷键是否触发服务只能看文件）。
    /// 只记服务名、项数、前台 App 与结果，不记路径。
    static func trace(_ message: String) {
        let line = "[\(Self.traceDateFormatter.string(from: Date()))] \(message)\n"
        traceQueue.async {
            let url = IPCBridge.rootDirectory.appendingPathComponent("service-debug.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
    private static let traceQueue = DispatchQueue(label: "com.finderright.app.services.trace")
    private static let traceDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pboard.propertyList(forType: filenamesType) as? [String], !paths.isEmpty {
            return paths.map { URL(fileURLWithPath: $0) }
        }
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL]) ?? []
    }

    /// 终端工作目录：下沉至 ServiceInvocationPolicy.targetDirectory
    private func directory(for url: URL) -> URL {
        ServiceInvocationPolicy.targetDirectory(for: url)
    }

    /// 剪切 / 粘贴 / 压缩 / 解压会以 FDA 身份读写文件，而 Services 可被任何 App 程序化调用；
    /// 仅直接受理访达调用（含快捷键触发时系统先激活本 App 的情况，见 invokingBundleId）；
    /// 用户正在本 App 窗口里时剪切 / 粘贴要求确认。
    private func isInvokedFromFinder(_ service: String) -> Bool {
        let frontmost = invokingBundleId()
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
        returnFocusToFinderIfNeeded()
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
        let names = PathFormatter.fileNames(for: items, format: SharedConfig.shared.copyFileNameFormat)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(names, forType: .string) else {
            showAlert(NSLocalizedString("无法写入剪贴板", comment: "service"))
            return
        }
        ClipboardToast.showCopied()
        returnFocusToFinderIfNeeded()
    }

    @objc func copyFileContent(_ pboard: NSPasteboard,
                               userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        // 以「完全磁盘访问」身份读文件内容写入剪贴板：任何 App 都能 NSPerformService 传入任意路径，
        // 必须只受理访达前台调用，否则可借本 App 读出受保护文件
        guard isInvokedFromFinder("copyFileContent") else {
            error?.pointee = NSLocalizedString("请从访达调用文件服务", comment: "service") as NSString
            return
        }
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.copyFileContent) else {
            showAlert(NSLocalizedString("复制文件内容功能已关闭，请在设置中启用", comment: "service"))
            return
        }
        let items = fileURLs(from: pboard)
        guard let url = ServiceInvocationPolicy.validateSingleFile(from: items) else {
            showAlert(NSLocalizedString("仅支持复制单个文件的内容", comment: "service"))
            return
        }
        let maxBytes = SharedConfig.shared.copyFileContentMaxBytes
        // 服务传入的 pasteboard 已同步读完；文件 I/O 和文本识别交给后台。
        workQueue.async { [self] in
            let result = FileContentReader.readText(from: url, maxBytes: maxBytes)
            DispatchQueue.main.async { [self] in
                switch result {
                case .success(let text):
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(text, forType: .string) else {
                        showAlert(NSLocalizedString("无法写入剪贴板", comment: "service"))
                        return
                    }
                    ClipboardToast.showCopied(message: NSLocalizedString("已复制文件内容到剪贴板", comment: ""))
                    returnFocusToFinderIfNeeded()
                case .notRegularFile:
                    showAlert(NSLocalizedString("仅支持普通文件", comment: "service"))
                case .fileTooLarge:
                    ClipboardToast.showCopied(message: NSLocalizedString("文件大小超过限制", comment: ""), isWarning: true)
                case .readFailed:
                    showAlert(NSLocalizedString("无法读取文件内容", comment: "service"))
                case .binaryFile:
                    ClipboardToast.showCopied(message: NSLocalizedString("无法复制：非文本文件", comment: ""), isWarning: true)
                }
            }
        }
        returnFocusToFinderIfNeeded()
    }

    /// 服务菜单不支持子菜单，保留最常用的 SHA-256；其余算法仍从 FinderSync 菜单选择。
    @objc func copyFileHash(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard isInvokedFromFinder("copyFileHash") else {
            error?.pointee = NSLocalizedString("请从访达调用文件服务", comment: "service") as NSString
            return
        }
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.copyFileHash) else {
            showAlert(NSLocalizedString("此功能已关闭，请在设置中启用", comment: "service"))
            return
        }
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        performFileAction(IPCRequest(id: UUID().uuidString, action: "copyFileHash", payload: [
            "items": .stringArray(items.map(\.path)), "algorithm": .string(FileHasher.Algorithm.sha256.rawValue)
        ]), feature: MenuFeatureCatalog.copyFileHash)
        returnFocusToFinderIfNeeded()
    }

    @objc func createSymlink(_ pboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        guard canStartFileAction(MenuFeatureCatalog.createSymlink, error: error) else { return }
        let items = fileURLs(from: pboard)
        guard !items.isEmpty else { return }
        performFileAction(IPCRequest(id: UUID().uuidString, action: "createSymlink", payload: [
            "items": .stringArray(items.map(\.path))
        ]), feature: MenuFeatureCatalog.createSymlink)
        returnFocusToFinderIfNeeded()
    }

    @objc func goToDirectory(_ pboard: NSPasteboard,
                             userData: String?,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.goToDirectory) else {
            showAlert(NSLocalizedString("打开路径功能已关闭，请在设置中启用", comment: "service"))
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
        DispatchQueue.main.async { [self] in
            SharedConfig.shared.reload()
            let customTemplates = SharedConfig.shared.customFileTemplates
            let order = SharedConfig.shared.newFileOrder
            let hidden = SharedConfig.shared.hiddenNewFileTemplates
            let allTemplates = NewFileTemplateCatalog.resolvedTemplates(order: order, customTemplates: customTemplates)
            let activeTemplates = allTemplates.filter { !hidden.contains($0.id) }
            guard !activeTemplates.isEmpty else {
                showAlert(NSLocalizedString("未启用任何新建文件模板，请在设置中开启", comment: "service"))
                return
            }
            let choices = activeTemplates.map { item -> String in
                if item.isCustom {
                    return item.name.isEmpty ? ".\(item.fileExtension)" : "\(item.name) (.\(item.fileExtension))"
                }
                return NSLocalizedString(item.name, comment: "service")
            }
            guard let index = chooseFileAction(title: "在此文件夹新建文件…", symbol: "doc.badge.plus", details: destination.path,
                                              choices: choices, button: "创建") else { return }
            let item = activeTemplates[index]
            var payload: [String: AnyJSON] = ["directory": .string(destination.path), "baseName": .string("untitled")]
            if item.isOffice {
                payload["template"] = .string(item.fileExtension)
            } else {
                payload["ext"] = .string(item.fileExtension)
                payload["content"] = .string(item.content)
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
        let favorites = SharedConfig.shared.orderedFavoriteDirectories
        guard ServiceInvocationPolicy.validateFavoritesTransfer(items: items, favorites: favorites) else {
            if items.isEmpty {
                showAlert(NSLocalizedString("请先选中要移动或复制的项目", comment: "service"))
            } else {
                showAlert(NSLocalizedString("尚未添加常用目录，请在设置中添加", comment: "service"))
            }
            return
        }
        DispatchQueue.main.async { [self] in
            let names = FavoriteDirectories.displayNames(for: favorites, home: IPCBridge.realUserHomeDirectory.path)
            let choices = zip(names, favorites).map { "\($0) — \($1)" }
            let details = String(format: NSLocalizedString("已选 %d 个项目：", comment: "service"), items.count)
                + "\n" + items.prefix(5).map(\.path).joined(separator: "\n") + (items.count > 5 ? "\n…" : "")
            guard let index = chooseFileAction(title: mode == .move ? "移动到常用目录…" : "复制到常用目录…",
                                              symbol: mode == .move ? "arrowshape.turn.up.right" : "plus.square.on.square",
                                              details: details, choices: choices, button: mode == .move ? "移动" : "复制") else { return }
            performFileAction(IPCRequest(id: UUID().uuidString, action: "transferItems", payload: [
                "items": .stringArray(items.map(\.path)), "destination": .string(favorites[index]), "mode": .string(mode.rawValue)
            ]), feature: feature)
        }
    }

    private func canStartFileAction(_ feature: String, error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard ServiceInvocationPolicy.acceptsInteractiveService(
            frontmostBundleId: invokingBundleId(),
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

    private func chooseFileAction(title: String, symbol: String, details: String, choices: [String], button: String) -> Int? {
        guard !isShowingFileActionPrompt else { return nil }
        isShowingFileActionPrompt = true
        defer { isShowingFileActionPrompt = false }
        let dialog = FRDialog(
            title: NSLocalizedString(title, comment: "service"),
            message: details,
            symbol: symbol,
            buttons: [NSLocalizedString(button, comment: "service"), NSLocalizedString("取消", comment: "service")],
            input: .choice(choices, accessibilityLabel: NSLocalizedString("模板或目标目录", comment: "service")))
        guard dialog.runModal() == 0, choices.indices.contains(dialog.selectedIndex) else { return nil }
        return dialog.selectedIndex
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
            FRDialog(title: title, message: message, symbol: "exclamationmark.triangle", tone: .warning,
                     buttons: [NSLocalizedString("好", comment: "service")]).runModal()
        }
    }

    @objc func openTerminal(_ pboard: NSPasteboard,
                            userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let items = fileURLs(from: pboard)
        guard let first = items.first else { return }
        let dir = directory(for: first)
        let bundleId = TerminalCatalog.resolvedDefault(preferred: SharedConfig.shared.preferredTerminal)
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
            preferred: config.preferredEditor)
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
        let frontmost = invokingBundleId()
        Self.trace("cutFiles called: items=\(fileURLs(from: pboard).count) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") caller=\(frontmost ?? "nil")")
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
            returnFocusToFinderIfNeeded()
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
        let details = String(format: NSLocalizedString("已选 %d 个项目：", comment: "service"), items.count)
            + "\n" + items.prefix(5).map(\.path).joined(separator: "\n") + (items.count > 5 ? "\n…" : "")
            + "\n\n" + NSLocalizedString("确认后在目标文件夹调用「粘贴」即可移动。", comment: "service")
        return FRDialog(title: NSLocalizedString("剪切文件", comment: "service"), message: details, symbol: "scissors",
                        buttons: [NSLocalizedString("剪切", comment: "service"), NSLocalizedString("取消", comment: "service")]).runModal() == 0
    }

    @objc func pasteFiles(_ pboard: NSPasteboard,
                          userData: String?,
                          error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        let frontmost = invokingBundleId()
        let items = fileURLs(from: pboard)
        Self.trace("pasteFiles called: items=\(items.count) dirs=\(items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") caller=\(frontmost ?? "nil")")
        let needsConfirmation = ServiceInvocationPolicy.requiresServiceConfirmation(
            frontmostBundleId: frontmost, providerBundleId: Bundle.main.bundleIdentifier)
        guard ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: frontmost)
                || needsConfirmation else {
            Self.trace("pasteFiles rejected: not from Finder")
            error?.pointee = NSLocalizedString("请从访达调用粘贴服务", comment: "service") as NSString
            return
        }
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.paste) else {
            showAlert(NSLocalizedString("粘贴功能已关闭，请在设置中启用", comment: "service"))
            return
        }
        guard let destination = ServiceInvocationPolicy.pasteDestination(for: items) else {
            Self.trace("pasteFiles rejected: no destination")
            showAlert(NSLocalizedString("请选择一个目标文件夹，再调用粘贴服务", comment: "service"))
            return
        }
        Self.trace("pasteFiles accepted: confirm=\(needsConfirmation)")
        // 确认框与移动都放到服务返回之后：模态等待和云盘大文件移动不能占用 Services 的同步超时。
        DispatchQueue.main.async { [self] in
            if needsConfirmation && !confirmPaste(into: destination) { return }
            performFileAction(IPCRequest(
                id: UUID().uuidString,
                action: "pasteFiles",
                payload: ["destination": .string(destination.path)]), feature: MenuFeatureCatalog.paste)
            if !needsConfirmation { returnFocusToFinderIfNeeded() }
        }
    }

    private func confirmPaste(into destination: URL) -> Bool {
        guard !isConfirmingCutPaste else { return false }
        isConfirmingCutPaste = true
        defer { isConfirmingCutPaste = false }
        let details = String(format: NSLocalizedString(
            "将 FinderRight 剪切队列中的文件移动到：\n%@", comment: "service"), destination.path)
        return FRDialog(title: NSLocalizedString("粘贴已剪切的文件", comment: "service"), message: details, symbol: "doc.on.clipboard",
                        buttons: [NSLocalizedString("粘贴", comment: "service"), NSLocalizedString("取消", comment: "service")]).runModal() == 0
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
        let archives = ServiceInvocationPolicy.filterArchives(from: fileURLs(from: pboard))
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
