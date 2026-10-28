import SwiftUI
import FinderRightKit

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    var statusItem: NSStatusItem?
    var onboardingWindow: NSWindow?
    var settingsWindow: NSWindow?
    var receivedLaunchURL = false
    var directoryDialog: FRDialog?
    /// 菜单打开期间随更新状态刷新标题（检查中 / 下载进度 / 安装中）
    weak var updateMenuItem: NSMenuItem?

    /// 用户是否要求常驻显示 Dock 图标
    var alwaysShowDockIcon: Bool {
        UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? false
    }

    /// 用户是否显示菜单栏图标
    var showMenuBarIcon: Bool {
        UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
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

        RecentOperations.shared.setCapacity(UserDefaults.standard.object(forKey: RecentOperations.capacityKey) as? Int ?? 100)
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

        // 失败反馈独立于历史保留条数与菜单栏图标。
        NotificationCenter.default.addObserver(
            self, selector: #selector(operationDidFinish(_:)),
            name: RecentOperations.didFinishNotification, object: nil)

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

    var isUpdatingStatusItemVisibility = false
}
