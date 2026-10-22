import SwiftUI
import AppKit
import CoreServices
import FinderRightKit
import ServiceManagement

// MARK: - SettingsView

/// 设置窗口当前显示的标签页。由 finderright://settings/<页名> 链接驱动（例如右键「管理常用目录…」）
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsView.SettingsTab = .general
}

/// 设置窗口：左侧侧边栏导航 + 右侧卡片式内容。窗口为无标题栏样式，侧边栏延伸到红绿灯下方。
struct SettingsView: View {
    enum SettingsTab: String, CaseIterable {
        case general = "通用"
        case features = "功能"
        case newFile = "文件模板"
        case favorites = "常用目录"
        case shortcuts = "快捷键"
        case tools = "终端"
        case editors = "编辑器"
        case history = "操作历史"
        case permissions = "权限与扩展"
        case about = "关于"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .features: return "slider.horizontal.3"
            case .favorites: return "folder"
            case .shortcuts: return "keyboard"
            case .newFile: return "doc.badge.plus"
            case .tools: return "terminal"
            case .editors: return "curlybraces"
            case .history: return "clock.arrow.circlepath"
            case .permissions: return "checkmark.shield"
            case .about: return "info.circle"
            }
        }

        /// finderright://settings/<urlName> 中使用的页名
        var urlName: String {
            switch self {
            case .general: return "general"
            case .features: return "features"
            case .favorites: return "favorites"
            case .shortcuts: return "shortcuts"
            case .newFile: return "newfile"
            case .tools: return "tools"
            case .editors: return "editors"
            case .history: return "history"
            case .permissions: return "permissions"
            case .about: return "about"
            }
        }
    }

    @ObservedObject private var navigation = SettingsNavigation.shared
    @AppStorage(FRThemeID.storageKey) private var themeRaw = FRThemeID.midnight.rawValue

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $navigation.selectedTab)

            Rectangle()
                .fill(FRTheme.border)
                .frame(width: 1)

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FRTheme.window)
        }
        // 主题色变化时整棵视图重建，让所有动态颜色按新主题重新取值
        .id(themeRaw)
        .frame(minWidth: 680, idealWidth: 780, maxWidth: .infinity,
               minHeight: 500, idealHeight: 620, maxHeight: .infinity)
        .background(FRTheme.window)
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.selectedTab {
        case .general: GeneralTab()
        case .features: FeaturesTab()
        case .favorites: FavoritesTab()
        case .shortcuts: ShortcutsTab()
        case .newFile: NewFileTab()
        case .tools: ToolsTab()
        case .editors: EditorsTab()
        case .history: OperationHistoryView()
        case .permissions: PermissionsTab()
        case .about: AboutTab()
        }
    }
}

// MARK: - 侧边栏

private struct SettingsSidebar: View {
    @Binding var selection: SettingsView.SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部留出红绿灯的位置
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                Text(verbatim: "FinderRight")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FRTheme.text)
            }
            .padding(.top, 46)
            .padding(.horizontal, 16)

            VStack(spacing: 2) {
                ForEach(SettingsView.SettingsTab.allCases, id: \.self) { tab in
                    SidebarItem(tab: tab, isSelected: selection == tab) {
                        selection = tab
                    }
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 10)

            Spacer(minLength: 0)

            Text(verbatim: "v\(UpdateChecker.shared.currentAppVersion)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(FRTheme.mute)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(FRTheme.sidebar)
    }
}

private struct SidebarItem: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @FRState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundColor(isSelected ? FRTheme.accentText : FRTheme.mute)
                Text(LocalizedStringKey(tab.rawValue))
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? FRTheme.text : FRTheme.mute)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? FRTheme.selection : (isHovering ? FRTheme.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

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

// MARK: - 权限与扩展 Tab

struct PermissionsTab: View {
    var body: some View {
        FRPage(title: "权限与扩展", subtitle: "管理访达扩展与系统授权") {
            // 从下载目录直接打开时先提醒：这种运行方式会让扩展状态与唤醒行为都不正常
            if AppRuntime.isTranslocated {
                translocationNotice
            }

            FRSection("扩展") {
                FRCard {
                    FinderExtensionView()
                }
            }

            FRSection("系统权限") {
                FRCard {
                    FullDiskAccessView()
                    FRDivider()
                    AccessibilityView()
                }

                FRFootnote(Text("「完全磁盘访问」让你能在 ~/Documents、~/Desktop、~/Pictures 等受保护目录使用所有功能。「辅助功能」让「切换隐藏文件」无需重启访达，不会关闭访达窗口或中断拷贝。"))
            }

            FRSection {
                HStack {
                    FRCaption("排查与引导")
                    Spacer()
                    Button("重新查看引导") {
                        NotificationCenter.default.post(name: .openOnboarding, object: nil)
                    }
                    .buttonStyle(.frLink)
                    .padding(.trailing, 4)
                }
            } content: {
                FRCard {
                    FRRow(title: Text("右键菜单排查"), subtitle: Text("若右键未显示菜单，可尝试重启访达或检查扩展开关")) {
                        HStack(spacing: 8) {
                            Button("重启访达") { FinderRelauncher.relaunch() }
                                .buttonStyle(.frSecondary)

                            Button("扩展设置...") {
                                FinderExtensionChecker.openSettings()
                            }
                            .buttonStyle(.frSecondary)
                        }
                    }
                }
            }
        }
    }

    /// 运行在 App Translocation 临时副本时的提示（见 AppRuntime.isTranslocated）
    private var translocationNotice: some View {
        FRCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.warnText)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("FinderRight 正在以临时副本运行")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FRTheme.text)
                    Text("当前是从下载目录直接打开的，macOS 会把它挂载到只读的临时路径下运行，扩展状态判断与「新建文件」等操作可能表现异常。把 FinderRight 拖到「应用程序」文件夹后再打开即可恢复正常。")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button("打开应用程序文件夹") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                }
                .buttonStyle(.frSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }
}

// MARK: - 功能 Tab

struct FeaturesTab: View {
    @FRState private var badgeOwnershipReclaim: Bool = SharedConfig.shared.badgeOwnershipReclaim
    @FRState private var copyPathFormat: CopyPathFormat = SharedConfig.shared.copyPathFormat
    @FRState private var copyFileContentMaxSizeKB: Int = SharedConfig.shared.copyFileContentMaxSizeKB
    @FRState private var featureOrder: [MenuFeature] = MenuFeatureCatalog.ordered(by: SharedConfig.shared.menuOrder)
    @FRState private var dropTargetId: String?

    /// 把拖动的功能放到目标行的位置：下移时落在目标之后，上移时落在目标之前
    private func moveFeature(_ id: String, to targetId: String) -> Bool {
        dropTargetId = nil
        guard id != targetId,
              let from = featureOrder.firstIndex(where: { $0.id == id }),
              let to = featureOrder.firstIndex(where: { $0.id == targetId }) else { return false }
        var order = featureOrder
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        featureOrder = order
        SharedConfig.shared.menuOrder = order.map(\.id)
        return true
    }

    /// 用真实主目录下的示例文件演示当前格式
    private var copyPathExample: String {
        let home = IPCBridge.realUserHomeDirectory
        let sample = home.appendingPathComponent("Documents").appendingPathComponent("报告 2026.pdf")
        return PathFormatter.string(for: [sample], format: copyPathFormat, home: home.path)
    }

    var body: some View {
        FRPage(title: "功能", subtitle: "选择出现在右键菜单中的功能，拖动调整顺序") {
            menuSection
            copyPathSection
            copyContentSection
            badgeSection
            quickLookSection
        }
    }

    // MARK: 快速查看

    private var quickLookSection: some View {
        FRSection("快速查看") {
            FRCard {
                PreviewExtensionToggle(
                    identifier: PreviewExtensionManager.identifier,
                    title: Text("预览增强"),
                    subtitle: Text("文件夹、压缩包与更多文本格式"),
                    switchLabel: "预览增强"
                )
                FRDivider()
                PreviewExtensionToggle(
                    identifier: PreviewExtensionManager.markdownIdentifier,
                    title: Text("Markdown 渲染"),
                    switchLabel: "Markdown 渲染",
                    checksMarkdownConflicts: true
                )
            }
        }
    }

    // MARK: 右键菜单功能

    private var menuSection: some View {
        FRSection {
            HStack {
                FRCaption("右键菜单功能")
                Spacer()
                Button("恢复默认顺序") {
                    SharedConfig.shared.menuOrder = []
                    featureOrder = MenuFeatureCatalog.ordered(by: [])
                }
                .buttonStyle(.frLink)
                .disabled(featureOrder.map(\.id) == MenuFeatureCatalog.all.map(\.id))
                .padding(.trailing, 4)
            }
        } content: {
            FRCard {
                ForEach(Array(featureOrder.enumerated()), id: \.element.id) { index, feature in
                    if index > 0 { FRDivider() }
                    featureRow(feature)
                }
            }

            FRFootnote(Text("关闭的功能不会出现在 Finder 右键菜单中。拖动左侧的 ≡ 可调整它们在右键菜单中的顺序。"))
        }
    }

    private func featureRow(_ feature: MenuFeature) -> some View {
        HStack(spacing: 10) {
            // 只有把手可以拖起，避免与开关的点击手势冲突；整行都是放置目标
            FRGrip()
                .draggable(feature.id)
                .help("拖动调整在右键菜单中的顺序")
            FeatureToggleRow(feature: feature)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(dropTargetId == feature.id ? FRTheme.selection : Color.clear)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            return moveFeature(id, to: feature.id)
        } isTargeted: { targeted in
            if targeted {
                dropTargetId = feature.id
            } else if dropTargetId == feature.id {
                dropTargetId = nil
            }
        }
    }

    // MARK: 复制路径

    private var copyPathSection: some View {
        FRSection("复制路径") {
            FRCard {
                FRRow(title: Text("复制格式")) {
                    FRPicker(label: "复制格式", selection: Binding(
                        get: { copyPathFormat },
                        set: { newValue in
                            copyPathFormat = newValue
                            SharedConfig.shared.copyPathFormat = newValue
                        }
                    )) {
                        ForEach(CopyPathFormat.allCases) { format in
                            Text(LocalizedStringKey(format.titleKey)).tag(format)
                        }
                    }
                }

                FRDivider()

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("示例")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                    Text(verbatim: copyPathExample)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(FRTheme.text)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }

            FRFootnote(Text(copyPathFormat == .shellEscaped
                            ? "含空格等特殊字符的路径会加引号；多选时以空格分隔，可直接粘贴为终端命令参数。"
                            : "多选时每行一项。「服务」菜单里的复制路径也使用此格式。"))
        }
    }

    // MARK: 复制文件内容

    private var copyContentSection: some View {
        FRSection("复制文件内容") {
            FRCard {
                FRRow(title: Text("文件大小上限"), subtitle: Text("仅在单选常规文件且大小在上限内时显示菜单项")) {
                    FRPicker(label: "文件大小上限", selection: Binding(
                        get: {
                            CopyFileContentSizePreset(rawValue: copyFileContentMaxSizeKB) ?? .mb1
                        },
                        set: { newValue in
                            copyFileContentMaxSizeKB = newValue.rawValue
                            SharedConfig.shared.copyFileContentMaxSizeKB = newValue.rawValue
                        }
                    )) {
                        ForEach(CopyFileContentSizePreset.allCases) { preset in
                            Text(preset.titleKey).tag(preset)
                        }
                    }
                }
            }

        }
    }

    // MARK: 剪切角标

    private var badgeSection: some View {
        FRSection("剪切角标") {
            FRCard {
                // 其他访达扩展（如 Keka、Pearcleaner）可能占用角标显示权，导致剪切角标不显示。开启后，仅当所在目录有已剪切的文件时，FinderRight 才会短暂重启这些扩展以取回显示权（每次访达启动至多一次）。
                FRRow(title: Text("自动解决角标冲突")) {
                    FRSwitch(label: "自动解决角标冲突", isOn: Binding(
                        get: { badgeOwnershipReclaim },
                        set: { newValue in
                            badgeOwnershipReclaim = newValue
                            SharedConfig.shared.badgeOwnershipReclaim = newValue
                        }
                    ))
                }
            }

            FRFootnote(Text("注意：这可能使网盘等扩展的同步状态图标在 FinderRight 监控的目录中不再显示。"))
        }
    }

}

// MARK: - 终端 Tab

struct ToolsTab: View {
    @FRState private var availableTerminals: [KnownTerminal] = []
    @FRState private var selectedTerminalBundleId = ""
    @FRState private var defaultSystemTerminalId: String = "com.apple.Terminal"
    @FRState private var selectedTerminalIds: Set<String> = []
    @FRState private var dropTargetTerminalId: String?
    @FRState private var isSearching = true
    @FRState private var terminalMessage: String?

    var body: some View {
        FRPage(title: "终端", subtitle: "选择右键菜单中「在终端中打开」使用的终端应用") {
            FRSection("默认终端") {
                FRCard {
                    FRRow(title: Text("默认终端")) {
                        FRPicker(label: "默认终端", selection: Binding(
                            get: { selectedTerminalBundleId },
                            set: { newValue in
                                let config = SharedConfig.shared
                                let usedDefault = selectedTerminalIds == [config.preferredTerminal]
                                selectedTerminalBundleId = newValue
                                config.preferredTerminal = newValue
                                if usedDefault {
                                    config.resetTerminalMenuToDefault()
                                    selectedTerminalIds = config.selectedTerminals
                                }
                            }
                        )) {
                            Text("跟随系统").tag("")
                            ForEach(availableTerminals) { terminal in
                                Text(NSLocalizedString(terminal.name, comment: "")).tag(terminal.bundleIdentifier)
                            }
                        }
                        .disabled(isSearching)
                    }
                }
            }
            FRSection {
                HStack {
                    FRCaption("右键菜单中显示")
                    Spacer()
                    Button(action: chooseTerminalApplications) {
                        Label("添加终端…", systemImage: "plus")
                    }
                    .buttonStyle(.frPrimary)
                    .disabled(isSearching)
                }
            } content: {
                FRCard {
                    if isSearching {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在查找…")
                        }
                        .padding(16)
                    }
                    ForEach(Array(availableTerminals.enumerated()), id: \.element.id) { index, terminal in
                        if index > 0 { FRDivider() }
                        terminalRow(terminal)
                    }
                }
                if let terminalMessage {
                    FRFootnote(Text(verbatim: terminalMessage))
                }
                FRFootnote(Text("自动识别已声明终端功能的应用；也可通过「添加终端…」手动选择，所选应用须通过同样的校验。默认终端跟随系统，可在上方更改。"))
                FRFootnote(Text("默认只显示一个终端；启用多个终端时展开子菜单，只有一个时直接打开。全部关闭则隐藏右键入口。拖动左侧的 ≡ 可调整终端在右键菜单中的顺序。"))
            }
        }
        .onAppear(perform: detectInstalledApps)
    }

    private func terminalRow(_ terminal: KnownTerminal) -> some View {
        let isDefault = terminal.bundleIdentifier == defaultSystemTerminalId
        return HStack(spacing: 12) {
            FRGrip()
                .draggable(terminal.bundleIdentifier)
                .help("拖动调整在右键菜单中的顺序")
            FRIconChip(systemName: terminal.icon)
            Text(NSLocalizedString(terminal.name, comment: ""))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FRTheme.text)
            if isDefault {
                FRChip(text: Text("系统默认"))
            }
            Spacer(minLength: 0)
            FRSwitch(label: "右键菜单中显示", isOn: Binding(
                get: { selectedTerminalIds.contains(terminal.bundleIdentifier) },
                set: { visible in
                    if visible {
                        selectedTerminalIds.insert(terminal.bundleIdentifier)
                    } else {
                        selectedTerminalIds.remove(terminal.bundleIdentifier)
                    }
                    SharedConfig.shared.selectedTerminals = selectedTerminalIds
                }
            ))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(dropTargetTerminalId == terminal.bundleIdentifier ? FRTheme.selection : Color.clear)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            return moveTerminal(id, to: terminal.bundleIdentifier)
        } isTargeted: { targeted in
            if targeted {
                dropTargetTerminalId = terminal.bundleIdentifier
            } else if dropTargetTerminalId == terminal.bundleIdentifier {
                dropTargetTerminalId = nil
            }
        }
    }

    private func moveTerminal(_ id: String, to targetId: String) -> Bool {
        dropTargetTerminalId = nil
        guard id != targetId,
              let from = availableTerminals.firstIndex(where: { $0.bundleIdentifier == id }),
              let to = availableTerminals.firstIndex(where: { $0.bundleIdentifier == targetId }) else { return false }
        var order = availableTerminals
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        availableTerminals = order
        SharedConfig.shared.terminalOrder = order.map(\.bundleIdentifier)
        return true
    }

    private func detectInstalledApps() {
        isSearching = true
        let config = SharedConfig.shared
        let additionalIds = config.selectedTerminals.union([config.preferredTerminal])
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = TerminalCatalog.installed(additionalBundleIdentifiers: additionalIds)
            let defaultId = TerminalCatalog.defaultTerminalBundleIdentifier()
            DispatchQueue.main.async {
                availableTerminals = TerminalCatalog.ordered(installed, by: config.terminalOrder)
                defaultSystemTerminalId = defaultId
                selectedTerminalBundleId = !config.followsSystemTerminal
                    && installed.contains(where: { $0.bundleIdentifier == config.preferredTerminal })
                    ? config.preferredTerminal : ""
                selectedTerminalIds = Set(TerminalCatalog.menuTerminals(
                    available: availableTerminals, selected: config.selectedTerminals,
                    preferred: selectedTerminalBundleId.isEmpty ? defaultId : selectedTerminalBundleId
                ).map(\.bundleIdentifier))
                isSearching = false
            }
        }
    }

    private func chooseTerminalApplications() {
        terminalMessage = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = NSLocalizedString("添加", comment: "")
        guard panel.runModal() == .OK else { return }

        var messages: [String] = []
        for url in panel.urls {
            guard let terminal = TerminalCatalog.terminal(at: url),
                  terminal.bundleIdentifier != Bundle.main.bundleIdentifier else {
                messages.append(String(format: NSLocalizedString("未识别到终端功能：%@", comment: ""),
                                       url.lastPathComponent))
                continue
            }
            // 注册手选位置，让主 App 和沙箱扩展都可按 bundle id 定位，不传递可执行路径。
            guard LSRegisterURL(url as CFURL, true) == noErr else {
                messages.append(String(format: NSLocalizedString("无法添加以下应用：%@", comment: ""), terminal.name))
                continue
            }
            if !availableTerminals.contains(where: { $0.bundleIdentifier == terminal.bundleIdentifier }) {
                availableTerminals.append(terminal)
            }
            selectedTerminalIds.insert(terminal.bundleIdentifier)
            SharedConfig.shared.selectedTerminals = selectedTerminalIds
        }
        terminalMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
}

// MARK: - 关于 Tab

struct AboutTab: View {
    private let appVersion = UpdateChecker.shared.currentAppVersion

    @FRState private var updateStatus: UpdateCheckStatus = UpdateChecker.shared.currentStatus
    @FRState private var didCopyDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // 应用图标：直接取 App 自身图标，与程序坞 / 访达中显示的保持一致（图标自带边距与投影）
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)

            Text(verbatim: "FinderRight")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(FRTheme.text)
                .padding(.top, 14)

            Text("版本 \(appVersion)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(FRTheme.mute)
                .padding(.top, 4)

            updateArea
                .padding(.top, 14)

            // 描述
            Text("增强 macOS Finder 右键菜单的轻量工具。")
                .multilineTextAlignment(.center)
                .foregroundColor(FRTheme.mute)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .padding(.horizontal, 40)
                .padding(.top, 22)

            // GitHub 链接与 Star 入口：从 Release 直接下载 dmg 的用户通常不会回到仓库页，这里给一个入口
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/funny-dog/FinderRight")!)
                } label: {
                    Label("GitHub 仓库", systemImage: "link")
                }
                .buttonStyle(.frSecondary)

                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/funny-dog/FinderRight")!)
                } label: {
                    Label("觉得好用？去 GitHub 点个 Star", systemImage: "star")
                }
                .buttonStyle(.frPrimary)
                .help("打开仓库主页，登录 GitHub 后手动点击右上角 Star")
            }
            .padding(.top, 24)

            // 反馈入口：一次带齐版本、系统、权限与扩展状态，省掉 issue 里反复问环境
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(DiagnosticsReport.make(), forType: .string)
                didCopyDiagnostics = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    didCopyDiagnostics = false
                }
            } label: {
                if didCopyDiagnostics {
                    Label("已复制诊断信息", systemImage: "checkmark")
                } else {
                    Label("复制诊断信息", systemImage: "doc.on.doc")
                }
            }
            .buttonStyle(.frLink)
            .help("复制版本、系统、权限与扩展状态，反馈问题时附上")
            .padding(.top, 12)

            Spacer(minLength: 0)

            // 版权信息
            Text(verbatim: "Copyright © 2026 FinderRight · MIT License")
                .font(.system(size: 11.5))
                .foregroundColor(FRTheme.mute)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            performCheck(force: false)
        }
        // 菜单栏「检查更新…」发起的检查与下载也同步到这里
        .onReceive(NotificationCenter.default.publisher(for: UpdateChecker.statusDidChangeNotification)) { _ in
            updateStatus = UpdateChecker.shared.currentStatus
        }
    }

    /// 版本状态与更新操作：有新版本、下载中、安装中、最新、失败，各有各的呈现
    @ViewBuilder
    private var updateArea: some View {
        VStack(spacing: 8) {
            switch updateStatus {
            case .updateAvailable(let newVersion, let releaseURL, let downloadURL, let checksum):
                HStack(spacing: 8) {
                    if let downloadURL = downloadURL {
                        Button {
                            UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum) { newStatus in
                                self.updateStatus = newStatus
                            }
                        } label: {
                            Label("立即更新到 \(newVersion)", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.frPrimary)
                        .help("自动下载并安装新版本")
                    }

                    Button {
                        NSWorkspace.shared.open(releaseURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.frSecondary)
                    .help("在浏览器中查看更新说明")
                }

            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(FRTheme.accent)
                        .frame(width: 120)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(FRTheme.mute)
                }

            case .installing:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text("正在安装并重启...")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                }

            case .checking:
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)

            case .upToDate:
                HStack(spacing: 10) {
                    FRChip(text: Text("已是最新版本"), kind: .ok)
                    checkButton
                }

            case .failed(let msg):
                HStack(spacing: 10) {
                    Label {
                        Text(verbatim: msg)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
                    checkButton
                }

            default:
                checkButton
            }
        }
        .frame(minHeight: 28)
    }

    private var checkButton: some View {
        Button {
            performCheck(force: true)
        } label: {
            Label("检查更新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.frLink)
    }

    private func performCheck(force: Bool) {
        UpdateChecker.shared.check(force: force) { newStatus in
            self.updateStatus = newStatus
        }
    }
}

// MARK: - 快捷键 Tab

struct ShortcutsTab: View {

    private let actions: [(id: String, name: String, icon: String)] = [
        ("shortcut.undo",         "撤销",           "arrow.uturn.backward"),
        ("shortcut.newFile",      "新建文件",       "doc.badge.plus"),
        ("shortcut.copyPath",     "复制路径",       "link"),
        ("shortcut.copyFileName", "复制文件名",     "character.cursor.ibeam"),
        ("shortcut.copyFileContent", "复制文件内容", "doc.plaintext"),
        ("shortcut.goToDirectory", "打开路径…",     "arrow.right.circle"),
        ("shortcut.openTerminal", "打开终端",       "terminal"),
        ("shortcut.openEditor",   "打开编辑器",     "curlybraces"),
        ("shortcut.cut",          "剪切",           "scissors"),
        ("shortcut.paste",        "粘贴",           "doc.on.clipboard"),
        ("shortcut.compress",     "压缩为 ZIP",     "doc.zipper"),
        ("shortcut.decompress",   "解压到当前目录", "shippingbox.and.arrow.backward"),
        ("shortcut.toggleHidden", "切换隐藏文件",   "eye"),
    ]

    @FRState private var conflictMessage: String?
    /// 服务快捷键已写入系统，但运行中的访达要重启才会读取
    @FRState private var needsFinderRestart = ServiceShortcutSync.finderNeedsRelaunch
    /// 授权后所有快捷键由按键拦截处理；未授权时剪切 / 粘贴不可用，其他行退回服务快捷键
    @FRState private var hasAccessibility = AccessibilityChecker.check()
    /// 恢复默认后递增，让各行重新读取快捷键
    @FRState private var reloadToken = 0

    var body: some View {
        FRPage(title: "快捷键", subtitle: "在访达中选中文件后直接按键，无需展开右键菜单") {
            FRSection("访达快捷键") {
                if !hasAccessibility {
                    FRCard {
                        FRRow(title: Text("快捷键需要「辅助功能」权限"),
                              subtitle: Text("授权后任意组合都能用、改完立即生效；未授权时剪切、粘贴不可用，其余快捷键要重启访达才生效。")) {
                            VStack(alignment: .trailing, spacing: 8) {
                                Button("授权辅助功能…") { requestAccessibility() }
                                    .buttonStyle(.frPrimary)
                                Button("前往权限与扩展") {
                                    SettingsNavigation.shared.selectedTab = .permissions
                                }
                                .buttonStyle(.frLink)
                            }
                        }
                    }
                }

                // 授权后按键拦截立即生效，不用重启；只有退回服务快捷键时才需要
                if needsFinderRestart && !hasAccessibility {
                    FRCard {
                        FRRow(title: Text("重启访达后新快捷键生效"),
                              subtitle: Text("访达只在启动时读取服务快捷键；重启会关闭所有访达窗口，可能中断正在进行的拷贝。")) {
                            Button("重启访达") {
                                FinderRelauncher.relaunch()
                                needsFinderRestart = false
                            }
                            .buttonStyle(.frPrimary)
                        }
                    }
                }

                FRCard {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { FRDivider() }
                        ShortcutCell(actionId: action.id,
                                     actionName: action.name,
                                     actionIcon: action.icon,
                                     allActions: actions,
                                     interceptorAvailable: hasAccessibility,
                                     onConflict: { msg in
                                         conflictMessage = msg
                                     },
                                     onChange: { shortcutChanged(actionId: action.id) })
                        .id("\(action.id)-\(reloadToken)")
                    }
                }

                FRCard {
                    FRRow(title: Text("恢复默认快捷键"),
                          subtitle: Text("恢复与访达一致的默认组合，没有默认的会清空。")) {
                        Button("恢复默认…") { confirmRestoreDefaults() }
                            .buttonStyle(.frSecondary)
                    }
                }

                FRFootnote(Text("点击按钮后按键录制，Delete 清除，ESC 取消。默认与访达一致，升级不会改动你的设置。\n除剪切、粘贴、切换隐藏文件、打开路径外，其余快捷键需先选中文件。"))
            }
        }
        .onAppear {
            needsFinderRestart = ServiceShortcutSync.finderNeedsRelaunch
            hasAccessibility = AccessibilityChecker.check()
        }
        // 从系统设置授权后切回本 App 时刷新提示
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = AccessibilityChecker.check()
        }
        .onChange(of: conflictMessage) { message in
            guard let message else { return }
            showSheet(FRDialog(title: NSLocalizedString("快捷键冲突", comment: ""), message: message,
                               symbol: "exclamationmark.triangle", tone: .warning,
                               buttons: [NSLocalizedString("好", comment: "")])) { _ in conflictMessage = nil }
        }
    }

    /// 设置窗口内的弹窗以 sheet 显示；找不到窗口时退回模态
    private func showSheet(_ dialog: FRDialog, completion: @escaping (Int?) -> Void) {
        if let window = NSApp.keyWindow {
            dialog.beginSheet(for: window, completion: completion)
        } else {
            completion(dialog.runModal())
        }
    }

    /// 系统弹窗会把 FinderRight 加进辅助功能列表；再打开设置页，用户只需打开开关
    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func confirmRestoreDefaults() {
        let dialog = FRDialog(
            title: NSLocalizedString("恢复默认快捷键？", comment: ""),
            message: NSLocalizedString("你设置的快捷键会被替换为默认组合，没有默认组合的会被清空。", comment: ""),
            symbol: "arrow.counterclockwise", tone: .warning,
            buttons: [NSLocalizedString("恢复默认", comment: ""), NSLocalizedString("取消", comment: "")])
        showSheet(dialog) { if $0 == 0 { restoreDefaults() } }
    }

    /// 全部换成默认快捷键，并刷新各行、按键拦截与服务快捷键
    private func restoreDefaults() {
        FinderShortcutInterceptor.restoreDefaultShortcuts()
        reloadToken += 1
        FinderShortcutInterceptor.shared.refresh()
        guard ServiceShortcutSync.run() else { return }
        NSUpdateDynamicServices()
        needsFinderRestart = true
    }

    /// 按键拦截立即生效；其余行同时同步为系统服务快捷键（未授权时的回退），有变化时记下需重启访达
    private func shortcutChanged(actionId: String) {
        FinderShortcutInterceptor.shared.refresh()
        guard ServiceShortcutSync.run() else { return }
        NSUpdateDynamicServices()
        if ServiceShortcuts.syncsShortcut(actionId: actionId) { needsFinderRestart = true }
    }
}

// MARK: - 单行快捷键录制组件

struct ShortcutCell: View {
    let actionId: String
    let actionName: String
    let actionIcon: String
    let allActions: [(id: String, name: String, icon: String)]
    /// 已授权「辅助功能」：所有行由按键拦截处理
    let interceptorAvailable: Bool
    let onConflict: (String) -> Void
    let onChange: () -> Void

    @FRState private var shortcut: ActionShortcut?
    @FRState private var isRecording = false
    @FRState private var monitor: Any?

    var body: some View {
        HStack(spacing: 12) {
            FRIconChip(systemName: actionIcon)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(actionName))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                if let reserved = shortcut.flatMap({
                    FinderKeyTakeover.recordingConflict(for: $0, actionId: actionId, interceptorAvailable: interceptorAvailable)
                }) {
                    // 系统全局快捷键永远轮不到；访达 / 文本编辑组合在未授权（退回服务快捷键）时由访达或系统响应
                    Group {
                        switch reserved.kind {
                        case .system:
                            Text(String(format: NSLocalizedString("与系统「%@」冲突，不会生效，请重新录制", comment: ""),
                                        NSLocalizedString(reserved.name, comment: "")))
                        case .textEditing:
                            Text(String(format: NSLocalizedString("未授权「辅助功能」时被系统文本编辑按键（%@）占用", comment: ""),
                                        reserved.name))
                        case .finderMenu:
                            Text(String(format: NSLocalizedString("未授权「辅助功能」时由访达自带的「%@」响应", comment: ""),
                                        NSLocalizedString(reserved.name, comment: "")))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(FRTheme.warnText)
                } else if actionId == FinderKeyTakeover.pasteActionId {
                    Text("粘贴到当前窗口所在的文件夹，空白处也可以")
                        .font(.system(size: 11))
                        .foregroundColor(FRTheme.mute)
                } else if actionId == FinderKeyTakeover.toggleHiddenActionId && !interceptorAvailable {
                    Text("需要「辅助功能」权限，否则仅在右键菜单展开时生效")
                        .font(.system(size: 11))
                        .foregroundColor(FRTheme.mute)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { isRecording ? cancelRecording() : startRecording() } label: {
                Group {
                    if isRecording {
                        Text("按下快捷键…")
                            .foregroundColor(FRTheme.accentText)
                    } else if let s = shortcut {
                        Text(displayString(s))
                            .fontWeight(.semibold)
                            .foregroundColor(FRTheme.text)
                    } else {
                        Text("未设置")
                            .foregroundColor(FRTheme.mute)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 84)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecording ? FRTheme.selection : FRTheme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isRecording ? FRTheme.accentText : FRTheme.fieldBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isRecording)

            Button { finishRecording(nil) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(FRTheme.mute.opacity(0.7))
            }
            .buttonStyle(.plain)
            .opacity(shortcut != nil && !isRecording ? 1 : 0)
            .help("清除")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear { shortcut = SharedConfig.shared.shortcut(forActionId: actionId) }
        .onDisappear {
            isRecording = false
            removeMonitor()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                self.cancelRecording()
            } else if event.keyCode == 51 || event.keyCode == 117 {
                self.finishRecording(nil)
            } else {
                let cleanMods = event.modifierFlags.intersection([.command, .option, .shift, .control])
                guard !cleanMods.intersection([.command, .option, .control]).isEmpty,
                      let chars = event.charactersIgnoringModifiers?.lowercased(),
                      !chars.isEmpty else { return nil }
                self.finishRecording(ActionShortcut(key: chars, modifiers: Int(cleanMods.rawValue)))
            }
            return nil
        }
    }

    private func cancelRecording() { isRecording = false; removeMonitor() }

    private func finishRecording(_ newShortcut: ActionShortcut?) {
        if let candidate = newShortcut {
            // 已授权：按键拦截抢在访达之前处理，只拦系统全局快捷键；未授权：除剪切 / 粘贴外退回服务快捷键，照旧拦截
            if let reserved = FinderKeyTakeover.recordingConflict(for: candidate, actionId: actionId,
                                                                   interceptorAvailable: interceptorAvailable) {
                var message: String
                switch reserved.kind {
                case .system:
                    message = String(format: NSLocalizedString("该快捷键已被系统「%@」占用，请换一个组合", comment: ""),
                                     NSLocalizedString(reserved.name, comment: ""))
                case .finderMenu:
                    message = String(format: NSLocalizedString("该快捷键是访达自带的「%@」，访达会优先响应，请换一个组合（例如加上 ⌃）", comment: ""),
                                     NSLocalizedString(reserved.name, comment: ""))
                case .textEditing:
                    message = String(format: NSLocalizedString("该快捷键是系统文本编辑按键（%@），访达会先拿去处理，请换一个组合（例如 ⌃⌘ 组合）", comment: ""),
                                     reserved.name)
                }
                if !reserved.isSystem {
                    message += "\n" + NSLocalizedString("授权「辅助功能」后可以使用这个组合。", comment: "")
                }
                cancelRecording()
                onConflict(message)
                return
            }
            for other in allActions where other.id != actionId {
                if let existing = SharedConfig.shared.shortcut(forActionId: other.id),
                   existing.key.lowercased() == candidate.key.lowercased(),
                   existing.modifiers == candidate.modifiers {
                    let otherTitle = NSLocalizedString(other.name, comment: "")
                    let msg = String(format: NSLocalizedString("该快捷键已被「%@」占用", comment: ""), otherTitle)
                    cancelRecording()
                    onConflict(msg)
                    return
                }
            }
        }
        isRecording = false
        shortcut = newShortcut
        SharedConfig.shared.setShortcut(newShortcut, forActionId: actionId)
        removeMonitor()
        onChange()
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func displayString(_ s: ActionShortcut) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(s.modifiers))
        var r = ""
        if flags.contains(.control) { r += "⌃" }
        if flags.contains(.option)  { r += "⌥" }
        if flags.contains(.shift)   { r += "⇧" }
        if flags.contains(.command) { r += "⌘" }
        r += s.key.uppercased()
        return r
    }
}

// MARK: - 服务快捷键同步

enum ServiceShortcutSync {
    /// 最近一次真正改写 pbs 的时间；访达早于它启动就说明还没读到新快捷键
    private static let syncedAtKey = "serviceShortcutsSyncedAt"

    /// 把设置里的快捷键写入系统服务快捷键，返回是否有变化
    @discardableResult
    static func run() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier,
              ServiceShortcuts.sync(shortcuts: SharedConfig.shared.shortcuts, bundleId: bundleId) else { return false }
        UserDefaults.standard.set(Date(), forKey: syncedAtKey)
        return true
    }

    /// 访达是否在最近一次同步之前启动（需要重启才能用上新快捷键）
    static var finderNeedsRelaunch: Bool {
        guard let syncedAt = UserDefaults.standard.object(forKey: syncedAtKey) as? Date,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let started = processStartDate(pid: finder.processIdentifier) else { return false }
        return started < syncedAt
    }

    /// 访达由 launchd 拉起，NSRunningApplication.launchDate 为 nil，改从内核读进程启动时间
    private static func processStartDate(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}

// MARK: - 重启访达

enum FinderRelauncher {
    /// killall 后由系统自动拉起访达（会关闭所有访达窗口）
    static func relaunch() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["Finder"]
        try? proc.run()
    }
}

/// 功能页中的 Quick Look 开关，直接读取与修改系统的扩展选举。
/// 文件预览与 Markdown 预览是两个独立扩展，各自一行开关。
private struct PreviewExtensionToggle: View {
    let identifier: String
    let title: Text
    var subtitle: Text? = nil
    let switchLabel: LocalizedStringKey
    var checksMarkdownConflicts = false

    @FRState private var enabled: Bool? = nil
    @FRState private var busy = false
    @FRState private var errorMessage: String? = nil
    @FRState private var hasConflict = false

    var body: some View {
        VStack(spacing: 0) {
            FRRow(title: title, subtitle: subtitle) {
                HStack(spacing: 8) {
                    if busy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(Text("正在更新预览设置"))
                    }
                    FRSwitch(label: switchLabel, isOn: Binding(
                        get: { enabled ?? false },
                        set: { update(to: $0) }
                    ))
                    .disabled(busy || enabled == nil)
                }
            }
            if let errorMessage {
                FRDivider()
                HStack(spacing: 8) {
                    Text(verbatim: errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("重新检测") { update() }
                        .buttonStyle(.frSecondary)
                        .disabled(busy)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            if enabled == true, hasConflict {
                FRDivider()
                Text("检测到其他应用的 Markdown 预览，系统可能优先使用它")
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .onAppear { update() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in update() }
    }

    private func update(to desired: Bool? = nil) {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                if let desired { try PreviewExtensionManager.setEnabled(desired, identifier: identifier) }
                return try PreviewExtensionManager.isEnabled(identifier)
            }
            let conflict = checksMarkdownConflicts && !PreviewExtensionManager.markdownConflicts().isEmpty
            DispatchQueue.main.async {
                busy = false
                hasConflict = conflict
                switch result {
                case .success(let value): enabled = value
                case .failure(let error):
                    enabled = nil
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
