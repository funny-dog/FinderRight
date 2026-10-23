import SwiftUI
import AppKit
import CoreServices
import UniformTypeIdentifiers
import FinderRightKit

// MARK: - 编辑器 Tab

/// 管理「打开编辑器」：默认编辑器（服务菜单 / 快捷键）、右键菜单可见性与手动添加；自动推荐通用编辑器，手动添加校验文本编辑能力。
struct EditorsTab: View {
    /// 已安装的编辑器，按用户保存的顺序显示
    @FRState private var editors: [KnownEditor] = []
    @FRState private var icons: [String: NSImage] = [:]
    @FRState private var hidden: Set<String> = []
    @FRState private var customIds: Set<String> = []
    @FRState private var defaultId = ""
    @FRState private var systemDefaultId = EditorCatalog.textEditBundleId
    @FRState private var isSearching = true
    @FRState private var dropTargetEditorId: String?

    var body: some View {
        FRPage(title: "编辑器", subtitle: "右键「打开编辑器」与服务菜单使用的编辑器") {
            FRSection("默认编辑器") {
                FRCard {
                    FRRow(title: Text("默认编辑器")) {
                        FRPicker(label: "默认编辑器", selection: Binding(
                            get: { defaultId },
                            set: { newValue in
                                defaultId = newValue
                                SharedConfig.shared.preferredEditor = newValue
                            }
                        )) {
                            Text("跟随系统").tag("")
                            ForEach(editors) { editor in
                                Text(verbatim: editor.name).tag(editor.id)
                            }
                        }
                        .disabled(isSearching)
                    }
                }
                FRFootnote(Text("默认编辑器跟随系统的纯文本默认打开应用，也可在上方指定；不受菜单顺序和显示开关影响。"))
            }

            FRSection {
                HStack {
                    FRCaption("右键菜单中显示")
                    Spacer()
                    Button(action: chooseApplications) {
                        Label("添加编辑器…", systemImage: "plus")
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
                    ForEach(Array(editors.enumerated()), id: \.element.id) { index, editor in
                        if index > 0 { FRDivider() }
                        row(editor)
                    }
                }
                FRFootnote(Text("自动列出声明支持通用文本、通用源码或所有文件的编辑器；仅编辑特定文本格式的应用可通过「添加编辑器…」加入，无法识别时会弹窗说明。关闭开关可隐藏菜单项，拖动左侧的 ≡ 可调整顺序。"))
            }
        }
        .onAppear(perform: reload)
    }

    private func row(_ editor: KnownEditor) -> some View {
        let isCustom = customIds.contains(editor.id)
        return HStack(spacing: 10) {
            FRGrip()
                .draggable(editor.id)
                .help("拖动调整在右键菜单中的顺序")
            if let icon = icons[editor.id] {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            }
            Text(verbatim: editor.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FRTheme.text)
            if editor.id == systemDefaultId {
                FRChip(text: Text("系统默认"))
            }
            if isCustom {
                FRChip(text: Text("手动添加"), kind: .accent)
            }

            Spacer(minLength: 8)

            if isCustom {
                Button {
                    remove(editor)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 15))
                        .foregroundColor(FRTheme.mute)
                }
                .buttonStyle(.plain)
                .help("移除")
            }

            FRSwitch(label: "右键菜单中显示", isOn: Binding(
                get: { !hidden.contains(editor.id) },
                set: { visible in
                    if visible { hidden.remove(editor.id) } else { hidden.insert(editor.id) }
                    SharedConfig.shared.hiddenEditors = hidden
                }
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(dropTargetEditorId == editor.id ? FRTheme.selection : Color.clear)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            return moveEditor(id, to: editor.id)
        } isTargeted: { targeted in
            if targeted {
                dropTargetEditorId = editor.id
            } else if dropTargetEditorId == editor.id {
                dropTargetEditorId = nil
            }
        }
    }

    private func moveEditor(_ id: String, to targetId: String) -> Bool {
        dropTargetEditorId = nil
        guard id != targetId,
              let from = editors.firstIndex(where: { $0.id == id }),
              let to = editors.firstIndex(where: { $0.id == targetId }) else { return false }
        var order = editors
        let moved = order.remove(at: from)
        order.insert(moved, at: to)
        editors = order
        SharedConfig.shared.editorOrder = order.map(\.id)
        return true
    }

    private func reload() {
        isSearching = true
        let config = SharedConfig.shared
        let custom = config.customEditors
        DispatchQueue.global(qos: .userInitiated).async {
            let installed = EditorCatalog.installed(custom: custom, preferred: config.preferredEditor, order: config.editorOrder)
            var freshIcons: [String: NSImage] = [:]
            var manualIds = Set(custom.map(\.id))
            let home = IPCBridge.realUserHomeDirectory.path
            for editor in installed {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.id) {
                    freshIcons[editor.id] = NSWorkspace.shared.icon(forFile: url.path)
                    // 旧手动记录不改变当前能自动识别的应用的显示来源。
                    if EditorDiscovery.isStandardInstallLocation(url.path, home: home),
                       EditorCatalog.declaresGeneralEditing(infoDictionary: Bundle(url: url)?.infoDictionary ?? [:]) {
                        manualIds.remove(editor.id)
                    }
                }
            }
            let system = EditorCatalog.defaultEditorBundleIdentifier()
            DispatchQueue.main.async {
                editors = installed
                icons = freshIcons
                customIds = manualIds
                hidden = config.hiddenEditors
                systemDefaultId = system
                defaultId = config.preferredEditor.flatMap { preferred in
                    installed.contains(where: { $0.id == preferred }) ? preferred : nil
                } ?? ""
                isSearching = false
            }
        }
    }

    private func chooseApplications() {
        let parentWindow = NSApp.keyWindow
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = NSLocalizedString("添加", comment: "")
        guard panel.runModal() == .OK else { return }

        let config = SharedConfig.shared
        var custom = config.customEditors
        var updatedHidden = config.hiddenEditors
        var messages: [String] = []
        var didAcceptApplication = false
        for url in panel.urls {
            guard let editor = EditorCatalog.editor(at: url), editor.id != Bundle.main.bundleIdentifier else {
                messages.append(String(format: NSLocalizedString("未识别到文本编辑功能：%@", comment: ""), url.lastPathComponent))
                continue
            }
            guard LSRegisterURL(url as CFURL, true) == noErr else {
                messages.append(String(format: NSLocalizedString("无法添加以下应用：%@", comment: ""), editor.name))
                continue
            }
            if !editors.contains(where: { $0.id == editor.id }), !custom.contains(where: { $0.id == editor.id }) {
                custom.append(editor)
            }
            updatedHidden.remove(editor.id)
            didAcceptApplication = true
        }
        if custom != config.customEditors { config.customEditors = custom }
        if updatedHidden != config.hiddenEditors { config.hiddenEditors = updatedHidden }
        if didAcceptApplication { reload() }
        if !messages.isEmpty {
            let dialog = FRDialog(title: NSLocalizedString("无法添加编辑器", comment: ""),
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

    private func remove(_ editor: KnownEditor) {
        let config = SharedConfig.shared
        config.customEditors = config.customEditors.filter { $0.id != editor.id }
        var updatedHidden = config.hiddenEditors
        if updatedHidden.remove(editor.id) != nil {
            config.hiddenEditors = updatedHidden
        }
        if config.preferredEditor == editor.id {
            config.preferredEditor = nil
        }
        reload()
    }
}
