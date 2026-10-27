import SwiftUI
import AppKit
import ServiceManagement
import FinderRightKit

// MARK: - 通用 Tab

struct GeneralTab: View {
    @AppStorage(UpdateChecker.automaticUpdatesKey) private var automaticUpdates = false
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("showDockIcon") private var showDockIcon = false
    @FRState private var menuIconStyle: MenuIconStyle = SharedConfig.shared.menuIconStyle
    @FRState private var appLanguage: String = SharedConfig.shared.appLanguage
    @AppStorage(FRThemeID.storageKey) private var themeRaw = FRThemeID.midnight.rawValue
    @AppStorage(FRAppearanceMode.storageKey) private var appearanceRaw = FRAppearanceMode.system.rawValue
    @FRState private var launchAtLoginError: String?
    @FRState private var currentLoginStatus: SMAppService.Status = .notRegistered

    var body: some View {
        FRPage(title: "通用", subtitle: "启动、显示与外观") {
            launchSection
            updateSection
            displaySection
        }
        .onAppear {
            calibrateLaunchAtLoginStatus()
            menuIconStyle = SharedConfig.shared.menuIconStyle
            appLanguage = SharedConfig.shared.appLanguage
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calibrateLaunchAtLoginStatus()
            menuIconStyle = SharedConfig.shared.menuIconStyle
            appLanguage = SharedConfig.shared.appLanguage
        }
    }

    // MARK: 启动

    private var launchSection: some View {
        FRSection("启动") {
            FRCard {
                // 登录时自动运行 FinderRight
                FRRow(title: Text("开机自动启动")) {
                    FRSwitch(label: "开机自动启动", isOn: Binding(
                        get: { launchAtLogin },
                        set: { updateLaunchAtLogin(to: $0) }
                    ))
                }

                if let error = launchAtLoginError {
                    FRDivider()
                    Text(verbatim: error)
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }

                if currentLoginStatus == .requiresApproval {
                    FRDivider()
                    HStack(spacing: 12) {
                        Text("已注册，但需要在「系统设置」-「通用」-「登录项与扩展」（macOS 14 及更早为「登录项」）中允许启动")
                            .font(.system(size: 12))
                            .foregroundColor(FRTheme.warnText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("打开系统设置") {
                            LaunchAtLoginManager.openLoginItemsSettings()
                        }
                        .buttonStyle(.frSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    private var updateSection: some View {
        FRSection("更新") {
            FRCard {
                // 开启后立即检查，之后每 6 小时检查一次；空闲时下载并安装，完成后自动重启。默认关闭。
                FRRow(title: Text("自动检查并安装更新")) {
                    FRSwitch(label: "自动检查并安装更新", isOn: $automaticUpdates)
                }
            }
            // 关闭后不再发起自动更新；已经开始的更新仍会完成。
        }
    }

    // MARK: 显示

    private var displaySection: some View {
        FRSection("显示") {
            FRCard {
                let theme = FRThemeID(rawValue: themeRaw) ?? .midnight
                FRRow(title: Text("主题色"), subtitle: Text(LocalizedStringKey(theme.titleKey))) {
                    FRThemeSwatches(selection: Binding(
                        get: { theme },
                        set: { newValue in
                            // 先更新动态颜色读取的当前主题，再写存储触发重建
                            FRThemeID.current = newValue
                            themeRaw = newValue.rawValue
                        }
                    ))
                }

                FRDivider()

                FRRow(title: Text("深色模式")) {
                    FRPicker(label: "深色模式", selection: Binding(
                        get: { FRAppearanceMode(rawValue: appearanceRaw) ?? .system },
                        set: { newValue in
                            appearanceRaw = newValue.rawValue
                            newValue.apply()
                        }
                    )) {
                        ForEach(FRAppearanceMode.allCases) { mode in
                            Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                        }
                    }
                }

                FRDivider()

                FRRow(title: Text("语言")) {
                    FRPicker(label: "语言", selection: Binding(
                        get: { appLanguage },
                        set: { changeLanguage(to: $0) }
                    )) {
                        Text("跟随系统").tag("system")
                        Text("中文").tag("zh-Hans")
                        Text("English").tag("en")
                    }
                }

                FRDivider()

                FRRow(title: Text("右键菜单图标")) {
                    HStack(spacing: 12) {
                        MenuIconPreview(style: menuIconStyle)

                        FRPicker(label: "右键菜单图标", selection: Binding(
                            get: { menuIconStyle },
                            set: { newValue in
                                menuIconStyle = newValue
                                SharedConfig.shared.menuIconStyle = newValue
                            }
                        )) {
                            ForEach(MenuIconStyle.allCases) { style in
                                Text(LocalizedStringKey(style.titleKey)).tag(style)
                            }
                        }
                    }
                }

                FRDivider()

                // 关闭后，菜单栏不显示 FinderRight 图标
                FRRow(title: Text("显示菜单栏图标")) {
                    FRSwitch(label: "显示菜单栏图标", isOn: $showMenuBarIcon)
                }

                FRDivider()

                FRRow(title: Text("显示程序坞图标"), subtitle: Text("关闭后，FinderRight 在 Dock 中隐藏（仍可后台运行）")) {
                    FRSwitch(label: "显示程序坞图标", isOn: $showDockIcon)
                }
                .onChange(of: showDockIcon) { newValue in
                    applyDockIconPreference(newValue)
                }
            }

            FRFootnote(Text("切换语言将立即自动重启应用以生效"))
            FRFootnote(Text("云盘文件夹中的「服务」菜单由 macOS 按系统语言显示，不受此设置影响。"))

            if !showMenuBarIcon && !showDockIcon {
                Label {
                    Text("两个图标都关闭后，可通过 Spotlight 搜索「FinderRight」重新打开偏好设置")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 12))
                .foregroundColor(FRTheme.warnText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            }
        }
    }

    // MARK: 行为

    private func changeLanguage(to newValue: String) {
        guard newValue != appLanguage else { return }
        appLanguage = newValue
        SharedConfig.shared.appLanguage = newValue
        if newValue == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
        relaunchApp()
    }

    private func applyDockIconPreference(_ show: Bool) {
        if show {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            // setActivationPolicy(.accessory) 会在下一个 RunLoop 隐藏所有窗口；
            // 先捕获当前窗口引用，async 延后重新显示，避免设置界面被关掉。
            let win = NSApp.keyWindow
            NSApp.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                win?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func updateLaunchAtLogin(to newValue: Bool) {
        launchAtLoginError = nil
        do {
            try LaunchAtLoginManager.shared.setEnabled(newValue)
            launchAtLogin = newValue
            currentLoginStatus = LaunchAtLoginManager.shared.status
        } catch {
            NSLog("[SettingsView] 设置开机自动启动失败 (\(newValue ? "开启" : "关闭")): \(error)")
            // 回滚开关状态到系统实际状态
            launchAtLogin = LaunchAtLoginManager.shared.isEnabled
            currentLoginStatus = LaunchAtLoginManager.shared.status
            launchAtLoginError = "设置开机自动启动失败: \(error.localizedDescription)"
        }
    }

    private func calibrateLaunchAtLoginStatus() {
        let status = LaunchAtLoginManager.shared.status
        currentLoginStatus = status
        let isEnabled = LaunchAtLoginManager.shared.isEnabled
        if launchAtLogin != isEnabled {
            NSLog("[SettingsView] 校准开机自启状态: 本地=\(launchAtLogin) -> 系统=\(isEnabled) (系统状态: \(LaunchAtLoginManager.shared.statusDescription(status)))")
            launchAtLogin = isEnabled
        }
    }

    private func relaunchApp() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = PathFormatter.shellQuoted(Bundle.main.bundleURL.path)
        // 不要在这里 killall FinderRightSync：扩展每次构建菜单都实时读取 appLanguage，无需重启；
        // 而扩展进程重启会使其成为重叠目录的最后注册者、丢失剪切角标归属，
        // 进而触发一轮对其他访达扩展的重启抢回（见 BadgeOwnershipManager）。
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do
            /bin/sleep 0.1
        done
        /usr/bin/open -a \(appPath) --args \(LaunchPresentation.showSettingsArgument)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        try? proc.run()
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
