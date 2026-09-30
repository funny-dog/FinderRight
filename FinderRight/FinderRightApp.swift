import SwiftUI
import UserNotifications
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

    /// 用户是否要求常驻显示 Dock 图标
    private var alwaysShowDockIcon: Bool {
        UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
    }

    /// 用户是否显示菜单栏图标
    private var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 请求本地通知权限（用于异步失败通知与系统告警）
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

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

    /// 检查旧版 staging/ 目录是否存在遗留文件，仅提醒用户，不自动移动或删除
    private func checkLegacyStagingDirectory() {
        // 一次性提醒：发送成功后才置位，避免每次冷启动重复弹同一条通知
        let sentKey = "stagingLegacyWarningSent"
        guard !UserDefaults.standard.bool(forKey: sentKey) else { return }

        let stagingDir = IPCBridge.rootDirectory.appendingPathComponent("staging", isDirectory: true)
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: stagingDir.path), !items.isEmpty {
            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("发现暂存区遗留文件", comment: "notification")
            content.body = String(
                format: NSLocalizedString("暂存区有 %d 个历史遗留文件，位于 ~/Library/Application Support/FinderRight/staging", comment: "notification"),
                items.count)
            content.sound = .default
            let req = UNNotificationRequest(identifier: "staging-legacy-warning", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { _ in
                UserDefaults.standard.set(true, forKey: sentKey)
            }
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
            // 1. 注册插件到 PluginKit
            let regProc = Process()
            regProc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            regProc.arguments = ["-a", appexURL.path]
            try? regProc.run()
            regProc.waitUntilExit()

            // 2. 查询插件当前选举状态（避免覆盖用户在系统设置里的显式禁用）
            let matchProc = Process()
            let pipe = Pipe()
            matchProc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            matchProc.arguments = ["-m", "-i", "com.finderright.app.sync"]
            matchProc.standardOutput = pipe
            try? matchProc.run()
            matchProc.waitUntilExit()

            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

            // "+" 表示已处于启用状态（elected to use），无需重复开启
            if trimmed.hasPrefix("+") {
                NSLog("[AppDelegate] FinderRightSync appex 已经处于启用状态 (+)，无需重复执行 pluginkit -e use")
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

        let status = NSMenuItem(title: L("FinderRight 运行中"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

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

        return menu
    }

    private func L(_ key: String) -> String { NSLocalizedString(key, comment: "menu") }

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
                win.styleMask = [.titled, .closable, .miniaturizable]
                win.isReleasedWhenClosed = false
                win.center()
                self.settingsWindow = win
            }
            self.settingsWindow?.makeKeyAndOrderFront(nil)
            self.settingsWindow?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
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
            if closing === settingsWindow { settingsWindow = nil }
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

    /// 处理 finderright:// URL scheme（IPC 唤醒入口，以及外部打开设置的命令）
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("[AppDelegate] application(open:) urls=\(urls)")
        for url in urls {
            if url.host == "settings" || url.host == "preferences" {
                openSettings()
            } else {
                IPCWatcher.shared.handle(url: url)
            }
        }
    }
}
