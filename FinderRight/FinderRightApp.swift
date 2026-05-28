import SwiftUI

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
        // 设置窗口保留 SwiftUI Settings scene（提供 ⌘, 与标准设置窗口）。
        // 菜单栏入口与引导窗口改由 AppDelegate 用原生 AppKit 管理，
        // 以兼容 Ice/Thaw/Bartender 等菜单栏管理器（SwiftUI MenuBarExtra 与它们不兼容）。
        Settings {
            SettingsView()
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
        // 启动时的 Dock 图标策略（LSUIElement=YES 默认无 Dock 图标）
        if alwaysShowDockIcon {
            NSApp.setActivationPolicy(.regular)
        }
        NSLog("[AppDelegate] activation policy = \(alwaysShowDockIcon ? "regular" : "accessory")")

        setupStatusItem()

        // 监听窗口关闭：当所有标准窗口都关闭后，恢复 accessory（隐藏 Dock 图标）
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)

        // 监听偏好变化：实时切换菜单栏图标显隐
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification, object: nil)
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

    @objc private func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        }
    }

    @objc private func openOnboarding() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 偏好变化

    @objc private func defaultsChanged() {
        // 实时同步菜单栏图标显隐（设置里 showMenuBarIcon 改变时）
        let want = showMenuBarIcon
        if statusItem?.isVisible != want {
            statusItem?.isVisible = want
        }
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

    /// 处理 finderright:// URL scheme（IPC 唤醒入口）
    func application(_ application: NSApplication, open urls: [URL]) {
        NSLog("[AppDelegate] application(open:) urls=\(urls)")
        for url in urls {
            IPCWatcher.shared.handle(url: url)
        }
    }
}
