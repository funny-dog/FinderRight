import SwiftUI
import AppKit
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
        case favorites = "常用目录"
        case shortcuts = "快捷键"
        case tools = "终端"
        case about = "关于"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .features: return "slider.horizontal.3"
            case .favorites: return "folder"
            case .shortcuts: return "keyboard"
            case .tools: return "terminal"
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
            case .tools: return "tools"
            case .about: return "about"
            }
        }
    }

    @ObservedObject private var navigation = SettingsNavigation.shared

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
        case .tools: ToolsTab()
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
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("showDockIcon") private var showDockIcon = false
    @FRState private var menuIconStyle: MenuIconStyle = SharedConfig.shared.menuIconStyle
    @FRState private var appLanguage: String = SharedConfig.shared.appLanguage
    @FRState private var launchAtLoginError: String?
    @FRState private var currentLoginStatus: SMAppService.Status = .notRegistered

    var body: some View {
        FRPage(title: "通用", subtitle: "启动、显示与系统权限") {
            launchSection
            displaySection
            permissionSection
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
                FRRow(title: Text("开机自动启动"), subtitle: Text("登录时自动运行 FinderRight")) {
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
                        Text("已注册，但需要在「系统设置」-「通用」-「登录项」中允许启动")
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

    // MARK: 显示

    private var displaySection: some View {
        FRSection("显示") {
            FRCard {
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

                FRDivider()

                FRRow(title: Text("显示菜单栏图标"), subtitle: Text("关闭后，菜单栏不显示 FinderRight 图标")) {
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

    // MARK: 权限与扩展

    private var permissionSection: some View {
        FRSection("权限与扩展") {
            FRCard {
                FullDiskAccessView()
                FRDivider()
                AccessibilityView()
                FRDivider()
                FRRow(title: Text("访达右键扩展"), subtitle: Text("若右键未显示菜单，可尝试重启访达或检查扩展开关")) {
                    HStack(spacing: 8) {
                        Button("重启访达") {
                            let proc = Process()
                            proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                            proc.arguments = ["Finder"]
                            try? proc.run()
                        }
                        .buttonStyle(.frSecondary)

                        Button("扩展设置...") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.frSecondary)
                    }
                }
            }

            FRFootnote(Text("「完全磁盘访问」让你能在 ~/Documents、~/Desktop、~/Pictures 等受保护目录使用所有功能。「辅助功能」让「切换隐藏文件」时 Finder 窗口不闪烁。"))
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
        let appPath = Bundle.main.bundleURL.path
        // 不要在这里 killall FinderRightSync：扩展每次构建菜单都实时读取 appLanguage，无需重启；
        // 而扩展进程重启会使其成为重叠目录的最后注册者、丢失剪切角标归属，
        // 进而触发一轮对其他访达扩展的重启抢回（见 BadgeOwnershipManager）。
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do
            /bin/sleep 0.1
        done
        /usr/bin/open "\(appPath)"
        /bin/sleep 0.1
        /usr/bin/open "finderright://settings"
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

// MARK: - 功能 Tab

struct FeaturesTab: View {
    @FRState private var customTemplates: [FileTemplate] = SharedConfig.shared.customFileTemplates
    @FRState private var showingAddSheet = false
    @FRState private var badgeOwnershipReclaim: Bool = SharedConfig.shared.badgeOwnershipReclaim
    @FRState private var copyPathFormat: CopyPathFormat = SharedConfig.shared.copyPathFormat
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
            badgeSection
            templateSection
        }
        .sheet(isPresented: $showingAddSheet) {
            AddTemplateSheet(
                isPresented: $showingAddSheet,
                onAdd: { template in
                    SharedConfig.shared.addFileTemplate(template)
                    customTemplates = SharedConfig.shared.customFileTemplates
                }
            )
        }
        .onAppear {
            customTemplates = SharedConfig.shared.customFileTemplates
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

    // MARK: 剪切角标

    private var badgeSection: some View {
        FRSection("剪切角标") {
            FRCard {
                FRRow(
                    title: Text("自动解决角标冲突"),
                    subtitle: Text("其他访达扩展（如 Keka、Pearcleaner）可能占用角标显示权，导致剪切角标不显示。开启后，仅当所在目录有已剪切的文件时，FinderRight 才会短暂重启这些扩展以取回显示权（每次访达启动至多一次）。")
                ) {
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

    // MARK: 自定义文件模板

    private var templateSection: some View {
        FRSection("自定义文件模板") {
            FRCard {
                if customTemplates.isEmpty {
                    Text("暂无自定义模板")
                        .font(.system(size: 12.5))
                        .foregroundColor(FRTheme.mute)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                } else {
                    ForEach(Array(customTemplates.enumerated()), id: \.element.id) { index, tmpl in
                        if index > 0 { FRDivider() }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tmpl.name.isEmpty ? ".\(tmpl.fileExtension)" : tmpl.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(FRTheme.text)
                                Text(".\(tmpl.fileExtension)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(FRTheme.mute)
                            }
                            Spacer()
                            Button {
                                deleteTemplate(tmpl)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 13))
                                    .foregroundColor(FRTheme.danger)
                            }
                            .buttonStyle(.plain)
                            .help("删除")
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }

                FRDivider()

                HStack {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("添加自定义模板...", systemImage: "plus")
                    }
                    .buttonStyle(.frSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
            }

            FRFootnote(Text("添加的模板将显示在 Finder 右键「新建文件」子菜单底部。"))
        }
    }

    private func deleteTemplate(_ tmpl: FileTemplate) {
        SharedConfig.shared.removeFileTemplate(withId: tmpl.id)
        customTemplates = SharedConfig.shared.customFileTemplates
    }
}

// MARK: - 添加自定义模板弹窗

struct AddTemplateSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (FileTemplate) -> Void

    @FRState private var name: String = ""
    @FRState private var fileExtension: String = ""
    @FRState private var content: String = ""
    @FRState private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("新建文件模板")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(FRTheme.text)

            VStack(alignment: .leading, spacing: 10) {
                TextField("模板名称 (例如: 配置文件)", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("文件后缀 (例如: conf，无需带点)", text: $fileExtension)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 4) {
                    Text("默认内容 (可选):")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                    TextEditor(text: $content)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 100)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FRTheme.field))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(FRTheme.fieldBorder, lineWidth: 1)
                        )
                }
            }

            if let err = errorMessage {
                // Text(String) 走的是「原样显示」，不会查 Localizable.strings；
                // 包成 LocalizedStringKey 才能让「文件后缀不能为空」的英文条目生效
                Text(LocalizedStringKey(err))
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.danger)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.frSecondary)

                Button("添加") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.frPrimary)
            }
        }
        .padding(22)
        .frame(width: 440, height: 340)
        .background(FRTheme.window)
    }

    private func submit() {
        let cleanExt = fileExtension.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanExt.isEmpty else {
            errorMessage = "文件后缀不能为空"
            return
        }
        // 与主 App createFile 的校验一致（新建文件名为 untitled.<后缀>），提前在录入时拦下
        guard SafeFileName.isValid(baseName: "untitled", ext: cleanExt) else {
            errorMessage = "文件后缀不能包含 / 或控制字符"
            return
        }
        let tmpl = FileTemplate(name: cleanName.isEmpty ? cleanExt : cleanName,
                                fileExtension: cleanExt,
                                content: content)
        onAdd(tmpl)
        isPresented = false
    }
}


// MARK: - 终端 Tab

struct ToolsTab: View {
    @FRState private var availableTerminals: [KnownTerminal] = []
    @FRState private var selectedTerminalBundleId: String = "com.apple.Terminal"
    @FRState private var defaultSystemTerminalId: String = "com.apple.Terminal"

    var body: some View {
        FRPage(title: "终端", subtitle: "选择右键菜单中「在终端中打开」使用的终端应用") {
            FRSection("默认终端") {
                FRCard {
                    ForEach(Array(availableTerminals.enumerated()), id: \.element.id) { index, terminal in
                        if index > 0 { FRDivider() }
                        terminalRow(terminal)
                    }
                }
            }
        }
        .onAppear {
            detectInstalledApps()
            let defaultId = TerminalCatalog.defaultTerminalBundleIdentifier()
            defaultSystemTerminalId = defaultId

            // 读取已保存偏好；若已保存的 terminal 在可用列表中，则保留；
            // 否则优先选中系统默认终端（若可用），最后回退到第一个可用项。
            let savedTerminal = SharedConfig.shared.preferredTerminal
            if availableTerminals.contains(where: { $0.bundleIdentifier == savedTerminal }) {
                selectedTerminalBundleId = savedTerminal
            } else if availableTerminals.contains(where: { $0.bundleIdentifier == defaultId }) {
                selectedTerminalBundleId = defaultId
            } else {
                selectedTerminalBundleId = availableTerminals.first?.bundleIdentifier ?? "com.apple.Terminal"
            }
            SharedConfig.shared.preferredTerminal = selectedTerminalBundleId
        }
    }

    private func terminalRow(_ terminal: KnownTerminal) -> some View {
        let isSelected = terminal.bundleIdentifier == selectedTerminalBundleId
        let isDefault = terminal.bundleIdentifier == defaultSystemTerminalId
        return Button {
            selectedTerminalBundleId = terminal.bundleIdentifier
            SharedConfig.shared.preferredTerminal = terminal.bundleIdentifier
        } label: {
            HStack(spacing: 12) {
                FRIconChip(systemName: terminal.icon)
                Text(NSLocalizedString(terminal.name, comment: ""))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                if isDefault {
                    FRChip(text: Text("系统默认"))
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundColor(isSelected ? FRTheme.accentText : FRTheme.mute.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detectInstalledApps() {
        var installed = TerminalCatalog.all.filter { terminal in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) != nil
        }
        let sysDefault = TerminalCatalog.defaultTerminalBundleIdentifier()
        // 若系统默认终端未在预设清单中（如第三方冷门终端），但系统内确实已安装，则动态加入
        if !installed.contains(where: { $0.bundleIdentifier == sysDefault }),
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: sysDefault) {
            let name = Bundle(url: appURL)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: appURL)?.infoDictionary?["CFBundleDisplayName"] as? String
                ?? Bundle(url: appURL)?.infoDictionary?["CFBundleName"] as? String
                ?? appURL.deletingPathExtension().lastPathComponent
            installed.append(KnownTerminal(id: sysDefault, name: name, bundleIdentifier: sysDefault, icon: "terminal.fill"))
        }
        if installed.isEmpty {
            installed = [TerminalCatalog.all[0]] // 系统终端兜底
        }
        availableTerminals = installed
    }
}

// MARK: - 关于 Tab

struct AboutTab: View {
    private let appVersion = UpdateChecker.shared.currentAppVersion

    @FRState private var updateStatus: UpdateCheckStatus = UpdateChecker.shared.currentStatus

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
            Text("增强 macOS Finder 右键菜单的轻量工具。\n新建文件、复制路径、打开终端与编辑器、剪切粘贴、压缩解压。")
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
                    NSWorkspace.shared.open(URL(string: "https://github.com/funny-dog/FinderRight/stargazers")!)
                } label: {
                    Label("觉得好用？去 GitHub 点个 Star", systemImage: "star")
                }
                .buttonStyle(.frPrimary)
                .help("在仓库页右上角点击 Star")
            }
            .padding(.top, 24)

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
    }

    /// 版本状态与更新操作：有新版本、下载中、安装中、最新、失败，各有各的呈现
    @ViewBuilder
    private var updateArea: some View {
        VStack(spacing: 8) {
            switch updateStatus {
            case .updateAvailable(let newVersion, let releaseURL, let downloadURL, let sha256URL):
                HStack(spacing: 8) {
                    if let downloadURL = downloadURL {
                        Button {
                            UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, sha256URL: sha256URL) { newStatus in
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
        ("shortcut.newFile",      "新建文件",       "doc.badge.plus"),
        ("shortcut.copyPath",     "复制路径",       "doc.on.doc"),
        ("shortcut.openTerminal", "打开终端",       "terminal"),
        ("shortcut.openEditor",   "打开编辑器",     "square.and.pencil"),
        ("shortcut.cut",          "剪切",           "scissors"),
        ("shortcut.paste",        "粘贴",           "doc.on.clipboard"),
        ("shortcut.compress",     "压缩为 ZIP",     "archivebox"),
        ("shortcut.decompress",   "解压到当前目录", "archivebox.circle"),
        ("shortcut.toggleHidden", "切换隐藏文件",   "eye"),
    ]

    @FRState private var conflictMessage: String?

    var body: some View {
        FRPage(title: "快捷键", subtitle: "为右键菜单里的功能绑定快捷键") {
            FRSection("右键菜单快捷键") {
                FRCard {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { FRDivider() }
                        ShortcutCell(actionId: action.id,
                                     actionName: action.name,
                                     actionIcon: action.icon,
                                     allActions: actions,
                                     onConflict: { msg in
                                         conflictMessage = msg
                                     })
                    }
                }

                FRFootnote(Text("需含 ⌘、⌥ 或 ⌃ 之一。点击按钮后按键录制，Delete 清除，ESC 取消。\n快捷键仅在 Finder 右键菜单已展开时生效，不是全局热键。"))
            }
        }
        .alert(isPresented: Binding(
            get: { conflictMessage != nil },
            set: { if !$0 { conflictMessage = nil } }
        )) {
            Alert(
                title: Text("快捷键冲突"),
                message: Text(conflictMessage ?? ""),
                dismissButton: .default(Text("好"))
            )
        }
    }
}

// MARK: - 单行快捷键录制组件

struct ShortcutCell: View {
    let actionId: String
    let actionName: String
    let actionIcon: String
    let allActions: [(id: String, name: String, icon: String)]
    let onConflict: (String) -> Void

    @FRState private var shortcut: ActionShortcut?
    @FRState private var isRecording = false
    @FRState private var monitor: Any?

    var body: some View {
        HStack(spacing: 12) {
            FRIconChip(systemName: actionIcon)

            Text(LocalizedStringKey(actionName))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FRTheme.text)
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
