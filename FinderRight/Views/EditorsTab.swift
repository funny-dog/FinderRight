import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinderRightKit

// MARK: - 编辑器 Tab

/// 管理「打开编辑器」：默认编辑器（服务菜单 / 快捷键）、右键子菜单中显示哪些编辑器、手动添加清单外的应用。
struct EditorsTab: View {
    /// 已安装的编辑器：预置清单在前，手动添加项在后
    @FRState private var editors: [KnownEditor] = []
    @FRState private var icons: [String: NSImage] = [:]
    @FRState private var hidden: Set<String> = []
    @FRState private var customIds: Set<String> = []
    @FRState private var defaultId = EditorCatalog.textEditBundleId
    @FRState private var showingAddSheet = false

    var body: some View {
        FRPage(title: "编辑器", subtitle: "右键「打开编辑器」与服务菜单使用的编辑器") {
            FRSection("默认编辑器") {
                FRCard {
                    FRRow(title: Text("默认编辑器"),
                          subtitle: Text("通过服务菜单或快捷键「打开编辑器」时直接使用")) {
                        FRPicker(label: "默认编辑器", selection: Binding(
                            get: { defaultId },
                            set: { newValue in
                                defaultId = newValue
                                SharedConfig.shared.preferredEditor = newValue
                            }
                        )) {
                            ForEach(editors) { editor in
                                Text(verbatim: editor.name).tag(editor.id)
                            }
                        }
                    }
                }
            }

            FRSection {
                HStack {
                    FRCaption("右键菜单中显示")
                    Spacer()
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("添加编辑器…", systemImage: "plus")
                    }
                    .buttonStyle(.frPrimary)
                }
            } content: {
                FRCard {
                    ForEach(Array(editors.enumerated()), id: \.element.id) { index, editor in
                        if index > 0 { FRDivider() }
                        row(editor)
                    }
                }
                FRFootnote(Text("常见编辑器会自动识别；其他编辑器（或任何应用）可通过「添加编辑器…」加入。关闭开关的编辑器不会出现在右键子菜单中。"))
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddEditorSheet(isPresented: $showingAddSheet, onAdd: add)
        }
        .onAppear(perform: reload)
    }

    private func row(_ editor: KnownEditor) -> some View {
        let isCustom = customIds.contains(editor.id)
        return HStack(spacing: 10) {
            if let icon = icons[editor.id] {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
            }
            Text(verbatim: editor.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FRTheme.text)
            if editor.id == defaultId {
                FRChip(text: Text("默认"), kind: .ok)
            }
            if isCustom {
                FRChip(text: Text("手动添加"))
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
                    refreshDefault()
                }
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func reload() {
        let config = SharedConfig.shared
        let custom = config.customEditors
        var appURLs: [String: URL] = [:]
        editors = EditorCatalog.installed(custom: custom) { id in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
            appURLs[id] = url
            return true
        }
        icons = appURLs.mapValues { NSWorkspace.shared.icon(forFile: $0.path) }
        customIds = Set(custom.map(\.id))
        hidden = config.hiddenEditors
        refreshDefault()
    }

    private func refreshDefault() {
        let config = SharedConfig.shared
        defaultId = EditorCatalog.resolvedDefault(
            preferred: config.preferredEditor, custom: config.customEditors, hidden: hidden,
            isInstalled: { id in editors.contains(where: { $0.id == id }) })
    }

    /// 加入编辑器：清单内的（已自动识别）只需取消隐藏，其余记为手动添加项
    private func add(_ editor: KnownEditor) {
        let config = SharedConfig.shared
        if !EditorCatalog.all.contains(where: { $0.id == editor.id }),
           !config.customEditors.contains(where: { $0.id == editor.id }) {
            config.customEditors += [editor]
        }
        var updatedHidden = config.hiddenEditors
        if updatedHidden.remove(editor.id) != nil {
            config.hiddenEditors = updatedHidden
        }
        reload()
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

// MARK: - 添加编辑器

/// 一个可添加的应用（扫描出的候选或用户手选）
private struct EditorCandidate: Identifiable {
    var id: String { editor.id }
    let editor: KnownEditor
    let url: URL
    let icon: NSImage
}

/// 添加编辑器：列出 LaunchServices 中声明能编辑代码文件、但不在自动识别清单里的应用，
/// 并允许从「应用程序」文件夹手动选择任意应用（覆盖 Antigravity 这类不声明任何文档类型的编辑器）。
struct AddEditorSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (KnownEditor) -> Void

    @FRState private var candidates: [EditorCandidate] = []
    @FRState private var isSearching = true
    @FRState private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("添加编辑器")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(FRTheme.text)
                Text("这些应用声明可以编辑代码文件，但不在自动识别清单中")
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
            }

            FRCard {
                if isSearching {
                    placeholder(Text("正在查找…"), showsProgress: true)
                } else if candidates.isEmpty {
                    placeholder(Text("没有发现其他编辑器"), showsProgress: false)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                                if index > 0 { FRDivider() }
                                candidateRow(candidate)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            if let message {
                Text(verbatim: message)
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.warnText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("从应用程序中选择…", action: chooseApplications)
                    .buttonStyle(.frSecondary)
                Spacer()
                Button("完成") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.frPrimary)
            }
        }
        .padding(22)
        .frame(width: 460, height: 420)
        .background(FRTheme.window)
        .onAppear(perform: search)
    }

    private func placeholder(_ text: Text, showsProgress: Bool) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView().controlSize(.small)
            }
            text
                .font(.system(size: 13))
                .foregroundColor(FRTheme.mute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
    }

    private func candidateRow(_ candidate: EditorCandidate) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: candidate.icon)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: candidate.editor.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                Text(verbatim: candidate.url.path)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(FRTheme.mute)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("添加") {
                onAdd(candidate.editor)
                candidates.removeAll { $0.id == candidate.id }
            }
            .buttonStyle(.frSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 后台扫描候选（实测约 0.5 秒，不能放主线程）
    private func search() {
        let config = SharedConfig.shared
        var excluded = Set(EditorCatalog.all.map(\.id))
        excluded.formUnion(config.customEditors.map(\.id))
        // 终端会以 Editor 角色声明 .sh，不算编辑器
        excluded.formUnion(TerminalCatalog.all.map(\.bundleIdentifier))
        if let own = Bundle.main.bundleIdentifier { excluded.insert(own) }
        let home = IPCBridge.realUserHomeDirectory.path

        DispatchQueue.global(qos: .userInitiated).async {
            let found = Self.discoverCandidates(excluding: excluded, home: home)
            DispatchQueue.main.async {
                candidates = found
                isSearching = false
            }
        }
    }

    private static func discoverCandidates(excluding excluded: Set<String>, home: String) -> [EditorCandidate] {
        let codeTypes = EditorDiscovery.codeExtensions.compactMap { UTType(filenameExtension: $0) }
        let codeTypeIds = Set(codeTypes.map(\.identifier))
        var seen = excluded
        var result: [EditorCandidate] = []
        for type in codeTypes {
            for url in NSWorkspace.shared.urlsForApplications(toOpen: type) {
                guard EditorDiscovery.isStandardInstallLocation(url.path, home: home),
                      let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      !seen.contains(id) else { continue }
                seen.insert(id)
                guard EditorDiscovery.declaresCodeEditing(infoDictionary: bundle.infoDictionary ?? [:],
                                                          codeTypeIdentifiers: codeTypeIds) else { continue }
                result.append(EditorCandidate(editor: KnownEditor(id: id, name: appName(url)), url: url,
                                              icon: NSWorkspace.shared.icon(forFile: url.path)))
            }
        }
        return result.sorted { $0.editor.name.localizedStandardCompare($1.editor.name) == .orderedAscending }
    }

    /// 应用显示名：取访达中显示的本地化名称，去掉 .app 后缀
    private static func appName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func chooseApplications() {
        message = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = NSLocalizedString("添加", comment: "")
        guard panel.runModal() == .OK else { return }

        var rejected: [String] = []
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else {
                rejected.append(url.lastPathComponent)
                continue
            }
            onAdd(KnownEditor(id: id, name: Self.appName(url)))
            candidates.removeAll { $0.id == id }
        }
        if !rejected.isEmpty {
            message = String(format: NSLocalizedString("无法添加以下应用：%@", comment: ""),
                             rejected.joined(separator: "、"))
        }
    }
}
