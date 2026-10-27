import SwiftUI
import AppKit
import CoreServices
import FinderRightKit

// MARK: - 终端 Tab

struct ToolsTab: View {
    @FRState private var availableTerminals: [KnownTerminal] = []
    @FRState private var terminalIcons: [String: NSImage] = [:]
    @FRState private var selectedTerminalBundleId = ""
    @FRState private var defaultSystemTerminalId: String = "com.apple.Terminal"
    @FRState private var selectedTerminalIds: Set<String> = []
    @FRState private var dropTargetTerminalId: String?
    @FRState private var isSearching = true

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
                FRFootnote(Text("用于服务菜单和快捷键。"))
            }
            FRSection {
                HStack {
                    FRCaption("右键菜单中显示")
                    Spacer()
                    Button(action: detectInstalledApps) {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.frSecondary)
                    .help("重新扫描")
                    .disabled(isSearching)
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
            if let icon = terminalIcons[terminal.bundleIdentifier] {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            } else {
                FRIconChip(systemName: terminal.icon)
            }
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
            var icons: [String: NSImage] = [:]
            for terminal in installed {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleIdentifier) {
                    icons[terminal.bundleIdentifier] = NSWorkspace.shared.icon(forFile: url.path)
                }
            }
            DispatchQueue.main.async {
                availableTerminals = TerminalCatalog.ordered(installed, by: config.terminalOrder)
                terminalIcons = icons
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
        let parentWindow = NSApp.keyWindow
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
            terminalIcons[terminal.bundleIdentifier] = NSWorkspace.shared.icon(forFile: url.path)
            selectedTerminalIds.insert(terminal.bundleIdentifier)
            SharedConfig.shared.selectedTerminals = selectedTerminalIds
        }
        if !messages.isEmpty {
            let dialog = FRDialog(title: NSLocalizedString("无法添加终端", comment: ""),
                                  message: messages.joined(separator: "\n"),
                                  symbol: "exclamationmark.triangle", tone: .warning,
                                  buttons: [NSLocalizedString("好", comment: "")])
            if let parentWindow {
                dialog.beginSheet(for: parentWindow) { _ in }
            } else {
                dialog.runModal()
            }
        }
    }
}
