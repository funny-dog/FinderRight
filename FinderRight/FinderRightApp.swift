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

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var directoryAlert: NSAlert?

    /// 用户是否要求常驻显示 Dock 图标
    private var alwaysShowDockIcon: Bool {
        UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
    }

    /// 用户是否显示菜单栏图标
    private var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 「切换隐藏文件」在扩展端是无状态固定文案（见 FinderSync.menu(for:) 里该菜单项的说明），
        // 不再需要在启动时把 SharedConfig 锚定到 Finder 真实状态。

        // 根据偏好动态设定激活策略
        if alwaysShowDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
        NSLog("[AppDelegate] activation policy = \(alwaysShowDockIcon ? "regular" : "accessory")")

        setupStatusItem()

        // 注册 macOS Services：让右键操作在 iCloud / Google Drive 等 File Provider
        // 云盘文件夹中也可用（FinderSync 扩展在这些目录被系统架构性禁止）。
        ServicesProvider.register()

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

        // 首次启动：若尚未完成引导，自动弹出引导设置窗口
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if !hasCompletedOnboarding {
            // 弹出即视为已完成：用户若用红点直接关窗，OnboardingView 的「开始使用」不会执行，
            // 标志位会一直是 false，导致此后每次冷启动（含右键 IPC 冷启动、开机自启）
            // 都重复弹引导并抢焦。用户已看过引导即视为完成。
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            openOnboarding()
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
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = NSLocalizedString("自动更新失败", comment: "alert")
                alert.informativeText = content.trimmingCharacters(in: .whitespacesAndNewlines)
                alert.alertStyle = .warning
                alert.runModal()
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
        menu.addItem(.separator())

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

        let onboarding = NSMenuItem(title: L("引导设置"), action: #selector(openOnboarding), keyEquivalent: "")
        onboarding.target = self
        menu.addItem(onboarding)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("退出 FinderRight"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func L(_ key: String) -> String { NSLocalizedString(key, comment: "menu") }

    // MARK: - 最近操作

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private func recentOperationTitle(for record: OperationRecord) -> String {
        let format: String
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
        }
        return String(format: format, record.subject)
    }

    private func recentOperationItem(for record: OperationRecord) -> NSMenuItem {
        let time = Self.timeFormatter.string(from: record.date)
        let item = NSMenuItem(title: "\(recentOperationTitle(for: record))  ·  \(time)",
                              action: #selector(recentOperationClicked(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = record
        if record.succeeded {
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        } else {
            item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            item.toolTip = record.failure
        }
        return item
    }

    /// 成功项：在访达中显示产物；失败项：弹窗说明原因
    @objc private func recentOperationClicked(_ sender: NSMenuItem) {
        guard let record = sender.representedObject as? OperationRecord else { return }
        if record.succeeded {
            let existing = record.results.filter { FileManager.default.fileExists(atPath: $0.path) }
            if existing.isEmpty {
                NSSound.beep()
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(existing)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = recentOperationTitle(for: record)
        alert.informativeText = (record.failure ?? "") + "\n\n" + L("更多信息可在「控制台」App 中搜索 FinderRightService 查看。")
        alert.addButton(withTitle: L("好"))
        alert.runModal()
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
                // 侧边栏延伸到标题栏下方：隐藏标题文字、标题栏透明，整个窗口背景都可拖动
                win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                win.titlebarAppearsTransparent = true
                win.titleVisibility = .hidden
                win.isMovableByWindowBackground = true
                win.isReleasedWhenClosed = false
                // 先确定 SwiftUI 内容尺寸，避免按尚未布局的小窗口居中后再扩展而偏移。
                win.setContentSize(hosting.view.fittingSize)
                win.center()
                win.setFrameAutosaveName("FinderRightSettings")
                self.settingsWindow = win
            }
            self.settingsWindow?.makeKeyAndOrderFront(nil)
            self.settingsWindow?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openGoToDirectory(initialPath: String = "", failure: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let directoryAlert {
            directoryAlert.window.makeKeyAndOrderFront(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = L("前往目录…")
        alert.informativeText = failure ?? L("输入绝对路径或以 ~/ 开头的路径")
        alert.addButton(withTitle: L("打开"))
        alert.addButton(withTitle: L("取消"))
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        input.stringValue = initialPath
        input.placeholderString = "/Users/… / ~/Documents"
        input.setAccessibilityLabel(L("目录路径"))
        input.cell?.isScrollable = true
        input.cell?.wraps = false
        input.cell?.usesSingleLineMode = true
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        directoryAlert = alert
        defer { directoryAlert = nil }

        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let directory = try DirectoryPath.url(for: input.stringValue, home: IPCBridge.realUserHomeDirectory.path)
                guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
                    alert.informativeText = L("无法打开目录，请检查访问权限")
                    continue
                }
                let enteredPath = input.stringValue
                NSWorkspace.shared.open([directory], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                    guard let error else { return }
                    DispatchQueue.main.async {
                        self?.openGoToDirectory(initialPath: enteredPath, failure: error.localizedDescription)
                    }
                }
                return
            } catch let error as DirectoryPath.ValidationError {
                alert.informativeText = L(error.rawValue)
            } catch {
                alert.informativeText = error.localizedDescription
            }
            alert.window.initialFirstResponder = input
        }
    }

    @objc private func openOnboarding() {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.onboardingWindow == nil {
                let hosting = NSHostingController(rootView: OnboardingView(onClose: { [weak self] in
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
    /// 最多等 30 秒：粘贴另有 in-flight 崩溃恢复兜底，超时后照常退出
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let jobs = FinderRightService.backgroundJobs
        guard !jobs.isIdle else { return .terminateNow }
        NSLog("[AppDelegate] 有后台任务进行中，等待完成后再退出")
        DispatchQueue.global(qos: .userInitiated).async {
            let finished = jobs.waitUntilIdle(timeout: 30)
            NSLog("[AppDelegate] 后台任务\(finished ? "已完成" : "等待超时（30s）")，继续退出")
            DispatchQueue.main.async {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    // MARK: - Reopen 响应（Spotlight / 启动台 / 访达重复启动时弹出设置的唯一入口）

    /// 只在用户主动"重新打开"已运行的 App（双击图标、启动台、Spotlight 回车）时由系统派发；
    /// Services 派发、finderright:// IPC 唤醒均不会触发，是弹设置的唯一安全入口。
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

        // 打开设置窗口无副作用，任何来源都可以（切换语言后的重启脚本就靠它）
        if url.host == "settings" || url.host == "preferences" {
            // 可带页名直达某一页，如 finderright://settings/favorites；未知页名忽略，停留在当前页
            let page = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let tab = SettingsView.SettingsTab.allCases.first(where: { $0.urlName == page }) {
                SettingsNavigation.shared.selectedTab = tab
            }
            openSettings()
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
