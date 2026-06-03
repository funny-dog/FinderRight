import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 终端 & 编辑器定义

struct TerminalApp: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String
    let icon: String

    static let knownTerminals: [TerminalApp] = [
        TerminalApp(id: "terminal", name: "终端", bundleIdentifier: "com.apple.Terminal", icon: "terminal"),
        TerminalApp(id: "iterm", name: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", icon: "terminal.fill"),
        TerminalApp(id: "warp", name: "Warp", bundleIdentifier: "dev.warp.Warp-Stable", icon: "terminal.fill"),
        TerminalApp(id: "alacritty", name: "Alacritty", bundleIdentifier: "org.alacritty", icon: "terminal.fill"),
        TerminalApp(id: "kitty", name: "Kitty", bundleIdentifier: "net.kovidgoyal.kitty", icon: "terminal.fill"),
    ]
}

// MARK: - SettingsView

struct SettingsView: View {
    private enum SettingsTab: String, CaseIterable {
        case general = "通用"
        case features = "功能"
        case shortcuts = "快捷键"
        case tools = "终端"
        case about = "关于"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .features: return "slider.horizontal.3"
            case .shortcuts: return "keyboard"
            case .tools: return "terminal"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        TabView {
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

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $launchAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机自动启动")
                        Text("登录时自动运行 FinderRight")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("启动")
            }

            Section {
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
                if !showMenuBarIcon && !showDockIcon {
                    Label("两个图标都关闭后，可通过 Spotlight 搜索「FinderRight」重新打开偏好设置", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            Section {
                FullDiskAccessView()
                    .padding(.vertical, 4)
                Divider()
                AccessibilityView()
                    .padding(.vertical, 4)
            } header: {
                Text("权限")
            } footer: {
                Text("「完全磁盘访问」让你能在 ~/Documents、~/Desktop、~/Pictures 等受保护目录使用所有功能。「辅助功能」让「切换隐藏文件」时 Finder 窗口不闪烁。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 功能 Tab

struct FeaturesTab: View {
    var body: some View {
        Form {
            Section {
                ForEach(MenuFeatureCatalog.all) { feature in
                    FeatureToggleRow(feature: feature)
                }
            } header: {
                Text("右键菜单功能")
            } footer: {
                Text("关闭的功能不会出现在 Finder 右键菜单中。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 终端 Tab

struct ToolsTab: View {
    @State private var availableTerminals: [TerminalApp] = []
    @State private var selectedTerminalBundleId: String = "com.apple.Terminal"

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
                        Label(LocalizedStringKey(terminal.name), systemImage: terminal.icon)
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
            // 读取已保存偏好（bundleId）；若对应 App 未安装则回退到第一个可用项，
            // 并把解析结果写回，保证「设置里显示的」与「扩展实际使用的」一致。
            let savedTerminal = SharedConfig.shared.preferredTerminal
            selectedTerminalBundleId = availableTerminals.contains { $0.bundleIdentifier == savedTerminal }
                ? savedTerminal
                : (availableTerminals.first?.bundleIdentifier ?? "com.apple.Terminal")
            SharedConfig.shared.preferredTerminal = selectedTerminalBundleId
        }
    }

    private func detectInstalledApps() {
        availableTerminals = TerminalApp.knownTerminals.filter { terminal in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) != nil
        }
        if availableTerminals.isEmpty {
            availableTerminals = [TerminalApp.knownTerminals[0]] // 系统终端总是可用
        }
    }
}

// MARK: - 关于 Tab

struct AboutTab: View {
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // 应用图标
            Image(systemName: "contextualmenu.and.cursorarrow")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .blue.opacity(0.3), radius: 10, y: 5)

            // 名称与版本
            VStack(spacing: 4) {
                Text("FinderRight")
                    .font(.title)
                    .fontWeight(.bold)

                Text("版本 \(appVersion) (\(buildNumber))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // 描述
            Text("增强 macOS Finder 右键菜单的强大工具。\n快速访问开发工具、文件操作和自定义动作。")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .font(.body)
                .padding(.horizontal, 40)

            // GitHub 链接
            Link(destination: URL(string: "https://github.com/funny-dog/FinderRight")!) {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text("GitHub 仓库")
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Spacer()

            // 版权信息
            Text("Copyright © 2026 FinderRight. All rights reserved.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 快捷键 Tab

struct ShortcutsTab: View {

    private let actions: [(id: String, name: String, icon: String)] = [
        ("shortcut.copyPath",     "复制路径",       "doc.on.doc"),
        ("shortcut.openTerminal", "打开终端",       "terminal"),
        ("shortcut.cut",          "剪切",           "scissors"),
        ("shortcut.paste",        "粘贴",           "doc.on.clipboard"),
        ("shortcut.compress",     "压缩为 ZIP",     "archivebox"),
        ("shortcut.decompress",   "解压到当前目录", "archivebox.circle"),
        ("shortcut.toggleHidden", "切换隐藏文件",   "eye"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(actions, id: \.id) { action in
                    ShortcutCell(actionId: action.id,
                                 actionName: action.name,
                                 actionIcon: action.icon)
                }
            } header: {
                Text("右键菜单快捷键")
            } footer: {
                Text("需含 ⌘、⌥ 或 ⌃ 之一。点击按钮后按键录制，Delete 清除，ESC 取消。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - 单行快捷键录制组件

struct ShortcutCell: View {
    let actionId: String
    let actionName: String
    let actionIcon: String

    @State private var shortcut: ActionShortcut?
    @State private var isRecording = false
    @State private var monitor: Any?

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
