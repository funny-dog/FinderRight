import SwiftUI
import AppKit
import FinderRightKit
import ServiceManagement

// MARK: - 终端定义（使用 FinderRightKit 中的 TerminalCatalog）

// MARK: - SettingsView

/// 设置窗口当前显示的标签页。由 finderright://settings/<页名> 链接驱动（例如右键「管理常用目录…」）
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsView.SettingsTab = .general
}

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
        TabView(selection: $navigation.selectedTab) {
            GeneralTab()
                .tabItem {
                    Label(LocalizedStringKey(SettingsTab.general.rawValue), systemImage: SettingsTab.general.icon)
                }
                .tag(SettingsTab.general)

            FeaturesTab()
                .tabItem {
                    Label(LocalizedStringKey(SettingsTab.features.rawValue), systemImage: SettingsTab.features.icon)
                }
                .tag(SettingsTab.features)

            FavoritesTab()
                .tabItem {
                    Label(LocalizedStringKey(SettingsTab.favorites.rawValue), systemImage: SettingsTab.favorites.icon)
                }
                .tag(SettingsTab.favorites)

            ShortcutsTab()
                .tabItem {
                    Label(LocalizedStringKey(SettingsTab.shortcuts.rawValue), systemImage: SettingsTab.shortcuts.icon)
                }
                .tag(SettingsTab.shortcuts)

            ToolsTab()
                .tabItem {
                    Label(LocalizedStringKey(SettingsTab.tools.rawValue), systemImage: SettingsTab.tools.icon)
                }
                .tag(SettingsTab.tools)

            AboutTab()
                .tabItem {
                    Label(LocalizedStringKey(SettingsTab.about.rawValue), systemImage: SettingsTab.about.icon)
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 540, height: 460)
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
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        updateLaunchAtLogin(to: newValue)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动启动")
                        Text("登录时自动运行 FinderRight")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let error = launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                if currentLoginStatus == .requiresApproval {
                    HStack {
                        Text("已注册，但需要在「系统设置」-「通用」-「登录项」中允许启动")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                        Button("打开系统设置") {
                            LaunchAtLoginManager.openLoginItemsSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            } header: {
                Text("启动")
            }

            Section {
                Picker("语言", selection: Binding(
                    get: { appLanguage },
                    set: { newValue in
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
                )) {
                    Text("跟随系统").tag("system")
                    Text("中文").tag("zh-Hans")
                    Text("English").tag("en")
                }

                Picker("右键菜单图标", selection: Binding(
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

                Toggle(isOn: $showMenuBarIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示菜单栏图标")
                        Text("关闭后，菜单栏不显示 FinderRight 图标")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Toggle(isOn: $showDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("显示程序坞图标")
                        Text("关闭后，FinderRight 在 Dock 中隐藏（仍可后台运行）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .onChange(of: showDockIcon) { newValue in
                    if newValue {
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
            } header: {
                Text("显示")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("切换语言将立即自动重启应用以生效")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !showMenuBarIcon && !showDockIcon {
                        Label("两个图标都关闭后，可通过 Spotlight 搜索「FinderRight」重新打开偏好设置", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }

            Section {
                FullDiskAccessView()
                    .padding(.vertical, 4)
                Divider()
                AccessibilityView()
                    .padding(.vertical, 4)
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("访达右键扩展")
                        Text("若右键未显示菜单，可尝试重启访达或检查扩展开关")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("重启访达") {
                        let proc = Process()
                        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                        proc.arguments = ["Finder"]
                        try? proc.run()
                    }
                    .buttonStyle(.bordered)

                    Button("扩展设置...") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            } header: {
                Text("权限与扩展")
            } footer: {
                Text("「完全磁盘访问」让你能在 ~/Documents、~/Desktop、~/Pictures 等受保护目录使用所有功能。「辅助功能」让「切换隐藏文件」时 Finder 窗口不闪烁。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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
        Form {
            Section {
                ForEach(featureOrder) { feature in
                    HStack(spacing: 8) {
                        // 只有把手可以拖起，避免与开关的点击手势冲突；整行都是放置目标
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary)
                            .frame(width: 18, height: 24)
                            .contentShape(Rectangle())
                            .draggable(feature.id)
                            .help("拖动调整在右键菜单中的顺序")
                        FeatureToggleRow(feature: feature)
                    }
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(dropTargetId == feature.id ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
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
            } header: {
                HStack {
                    Text("右键菜单功能")
                    Spacer()
                    Button("恢复默认顺序") {
                        SharedConfig.shared.menuOrder = []
                        featureOrder = MenuFeatureCatalog.ordered(by: [])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(featureOrder.map(\.id) == MenuFeatureCatalog.all.map(\.id))
                }
            } footer: {
                Text("关闭的功能不会出现在 Finder 右键菜单中。拖动左侧的 ≡ 可调整它们在右键菜单中的顺序。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Picker("复制格式", selection: Binding(
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
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("示例")
                        .foregroundColor(.secondary)
                    Text(verbatim: copyPathExample)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
            } header: {
                Text("复制路径")
            } footer: {
                Text(copyPathFormat == .shellEscaped
                     ? "含空格等特殊字符的路径会加引号；多选时以空格分隔，可直接粘贴为终端命令参数。"
                     : "多选时每行一项。「服务」菜单里的复制路径也使用此格式。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { badgeOwnershipReclaim },
                    set: { newValue in
                        badgeOwnershipReclaim = newValue
                        SharedConfig.shared.badgeOwnershipReclaim = newValue
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动解决角标冲突")
                        Text("其他访达扩展（如 Keka、Pearcleaner）可能占用角标显示权，导致剪切角标不显示。开启后，仅当所在目录有已剪切的文件时，FinderRight 才会短暂重启这些扩展以取回显示权（每次访达启动至多一次）。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("剪切角标")
            } footer: {
                Text("注意：这可能使网盘等扩展的同步状态图标在 FinderRight 监控的目录中不再显示。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                if customTemplates.isEmpty {
                    Text("暂无自定义模板")
                        .foregroundColor(.secondary)
                        .font(.callout)
                } else {
                    ForEach(customTemplates) { tmpl in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tmpl.name.isEmpty ? ".\(tmpl.fileExtension)" : tmpl.name)
                                    .fontWeight(.medium)
                                Text(".\(tmpl.fileExtension)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button {
                                deleteTemplate(tmpl)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加自定义模板...", systemImage: "plus")
                }
            } header: {
                Text("自定义文件模板")
            } footer: {
                Text("添加的模板将显示在 Finder 右键「新建文件」子菜单底部。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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
                .font(.headline)

            Form {
                TextField("模板名称 (例如: 配置文件)", text: $name)
                TextField("文件后缀 (例如: conf，无需带点)", text: $fileExtension)

                VStack(alignment: .leading, spacing: 4) {
                    Text("默认内容 (可选):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )
                }
            }

            if let err = errorMessage {
                // Text(String) 走的是「原样显示」，不会查 Localizable.strings；
                // 包成 LocalizedStringKey 才能让「文件后缀不能为空」的英文条目生效
                Text(LocalizedStringKey(err))
                    .font(.caption)
                    .foregroundColor(.red)
            }

            HStack {
                Spacer()
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Button("添加") {
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
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420, height: 300)
    }
}


// MARK: - 终端 Tab

struct ToolsTab: View {
    @FRState private var availableTerminals: [KnownTerminal] = []
    @FRState private var selectedTerminalBundleId: String = "com.apple.Terminal"
    @FRState private var defaultSystemTerminalId: String = "com.apple.Terminal"

    var body: some View {
        Form {
            Section {
                Picker("默认终端", selection: Binding(
                    get: { selectedTerminalBundleId },
                    set: { newValue in
                        selectedTerminalBundleId = newValue
                        SharedConfig.shared.preferredTerminal = newValue
                    }
                )) {
                    ForEach(availableTerminals) { terminal in
                        let isDefault = terminal.bundleIdentifier == defaultSystemTerminalId
                        let localizedName = NSLocalizedString(terminal.name, comment: "")
                        let title = isDefault ? "\(localizedName) (\(NSLocalizedString("系统默认", comment: "")))" : localizedName
                        Label(title, systemImage: terminal.icon)
                            .tag(terminal.bundleIdentifier)
                    }
                }
            } header: {
                Text("终端")
            } footer: {
                Text("选择右键菜单中「在终端中打开」使用的终端应用")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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
        VStack(spacing: 20) {
            Spacer()

            // 应用图标：直接取 App 自身图标，与程序坞 / 访达中显示的保持一致（图标自带边距与投影）
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)

            // 名称与版本
            VStack(spacing: 6) {
                Text("FinderRight")
                    .font(.title)
                    .fontWeight(.bold)

                // 版本号与新版本提示
                HStack(alignment: .center, spacing: 8) {
                    Text("版本 \(appVersion)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    switch updateStatus {
                    case .updateAvailable(let newVersion, let releaseURL, let downloadURL, let sha256URL):
                        HStack(spacing: 6) {
                            if let downloadURL = downloadURL {
                                Button {
                                    UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, sha256URL: sha256URL) { newStatus in
                                        self.updateStatus = newStatus
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.down.circle.fill")
                                        Text("立即更新到 \(newVersion)")
                                            .fontWeight(.medium)
                                    }
                                    .font(.system(size: 11))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        Capsule()
                                            .fill(LinearGradient(colors: [.blue, .purple], startPoint: .leading, endPoint: .trailing))
                                    )
                                }
                                .buttonStyle(.plain)
                                .help("自动下载并安装新版本")
                            }

                            Button {
                                NSWorkspace.shared.open(releaseURL)
                            } label: {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("在浏览器中查看更新说明")
                        }

                    case .downloading(let progress):
                        HStack(spacing: 6) {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                                .frame(width: 80)
                            Text("\(Int(progress * 100))%")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                    case .installing:
                        HStack(spacing: 5) {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 14, height: 14)
                            Text("正在安装并重启...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                    case .checking:
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 14, height: 14)

                    default:
                        EmptyView()
                    }
                }

                // 辅助状态及手动刷新按钮
                HStack(spacing: 8) {
                    if updateStatus == .upToDate {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("已是最新版本")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    } else if case .failed(let msg) = updateStatus {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundColor(.secondary)
                            Text(msg)
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }

                    if updateStatus != .checking, !isUpdating(updateStatus) {
                        Button {
                            performCheck(force: true)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                Text("检查更新")
                            }
                            .font(.caption2)
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 2)
            }

            // 描述
            Text("增强 macOS Finder 右键菜单的轻量工具。\n新建文件、复制路径、打开终端与编辑器、剪切粘贴、压缩解压。")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .font(.body)
                .padding(.horizontal, 40)

            // GitHub 链接与 Star 入口：从 Release 直接下载 dmg 的用户通常不会回到仓库页，这里给一个入口
            HStack(spacing: 20) {
                Link(destination: URL(string: "https://github.com/funny-dog/FinderRight")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text("GitHub 仓库")
                    }
                }
                Link(destination: URL(string: "https://github.com/funny-dog/FinderRight/stargazers")!) {
                    HStack(spacing: 6) {
                        Image(systemName: "star")
                        Text("觉得好用？去 GitHub 点个 Star")
                    }
                }
                .help("在仓库页右上角点击 Star")
            }
            .font(.callout)
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Spacer()

            // 版权信息
            Text(verbatim: "Copyright © 2026 FinderRight · MIT License")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            performCheck(force: false)
        }
    }

    private func performCheck(force: Bool) {
        UpdateChecker.shared.check(force: force) { newStatus in
            self.updateStatus = newStatus
        }
    }

    private func isUpdating(_ status: UpdateCheckStatus) -> Bool {
        switch status {
        case .downloading, .installing:
            return true
        default:
            return false
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
        Form {
            Section {
                ForEach(actions, id: \.id) { action in
                    ShortcutCell(actionId: action.id,
                                 actionName: action.name,
                                 actionIcon: action.icon,
                                 allActions: actions,
                                 onConflict: { msg in
                                     conflictMessage = msg
                                 })
                }
            } header: {
                Text("右键菜单快捷键")
            } footer: {
                Text("需含 ⌘、⌥ 或 ⌃ 之一。点击按钮后按键录制，Delete 清除，ESC 取消。\n快捷键仅在 Finder 右键菜单已展开时生效，不是全局热键。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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
            Label(LocalizedStringKey(actionName), systemImage: actionIcon)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button { isRecording ? cancelRecording() : startRecording() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording
                              ? Color.accentColor.opacity(0.12)
                              : Color(NSColor.controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isRecording ? Color.accentColor : Color(NSColor.separatorColor),
                                      lineWidth: 1)
                    Group {
                        if isRecording {
                            Text("按下快捷键…")
                                .foregroundColor(.accentColor)
                        } else if let s = shortcut {
                            Text(displayString(s))
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                        } else {
                            Text("未设置")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .fixedSize()
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isRecording)

            Button { finishRecording(nil) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .opacity(shortcut != nil && !isRecording ? 1 : 0)
        }
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
