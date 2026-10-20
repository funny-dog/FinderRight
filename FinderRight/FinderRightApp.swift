import SwiftUI
import FinderRightKit

@main
struct FinderRightApp: App {
    // 用 AppDelegate 管理原生状态栏菜单 + URL scheme + activation policy
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSLog("[FinderRightApp] init() called, starting IPC watcher")
        IPCWatcher.shared.start()
        NSLog("[FinderRightApp] IPC watcher ready")
    }

    var body: some Scene {
        // 设置窗口改由 AppDelegate 唯一管理（菜单栏与 ⌘, 唤起相同实例），
        // 此处 Settings 留空以避免产生双设置窗口实例与状态分叉；
        // ⌘, 菜单项替换为 AppDelegate.openSettings()，否则 SwiftUI 默认项会打开空白窗口。
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(NSLocalizedString("设置...", comment: "menu")) {
                    appDelegate.openSettings()
                }
                // replacing: .appSettings 会连同系统自带「设置…」的 ⌘, 一起移除，
                // 这里必须显式补回，否则应用菜单里设置项没有快捷键
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    /// 设置页「重新查看引导」发出，由 AppDelegate 打开引导窗口
    static let openOnboarding = Notification.Name("FinderRight.openOnboarding")
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var receivedLaunchURL = false
    private var directoryDialog: FRDialog?
    /// 菜单打开期间随更新状态刷新标题（检查中 / 下载进度 / 安装中）
    private weak var updateMenuItem: NSMenuItem?

    /// 用户是否要求常驻显示 Dock 图标
    private var alwaysShowDockIcon: Bool {
        UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
    }

    /// 用户是否显示菜单栏图标
    private var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    /// 用户是否开启「最近操作」（可选功能，默认关闭）
    private var showRecentActivity: Bool {
        UserDefaults.standard.bool(forKey: "showRecentActivity")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 撤销记录只存内存：清掉上次崩溃或强退残留的状态文件，免得扩展显示无效的撤销菜单项
        UndoCenter.shared.clear()

        // 「切换隐藏文件」在扩展端是无状态固定文案（见 FinderSync.menu(for:) 里该菜单项的说明），
        // 不再需要在启动时把 SharedConfig 锚定到 Finder 真实状态。

        // 根据偏好动态设定激活策略
        if alwaysShowDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        NSLog("[AppDelegate] activation policy = \(alwaysShowDockIcon ? "regular" : "accessory")")

        // 在任何窗口创建前应用用户选择的浅色 / 深色外观并同步主题配置
        FRAppearanceMode.stored.apply()
        SharedConfig.shared.appTheme = FRThemeID.current

        RecentOperations.shared.isEnabled = showRecentActivity
        setupStatusItem()

        // 注册 macOS Services：让右键操作在 iCloud / Google Drive 等 File Provider
        // 云盘文件夹中也可用（这些目录归云盘自己的扩展，FinderSync 扩展拿不到右键菜单）。
        // 先补上默认快捷键（每行只补一次、只填空位，不覆盖用户设置），
        // 再把设置里的快捷键同步成系统服务快捷键（覆盖升级前的旧状态），register 内会刷新服务缓存
        FinderShortcutInterceptor.applyDefaultShortcutsIfNeeded()
        ServiceShortcutSync.run()
        ServicesProvider.register { [weak self] in self?.openGoToDirectory() }
        // 授权「辅助功能」后快捷键由按键拦截处理，访达在前台时生效
        FinderShortcutInterceptor.shared.start { [weak self] in self?.openGoToDirectory() }

        // 自动注册并启用自身包含的 FinderSync 扩展
        registerFinderSyncPlugin()

        // 检查是否有历史暂存区遗留文件或自动更新错误
        checkLegacyStagingDirectory()
        checkLastUpdateError()

        // 监听窗口关闭：当所有标准窗口都关闭后，恢复 accessory（隐藏 Dock 图标）
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)

        // 监听偏好变化：实时切换菜单栏图标显隐
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)

        // 后台操作有新结果：刷新菜单栏图标的失败提示
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateStatusIndicator),
            name: RecentOperations.didChangeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(updateStatusDidChange),
            name: UpdateChecker.statusDidChangeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(openOnboarding),
            name: .openOnboarding, object: nil)

        UpdateChecker.shared.configureAutomaticUpdates()

        let showSettings = LaunchPresentation.shouldShowSettings(
            isDefaultLaunch: notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? false,
            event: NSAppleEventManager.shared().currentAppleEvent,
            receivedURL: receivedLaunchURL,
            arguments: ProcessInfo.processInfo.arguments)
        NSLog("[AppDelegate] launch presentation: showSettings=\(showSettings)")
        guard showSettings else { return }

        // 仅主动打开时展示引导或设置，后台唤醒不标记引导完成。
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasCompletedOnboarding {
            // 弹出即视为已完成：用户若用红点直接关窗，OnboardingView 的「开始使用」不会执行，
            // 标志位会一直是 false，导致此后每次冷启动（含右键 IPC 冷启动、开机自启）
            // 都重复弹引导并抢焦。用户已看过引导即视为完成。
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            showOnboarding()
        } else {
            openSettings()
        }
    }

    /// 检查旧版 staging/ 目录是否存在遗留文件，仅记录日志，不自动移动或删除
    private func checkLegacyStagingDirectory() {
        // 一次性提醒：发送成功后才置位，避免每次冷启动重复弹同一条通知
        let sentKey = "stagingLegacyWarningSent"
        guard !UserDefaults.standard.bool(forKey: sentKey) else { return }

        let stagingDir = IPCBridge.rootDirectory.appendingPathComponent("staging", isDirectory: true)
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: stagingDir.path), !items.isEmpty {
            NSLog("[AppDelegate] 发现暂存区遗留文件: \(items.count) 个，位于 \(stagingDir.path)")
            UserDefaults.standard.set(true, forKey: sentKey)
        }
    }

    /// 检查上次更新是否有失败日志并弹窗提醒
    private func checkLastUpdateError() {
        let errorFileURL = IPCBridge.rootDirectory.appendingPathComponent("last-update-error.txt")
        let fm = FileManager.default
        if fm.fileExists(atPath: errorFileURL.path),
           let content = try? String(contentsOf: errorFileURL, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fm.removeItem(at: errorFileURL)
            DispatchQueue.main.async { [weak self] in
                self?.showUpdateFailure(title: NSLocalizedString("自动更新失败", comment: "alert"),
                                        message: content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// 自动检查并向系统注册自身的 FinderSync 扩展
    private func registerFinderSyncPlugin() {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else { return }
        let appexURL = pluginsURL.appendingPathComponent("FinderRightSync.appex")
        guard FileManager.default.fileExists(atPath: appexURL.path) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            /// 查询插件注册与选举状态。必须带 `-v`：输出形如
            /// `+    com.finderright.app.sync(1.1.10)<Tab><uuid><Tab><日期><Tab><路径>`；
            /// 不带 -v 时没有路径字段，路径比对永远失败（曾导致每次启动都重复 pluginkit -a）。
            func queryPluginState() -> (status: Int32, output: String) {
                let proc = Process()
                let pipe = Pipe()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                proc.arguments = ["-m", "-v", "-i", "com.finderright.app.sync"]
                proc.standardOutput = pipe
                // 启动失败时管道写端仍在本进程手里，直接读会永远等不到 EOF
                guard (try? proc.run()) != nil else { return (-1, "") }
                // 先读到 EOF 再等待退出，避免输出超过管道缓冲时互相等待（同 ProcessRunner）
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (proc.terminationStatus, text)
            }

            // 1. 仅在「未注册」「注册路径变化」或「注册版本与当前 bundle 不一致（刚升级）」时才注册。
            //
            // ⚠️ 不要改回每次启动都无条件 `pluginkit -a`：重复注册会让插件 UUID 变新并重启扩展进程，
            // 重启后的扩展成为与其他 Finder Sync 扩展（如 Keka）重叠目录的**最后注册者**，
            // 从而失去这些目录的角标归属（Finder 只把 requestBadgeIdentifier 交给最先注册者，
            // 见 FinderSync.requestBadgeIdentifier 处的说明），表现为重启 App 后剪切角标整体失效。
            // 版本号一致即同一份插件，重复注册有害无益；只有版本变化才需要让 PluginKit 更新。
            let appexVersion = (NSDictionary(contentsOf: appexURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? ""
            var (status, output) = queryPluginState()
            let isCurrent = FinderSyncElection.isRegistrationCurrent(
                verboseOutput: output, appexPath: appexURL.path, version: appexVersion)
            if status != 0 || !isCurrent {
                let regProc = Process()
                regProc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                regProc.arguments = ["-a", appexURL.path]
                try? regProc.run()
                regProc.waitUntilExit()
                NSLog("[AppDelegate] 重新注册 FinderSync appex（未注册/路径或版本变化，当前 \(appexVersion)）: \(appexURL.path)")
                (status, output) = queryPluginState()
            } else {
                NSLog("[AppDelegate] FinderSync appex 已注册且版本一致 (\(appexVersion))，跳过 pluginkit -a（避免扰动角标回调）")
            }

            // 2. 读取插件当前选举状态（避免覆盖用户在系统设置里的显式禁用）
            let trimmed = output
            guard status == 0 else {
                NSLog("[AppDelegate] PlugInKit 查询失败 (exit=\(status))，跳过修改扩展启用状态")
                return
            }

            // 已启用时不反复注销/注册扩展，避免扰动 Finder 的回调路由。
            if trimmed.hasPrefix("+") {
                NSLog("[AppDelegate] FinderRightSync appex 已经处于启用状态 (+)，无需重复注册")
                return
            }

            // "-" 表示用户在系统设置里显式禁用了扩展（elected to ignore），必须尊重用户意图，禁止强制覆盖
            if trimmed.hasPrefix("-") {
                NSLog("[AppDelegate] FinderRightSync appex 已被用户手动关闭 (-)，尊重用户设置，跳过 pluginkit -e use")
                return
            }

            // 既非 "+" 也非 "-"（未选举的默认初始状态），进行首次自动开启
            let enableProc = Process()
            enableProc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            enableProc.arguments = ["-e", "use", "-i", "com.finderright.app.sync"]
            try? enableProc.run()
            enableProc.waitUntilExit()

            NSLog("[AppDelegate] FinderRightSync appex 首次注册并自动启用成功")
        }
    }

    // MARK: - 原生状态栏菜单

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true   // 模板图随明暗菜单栏自动反色
            button.image = image
            button.image?.size = NSSize(width: 18, height: 18)
            button.toolTip = "FinderRight"
        }
        item.menu = buildMenu()
        item.isVisible = showMenuBarIcon
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // 每次打开前由 menuNeedsUpdate 重建，「最近操作」区随之更新
        menu.delegate = self
        populate(menu)
        return menu
    }

    private func populate(_ menu: NSMenu) {
        let status = NSMenuItem(title: L("FinderRight 运行中"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        // 引导不再常驻菜单：只有扩展未启用（右键菜单完全不出现）时才给出修复入口。
        // 完全磁盘访问、辅助功能是可选授权，用户可能有意跳过，不在这里常驻提醒
        if !FinderExtensionChecker.check() {
            let setup = NSMenuItem(title: L("启用 Finder 扩展…"), action: #selector(openExtensionSetup), keyEquivalent: "")
            setup.target = self
            setup.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            setup.toolTip = L("扩展未启用时，访达右键菜单中不会出现 FinderRight")
            menu.addItem(setup)
        }
        menu.addItem(.separator())

        // 只在有可撤销的记录时出现；菜单栏入口不比对访达撤销项，点了就撤销 FinderRight 的记录。
        // 归在「显示最近操作」开关下：关掉后菜单栏不再出现撤销项，避免用户以为还有操作记录可看。
        // ⌘Z 拦截与访达右键菜单里的「撤销」不读这个开关，照常可用
        if showRecentActivity, let record = UndoCenter.shared.current {
            let state = UndoMenuState(kind: record.kind, count: record.count, name: record.name)
            let undo = NSMenuItem(title: UndoText.menuTitle(for: state, localize: L), action: #selector(undoLast), keyEquivalent: "")
            undo.target = self
            undo.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
            menu.addItem(undo)
            menu.addItem(.separator())
        }

        let records = RecentOperations.shared.records
        if !records.isEmpty {
            let header = NSMenuItem(title: L("最近操作"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for record in records {
                menu.addItem(recentOperationItem(for: record))
            }
            let clear = NSMenuItem(title: L("清除记录"), action: #selector(clearRecentOperations), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
            menu.addItem(.separator())
        }

        let settings = NSMenuItem(title: L("设置..."), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let update = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        update.target = self
        configureUpdateItem(update)
        menu.addItem(update)
        updateMenuItem = update

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("退出 FinderRight"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func L(_ key: String) -> String { NSLocalizedString(key, comment: "menu") }

    /// 菜单栏「撤销」走与 ⌘Z、右键菜单相同的 undoLast 处理
    private let undoService = FinderRightService()

    // MARK: - 检查更新

    /// 进行中时显示进度并禁用（action 置空后 NSMenu 自动置灰），空闲时可点
    private func configureUpdateItem(_ item: NSMenuItem) {
        let status = UpdateChecker.shared.currentStatus
        switch status {
        case .checking:
            item.title = L("正在检查更新…")
        case .downloading(let progress):
            item.title = String(format: L("正在下载更新… %d%%"), Int(progress * 100))
        case .installing:
            item.title = L("正在安装更新…")
        default:
            item.title = L("检查更新…")
        }
        item.action = status.isInProgress ? nil : #selector(checkForUpdates)
    }

    @objc private func updateStatusDidChange() {
        if let item = updateMenuItem { configureUpdateItem(item) }
    }

    /// 后台检查，结果用弹窗告知：已是最新直接提示，有新版本可一键下载安装并重启
    @objc private func checkForUpdates() {
        UpdateChecker.shared.check(force: true) { [weak self] status in
            guard let self else { return }
            switch status {
            case .upToDate:
                self.showUpToDateAlert()
            case .updateAvailable(let version, let releaseURL, let downloadURL, let checksum):
                self.promptUpdate(version: version, releaseURL: releaseURL, downloadURL: downloadURL, checksum: checksum)
            case .failed(let message):
                self.showUpdateFailure(title: self.L("无法检查更新"), message: message)
            default:
                break   // 检查中等中间状态由菜单项标题体现
            }
        }
    }

    private func showUpToDateAlert() {
        FRDialog(title: L("已是最新版本"),
                 message: String(format: L("FinderRight %@ 是目前的最新版本。"), UpdateChecker.shared.currentAppVersion),
                 symbol: "checkmark.seal", buttons: [L("好")]).runModal()
    }

    private func promptUpdate(version: String, releaseURL: URL, downloadURL: URL?, checksum: UpdateChecksum?) {
        let title = String(format: L("发现新版本 %@"), version)
        let current = UpdateChecker.shared.currentAppVersion

        // 发布缺少校验和时 downloadURL 为空，不能自动安装，只能去发布页手动下载
        guard let downloadURL else {
            let dialog = FRDialog(title: title,
                                  message: String(format: L("当前版本 %@。此版本不支持自动安装，请前往发布页下载。"), current),
                                  symbol: "arrow.down.circle", buttons: [L("前往下载"), L("稍后")])
            if dialog.runModal() == 0 {
                NSWorkspace.shared.open(releaseURL)
            }
            return
        }

        let dialog = FRDialog(title: title,
                              message: String(format: L("当前版本 %@。更新将在后台下载并安装，完成后 FinderRight 会自动重启。"), current),
                              symbol: "arrow.down.circle", buttons: [L("立即更新"), L("稍后"), L("查看更新说明")])
        dialog.cancelIndex = 1
        switch dialog.runModal() {
        case 0:
            // 成功时安装脚本会退出并重新拉起新版，这里只需处理失败；进度显示在菜单项标题上
            UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum) { [weak self] status in
                guard let self, case .failed(let message) = status else { return }
                self.showUpdateFailure(title: self.L("自动更新失败"), message: message)
            }
        case 2:
            NSWorkspace.shared.open(releaseURL)
        default:
            break
        }
    }

    private func showUpdateFailure(title: String, message: String) {
        FRDialog(title: title, message: message, symbol: "exclamationmark.triangle", tone: .warning,
                 buttons: [L("好")]).runModal()
    }

    // MARK: - 最近操作

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// - Parameter truncated: 菜单项用截断后的名称，避免长文件名把整个菜单撑宽；弹窗用完整名称
    private func recentOperationTitle(for record: OperationRecord, truncated: Bool = false) -> String {
        let format: String
        if record.cancelled {
            // 目前只有加密包的密码框能取消
            let subject = truncated ? OperationRecord.truncatedSubject(record.subject) : record.subject
            return String(format: L("已取消解压 %@"), subject)
        }
        switch (record.kind, record.succeeded) {
        case (.compress, true):    format = L("已压缩 %@")
        case (.compress, false):   format = L("压缩失败：%@")
        case (.decompress, true):  format = L("已解压 %@")
        case (.decompress, false): format = L("解压失败：%@")
        case (.paste, true):       format = L("已粘贴 %@")
        case (.paste, false):      format = L("粘贴失败：%@")
        case (.move, true):        format = L("已移动 %@")
        case (.move, false):       format = L("移动失败：%@")
        case (.copy, true):        format = L("已复制 %@")
        case (.copy, false):       format = L("复制失败：%@")
        case (.undo, true):        format = L("已撤销 %@")
        case (.undo, false):       format = L("撤销未完成：%@")
        }
        let subject = truncated ? OperationRecord.truncatedSubject(record.subject) : record.subject
        return String(format: format, subject)
    }

    private func recentOperationItem(for record: OperationRecord) -> NSMenuItem {
        let time = Self.timeFormatter.string(from: record.date)
        let item = NSMenuItem(title: "\(recentOperationTitle(for: record, truncated: true))  ·  \(time)",
                              action: #selector(recentOperationClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = record
        if record.cancelled {
            item.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            if OperationRecord.truncatedSubject(record.subject) != record.subject {
                item.toolTip = record.subject
            }
        } else if record.succeeded {
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            // 名称被截断时悬停可看完整名称；失败项的 toolTip 留给失败原因，完整名称在弹窗标题里
            if OperationRecord.truncatedSubject(record.subject) != record.subject {
                item.toolTip = record.subject
            }
        } else {
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            item.toolTip = record.failure
        }
        return item
    }

    /// 成功项：在访达中显示产物；失败项：弹窗说明原因；已取消项：没有产物也没有原因，不做任何事
    @objc private func recentOperationClicked(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? OperationRecord, !record.cancelled else { return }
        if record.succeeded {
            let existing = record.results.filter { FileManager.default.fileExists(atPath: $0.path) }
            if existing.isEmpty {
                NSSound.beep()
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(existing)
            }
            return
        }
        FRDialog(title: recentOperationTitle(for: record),
                 message: (record.failure ?? "") + "\n\n" + L("更多信息可在「控制台」App 中搜索 FinderRightService 查看。"),
                 symbol: "exclamationmark.triangle", tone: .warning, buttons: [L("好")]).runModal()
    }

    @objc private func undoLast() {
        _ = undoService.handle(IPCRequest(id: UUID().uuidString, action: "undoLast", payload: [:]))
    }

    @objc private func clearRecentOperations() {
        RecentOperations.shared.clear()
    }

    /// 有未查看的失败时把菜单栏图标染成红色，打开菜单后恢复。
    /// 用 contentTintColor 而不是自绘红点：模板图保持随明暗菜单栏自动反色
    @objc private func updateStatusIndicator() {
        guard let button = statusItem?.button else { return }
        let hasUnseenFailure = RecentOperations.shared.unseenFailureCount > 0
        button.contentTintColor = hasUnseenFailure ? .systemRed : nil
        button.toolTip = hasUnseenFailure ? L("有操作失败，点击查看") : "FinderRight"
    }

    // 供 Settings scene 的 ⌘, 命令与状态栏菜单共用（@objc 供 #selector 使用）
    @objc func openSettings() {
        NSApp.setActivationPolicy(.regular)
        // accessory→regular 切换需延一拍，否则窗口创建早于策略生效会不显示
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settingsWindow == nil {
                let hosting = NSHostingController(rootView: SettingsView())
                let win = NSWindow(contentViewController: hosting)
                win.title = "FinderRight"
                // 侧边栏延伸到标题栏下方：隐藏标题文字、标题栏透明。
                // 刻意不设 isMovableByWindowBackground：整窗背景拖动会和 SwiftUI 的拖拽排序抢事件，
                // 在 macOS 13 上表现为「拖手柄时窗口跟着鼠标走、无法换行」（Issue #7）。
                // 拖动窗口改用顶端一条显式的拖动条（installTitleDragBar）
                win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                win.titlebarAppearsTransparent = true
                win.titleVisibility = .hidden
                win.isReleasedWhenClosed = false
                // 先确定 SwiftUI 内容尺寸，避免按尚未布局的小窗口居中后再扩展而偏移。
                win.setContentSize(hosting.view.fittingSize)
                win.center()
                win.setFrameAutosaveName("FinderRightSettings")
                installTitleDragBar(in: win)
                self.settingsWindow = win
            }
            self.settingsWindow?.makeKeyAndOrderFront(nil)
            self.settingsWindow?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 在窗口顶端挂一条显式的拖动条，取代 isMovableByWindowBackground。
    /// 直接 addSubview 而不走 SwiftUI 的 overlay：NSViewRepresentable 能否拿到鼠标事件
    /// 取决于 SwiftUI 的命中测试，实测不稳定；这里需要的是确定性。
    private func installTitleDragBar(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let bar = WindowDragBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            // 让开红绿灯：即使它们与内容区的层叠顺序变化也不会被拖动条盖住
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 78),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    private func openGoToDirectory(initialPath: String = "", failure: String? = nil) {
        if let directoryDialog {
            directoryDialog.bringToFront()
            return
        }

        let home = IPCBridge.realUserHomeDirectory.path
        let dialog = FRDialog(
            title: L("打开路径"),
            message: failure ?? L("输入或粘贴文件、文件夹的路径（绝对路径或以 ~/ 开头）"),
            symbol: "arrow.right.circle",
            // 回车默认「在访达中显示」：文件会在所在文件夹中选中，文件夹直接打开
            buttons: [L("在访达中显示"), L("打开"), L("取消")],
            input: .text(initial: initialPath, placeholder: "/Users/… / ~/Documents/…",
                         accessibilityLabel: L("文件或文件夹路径"),
                         hint: { [weak self] input in self?.pathHint(for: input, home: home) }))
        dialog.validate = { [weak self] index in
            guard index != 2 else { return nil }
            do {
                _ = try DirectoryPath.resolve(dialog.text, home: home)
                return nil
            } catch let error as DirectoryPath.ValidationError {
                return self?.L(error.rawValue)
            } catch {
                return error.localizedDescription
            }
        }
        directoryDialog = dialog
        let response = dialog.runModal()
        directoryDialog = nil

        guard response == 0 || response == 1,
              let target = try? DirectoryPath.resolve(dialog.text, home: home) else { return }
        let enteredPath = dialog.text
        let reopenOnFailure: (Error?) -> Void = { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.openGoToDirectory(initialPath: enteredPath, failure: error.localizedDescription)
            }
        }
        switch target {
        case .file(let file) where response == 0:
            NSWorkspace.shared.activateFileViewerSelecting([file])
        case .file(let file):
            // 与在访达中双击相同：交给该文件的默认 App
            NSWorkspace.shared.open(file, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                reopenOnFailure(error)
            }
        case .directory(let directory):
            guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
                openGoToDirectory(initialPath: enteredPath, failure: L("无法打开目录，请检查访问权限"))
                return
            }
            NSWorkspace.shared.open([directory], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                reopenOnFailure(error)
            }
        }
    }

    /// 输入框下方的实时识别：是文件还是文件夹、位于哪里
    private func pathHint(for input: String, home: String) -> FRDialog.Hint? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let abbreviate = { (path: String) -> String in
            path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        switch try? DirectoryPath.resolve(input, home: home) {
        case .file(let file):
            return FRDialog.Hint(symbol: "doc", text: String(format: L("文件 · 位于 %@"), abbreviate(file.deletingLastPathComponent().path)), ok: true)
        case .directory(let directory):
            return FRDialog.Hint(symbol: "folder", text: String(format: L("文件夹 · %@"), abbreviate(directory.path)), ok: true)
        case nil:
            return FRDialog.Hint(symbol: "questionmark.circle", text: L("未找到这个路径"), ok: false)
        }
    }

    /// 设置页「重新查看引导」：从头开始
    @objc private func openOnboarding() {
        showOnboarding()
    }

    /// 菜单栏「启用 Finder 扩展…」：直接从扩展步骤开始
    @objc private func openExtensionSetup() {
        showOnboarding(startingAt: OnboardingView.extensionStep)
    }

    /// 引导窗口已打开时只把它提到前面，不重置用户当前所在的步骤
    private func showOnboarding(startingAt step: Int = 0) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.onboardingWindow == nil {
                let hosting = NSHostingController(rootView: OnboardingView(initialStep: step, onClose: { [weak self] in
                    self?.onboardingWindow?.close()
                }))
                let win = NSWindow(contentViewController: hosting)
                win.title = self.L("欢迎使用 FinderRight")
                win.styleMask = [.titled, .closable, .fullSizeContentView]
                win.titlebarAppearsTransparent = true
                win.titleVisibility = .hidden
                win.isMovableByWindowBackground = true
                win.isReleasedWhenClosed = false
                win.setContentSize(NSSize(width: 600, height: 500))
                win.center()
                self.onboardingWindow = win
            }
            self.onboardingWindow?.makeKeyAndOrderFront(nil)
            self.onboardingWindow?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 退出前等待后台任务

    /// 菜单退出、自动更新、切换语言重启都会走到这里。有压缩 / 解压 / 粘贴在途时延后退出，
    /// 手动退出最多等 30 秒（粘贴另有崩溃恢复兜底）；自动安装则等待任务完成。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let jobs = FinderRightService.backgroundJobs
        guard !jobs.isIdle else { return .terminateNow }
        NSLog("[AppDelegate] 有后台任务进行中，等待完成后再退出")
        DispatchQueue.global(qos: .userInitiated).async {
            // 自动安装不打断耗时文件操作；手动退出沿用原有 30 秒上限。
            let automaticInstall = UpdateChecker.shared.isAutomaticInstall
            var finished: Bool
            repeat {
                finished = jobs.waitUntilIdle(timeout: 30)
            } while automaticInstall && !finished
            NSLog("[AppDelegate] 后台任务\(finished ? "已完成" : "等待超时（30s）")，继续退出")
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        UndoCenter.shared.clear()
    }

    // MARK: - Reopen 响应（Spotlight / 启动台 / 访达重复打开）

    /// 只在用户主动"重新打开"已运行的 App（双击图标、启动台、Spotlight 回车）时由系统派发；
    /// 首次启动另由 LaunchPresentation 判断来源；Services 和 IPC 唤醒不应弹设置。
    ///
    /// ⚠️ 不要在 applicationDidBecomeActive 或 kAEOpenApplication/kAEReopenApplication
    /// AppleEvent 里弹设置：Services 派发会激活 App、IPC 冷启动会收到 kAEOpenApplication，
    /// 都会导致右键"打开终端"时误弹设置窗口并抢焦（2026-09 已修，勿回归）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSLog("[AppDelegate] applicationShouldHandleReopen: hasVisibleWindows=\(flag)")
        openSettings()
        return true
    }

    // MARK: - 偏好变化

    /// 防止 defaultsChanged 重入：
    /// 设置 NSStatusItem.isVisible 时，AppKit 会把可见性自动保存写回 UserDefaults，
    /// 并同步再次发出 didChangeNotification。若无保护，defaultsChanged → setVisible
    /// → 通知 → defaultsChanged 无限递归，最终栈溢出崩溃（EXC_BAD_ACCESS）。
    /// 重入瞬间 isVisible 读到的仍是旧值，靠 "值是否相等" 判断挡不住，必须用标志位。
    private var isUpdatingStatusItemVisibility = false

    @objc private func defaultsChanged() {
        UpdateChecker.shared.configureAutomaticUpdates()

        // 「最近操作」开关：关闭时 RecentOperations 自行清空记录并通知刷新图标提示
        let wantRecent = showRecentActivity
        if RecentOperations.shared.isEnabled != wantRecent {
            RecentOperations.shared.isEnabled = wantRecent
        }

        // 实时同步菜单栏图标显隐（设置里 showMenuBarIcon 改变时）
        guard !isUpdatingStatusItemVisibility else { return }
        let want = showMenuBarIcon
        guard statusItem?.isVisible != want else { return }
        isUpdatingStatusItemVisibility = true
        defer { isUpdatingStatusItemVisibility = false }
        statusItem?.isVisible = want
    }

    // MARK: - 窗口与激活策略

    /// 打开普通窗口（设置/引导）前调用：
    /// accessory App 无法正常显示并聚焦窗口，先临时切为 regular 再激活。
    func beginShowingStandardWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 标准窗口关闭后，如果用户没要求常驻 Dock，且已无可见标准窗口，则切回 accessory
    @objc private func windowWillClose(_ note: Notification) {
        if let closing = note.object as? NSWindow {
            if closing === settingsWindow {
                // 关闭后 AppKit 可能仍持有窗口，释放保存名称供下次创建恢复。
                closing.setFrameAutosaveName("")
                settingsWindow = nil
            }
            if closing === onboardingWindow { onboardingWindow = nil }
        }
        guard !alwaysShowDockIcon else { return }
        let closing = note.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            let stillHasStandardWindow = NSApp.windows.contains { w in
                w !== closing && w.isVisible && w.canBecomeMain
            }
            if !stillHasStandardWindow {
                NSApp.setActivationPolicy(.accessory)
            }
            _ = self
        }
    }

    // MARK: - finderright:// 入口

    /// 在 willFinishLaunching 注册：冷启动时拉起 App 的那条 URL 事件紧随其后派发，晚了会错过。
    /// 注册后 AppKit 不再调用 application(_:open:)，所有 finderright:// URL 都经由 handleGetURLEvent。
    /// 直接处理 Apple Event 是为了拿到发送方的 audit token —— application(_:open:) 拿不到。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == IPCBridge.urlScheme else { return }
        receivedLaunchURL = true

        // 打开设置窗口无副作用，任何来源都可以。
        if url.host == "settings" || url.host == "preferences" {
            // 可带页名直达某一页，如 finderright://settings/favorites；未知页名忽略，停留在当前页
            let page = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let tab = SettingsView.SettingsTab.allCases.first(where: { $0.urlName == page }) {
                SettingsNavigation.shared.selectedTab = tab
            }
            // 冷启动时先完成激活策略初始化，再切为 regular 显示窗口。
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
            return
        }

        // URL 只打开输入框，路径必须由用户输入，不从外部请求接收。
        if url.host == "go-to-directory" {
            DispatchQueue.main.async { [weak self] in self?.openGoToDirectory() }
            return
        }

        // 执行类请求会以「完全磁盘访问」身份读写文件：只受理本 App 内嵌的 FinderSync 扩展发来的。
        // 比对的是磁盘上内嵌扩展自己的签名规则，ad-hoc 与证书签名都适用（见 CodeSignatureCheck）
        guard let token = event.attributeDescriptor(forKeyword: keySenderAuditTokenAttr)?.data,
              let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FinderRightSync.appex"),
              CodeSignatureCheck.process(auditToken: token, satisfiesDesignatedRequirementOf: appex) else {
            NSLog("[AppDelegate] 拒绝来源未通过校验的请求: \(url.absoluteString)")
            return
        }
        IPCWatcher.shared.handle(url: url)
    }
}

// MARK: - 状态栏菜单刷新

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

    /// 用户打开菜单即看到了「最近操作」里的失败项，撤掉图标提示
    func menuWillOpen(_ menu: NSMenu) {
        RecentOperations.shared.markFailuresSeen()
    }
}

// MARK: - 窗口拖动条

/// 窗口顶端的拖动条：只有这一条响应「拖窗口」。
///
/// 之前用 isMovableByWindowBackground 让整个窗口背景可拖，它会和 SwiftUI 的拖拽会话抢同一个
/// mouseDown：在 macOS 13 上两条路径同时启动，窗口跟着鼠标走，指针相对列表行的位移恒为 0，
/// 拖拽排序因此永远换不了行（Issue #7）。改成只留一条后既彻底避开抢事件，
/// 也符合设置窗口「点开关时不该把窗口拖走」的预期。
private final class WindowDragBar: NSView {
    override var isOpaque: Bool { false }

    /// 窗口未激活时第一次按下也能直接开拖，与系统标题栏一致
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // 双击与系统标题栏行为保持一致（设置 - 桌面与程序坞 - 双击窗口标题栏）
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}
