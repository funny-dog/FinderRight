import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 新建文件 Tab

/// 管理右键「新建文件」子菜单中的文件类型与模板：内置类型启用/禁用、自定义模板增删改、拖动调整全局排序。
struct NewFileTab: View {
    @FRState private var customTemplates: [FileTemplate] = SharedConfig.shared.customFileTemplates
    @FRState private var newFileOrder: [String] = SharedConfig.shared.newFileOrder
    @FRState private var hiddenTemplates: Set<String> = SharedConfig.shared.hiddenNewFileTemplates
    @FRState private var removedTemplates: Set<String> = SharedConfig.shared.removedNewFileTemplates
    @FRState private var showingAddSheet = false
    @FRState private var editingTemplate: FileTemplate?
    @FRState private var dropTargetId: String?

    /// 列表中的项：已移除的内置类型不列出
    private var items: [NewFileTemplateItem] {
        NewFileTemplateCatalog.resolvedTemplates(order: newFileOrder, customTemplates: customTemplates)
            .filter { !removedTemplates.contains($0.id) }
    }

    /// 已移除的内置类型，按默认顺序列出供恢复
    private var removedItems: [NewFileTemplateItem] {
        NewFileTemplateCatalog.builtInItems.filter { removedTemplates.contains($0.id) }
    }

    private var isDefaultOrder: Bool {
        let currentIds = items.map(\.id)
        let defaultIds = (NewFileTemplateCatalog.defaultOrder + customTemplates.map(\.id))
            .filter { !removedTemplates.contains($0) }
        return currentIds == defaultIds
    }

    private var enabledCount: Int {
        items.filter { !hiddenTemplates.contains($0.id) }.count
    }

    var body: some View {
        FRPage(title: "文件模板", subtitle: "右键「新建文件」子菜单里可以新建的文件类型，拖动调整顺序") {
            templatesSection
            if !removedItems.isEmpty {
                removedSection
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            EditTemplateSheet(
                template: nil,
                isPresented: $showingAddSheet,
                onSave: { newTemplate in
                    SharedConfig.shared.addFileTemplate(newTemplate)
                    reload()
                }
            )
        }
        .sheet(item: $editingTemplate) { template in
            EditTemplateSheet(
                template: template,
                isPresented: Binding(
                    get: { editingTemplate != nil },
                    set: { if !$0 { editingTemplate = nil } }
                ),
                onSave: { updated in
                    SharedConfig.shared.updateFileTemplate(updated)
                    reload()
                }
            )
        }
        .onAppear(perform: reload)
    }

    // MARK: - 模板列表

    private var templatesSection: some View {
        FRSection {
            HStack(spacing: 8) {
                FRCaption("文件类型与模板")
                FRChip(text: Text(verbatim: "\(enabledCount)/\(items.count)"), kind: enabledCount == 0 ? .warn : .neutral)
                    .help(Text("已启用的类型数"))
                Spacer()
                Button("恢复默认顺序") {
                    SharedConfig.shared.newFileOrder = []
                    newFileOrder = []
                }
                .buttonStyle(.frLink)
                .disabled(isDefaultOrder)
                .padding(.trailing, 4)

                Button {
                    showingAddSheet = true
                } label: {
                    Label("添加自定义模板…", systemImage: "plus")
                }
                .buttonStyle(.frPrimary)
            }
        } content: {
            FRCard {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { FRDivider() }
                    templateRow(item)
                }
            }

            FRFootnote(Text("关闭的类型不会出现在访达右键「新建文件」子菜单中。拖动左侧的 ≡ 可调整顺序，双击自定义模板可编辑。"))
        }
    }

    private func templateRow(_ item: NewFileTemplateItem) -> some View {
        let isEnabled = !hiddenTemplates.contains(item.id)
        let title = Self.displayTitle(of: item)

        return HStack(spacing: 10) {
            // 只有把手可以拖起，避免与开关、按钮的点击冲突；整行都是放置目标
            FRGrip()
                .draggable(item.id)
                .help("拖动调整在右键菜单中的顺序")

            HStack(spacing: 12) {
                NewFileTemplateIcon(item: item)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(verbatim: title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(FRTheme.text)
                            .lineLimit(1)
                        if item.isCustom {
                            FRChip(text: Text("自定义"))
                        }
                    }
                    detailLine(item, showsExtension: title != ".\(item.fileExtension)")
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            // 双击只挂在图标与文字上，不影响行尾开关和按钮的单击
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { edit(item) }

            Spacer(minLength: 8)

            if item.isCustom {
                HStack(spacing: 2) {
                    RowIconButton(systemName: "pencil", help: "编辑模板") { edit(item) }
                    RowIconButton(systemName: "trash", help: "删除", isDestructive: true) { confirmDelete(item, title: title) }
                }
            } else {
                // 内置类型可以随时从下方「已移除的内置类型」恢复，不必确认
                RowIconButton(systemName: "minus.circle", help: "从列表移除", isDestructive: true) { removeBuiltIn(item) }
            }

            FRSwitch(label: LocalizedStringKey(item.name), isOn: Binding(
                get: { isEnabled },
                set: { enabled in
                    SharedConfig.shared.setNewFileTemplateEnabled(item.id, enabled: enabled)
                    hiddenTemplates = SharedConfig.shared.hiddenNewFileTemplates
                }
            ))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(dropTargetId == item.id ? FRTheme.selection : Color.clear)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            return moveItem(id, to: item.id)
        } isTargeted: { targeted in
            if targeted {
                dropTargetId = item.id
            } else if dropTargetId == item.id {
                dropTargetId = nil
            }
        }
    }

    // MARK: - 已移除的内置类型

    private var removedSection: some View {
        FRSection("已移除的内置类型") {
            FRCard {
                ForEach(Array(removedItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { FRDivider() }
                    HStack(spacing: 12) {
                        NewFileTemplateIcon(item: item)
                            .opacity(0.6)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: Self.displayTitle(of: item))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(FRTheme.text)
                            detailLine(item, showsExtension: true)
                        }
                        Spacer(minLength: 8)
                        Button("恢复") { restoreBuiltIn(item) }
                            .buttonStyle(.frSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            FRFootnote(Text("恢复后重新出现在上方列表中，并处于开启状态。"))
        }
    }

    /// 第二行：后缀 + 新建出来的文件里有什么（Office 空白文档 / 空白文件 / 默认内容的首行）
    private func detailLine(_ item: NewFileTemplateItem, showsExtension: Bool) -> some View {
        HStack(spacing: 6) {
            if showsExtension {
                Text(verbatim: ".\(item.fileExtension)")
                    .font(.system(size: 11.5, design: .monospaced))
                Text(verbatim: "·")
            }
            if item.isOffice {
                Text("空白 Office 文档")
            } else if let firstLine = Self.firstLine(of: item.content) {
                Text(verbatim: firstLine)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("空白文件")
            }
        }
        .font(.system(size: 12))
        .foregroundColor(FRTheme.mute)
        .lineLimit(1)
    }

    /// 内置名称自带「(.txt)」这类后缀，第二行已单独显示后缀，这里去掉避免重复。
    /// 自定义模板的名称是用户原文，不查本地化表
    private static func displayTitle(of item: NewFileTemplateItem) -> String {
        guard !item.isCustom else { return item.name }
        let localized = NSLocalizedString(item.name, comment: "")
        let suffix = " (.\(item.fileExtension))"
        return localized.hasSuffix(suffix) ? String(localized.dropLast(suffix.count)) : localized
    }

    /// 默认内容里第一行非空文字；全空时返回 nil
    private static func firstLine(of content: String) -> String? {
        content.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    private func edit(_ item: NewFileTemplateItem) {
        guard item.isCustom, let target = customTemplates.first(where: { $0.id == item.id }) else { return }
        editingTemplate = target
    }

    private func confirmDelete(_ item: NewFileTemplateItem, title: String) {
        let dialog = FRDialog(
            title: String(format: NSLocalizedString("删除模板「%@」？", comment: ""), title),
            message: NSLocalizedString("删除后它不再出现在右键「新建文件」中，已经新建的文件不受影响。", comment: ""),
            symbol: "trash", tone: .warning,
            buttons: [NSLocalizedString("删除", comment: ""), NSLocalizedString("取消", comment: "")])
        let completion: (Int?) -> Void = { choice in
            if choice == 0 { deleteCustomTemplate(withId: item.id) }
        }
        if let window = NSApp.keyWindow {
            dialog.beginSheet(for: window, completion: completion)
        } else {
            completion(dialog.runModal())
        }
    }

    private func removeBuiltIn(_ item: NewFileTemplateItem) {
        SharedConfig.shared.removeBuiltInNewFileTemplate(item.id)
        reload()
    }

    private func restoreBuiltIn(_ item: NewFileTemplateItem) {
        SharedConfig.shared.restoreBuiltInNewFileTemplate(item.id)
        reload()
    }

    private func moveItem(_ id: String, to targetId: String) -> Bool {
        dropTargetId = nil
        guard id != targetId else { return false }
        var currentItems = items
        guard let from = currentItems.firstIndex(where: { $0.id == id }),
              let to = currentItems.firstIndex(where: { $0.id == targetId }) else { return false }
        let moved = currentItems.remove(at: from)
        currentItems.insert(moved, at: to)
        let order = currentItems.map(\.id)
        newFileOrder = order
        SharedConfig.shared.newFileOrder = order
        return true
    }

    private func deleteCustomTemplate(withId id: String) {
        SharedConfig.shared.removeFileTemplate(withId: id)
        reload()
    }

    private func reload() {
        customTemplates = SharedConfig.shared.customFileTemplates
        newFileOrder = SharedConfig.shared.newFileOrder
        hiddenTemplates = SharedConfig.shared.hiddenNewFileTemplates
        removedTemplates = SharedConfig.shared.removedNewFileTemplates
    }
}

// MARK: - 行内小按钮

/// 行尾的图标按钮：悬停时显示底色，删除类悬停时变为警示色
private struct RowIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var isDestructive = false
    let action: () -> Void

    @FRState private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(isHovering ? (isDestructive ? FRTheme.danger : FRTheme.text) : FRTheme.mute)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? FRTheme.hover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

// MARK: - 图标视图

private struct NewFileTemplateIcon: View {
    let item: NewFileTemplateItem

    var body: some View {
        Image(systemName: item.systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(Color(nsColor: item.tint.dynamicLineColor()))
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: item.tint.dynamicTileColor()).opacity(0.16))
            )
    }
}

// MARK: - 编辑/新建模板 Sheet

struct EditTemplateSheet: View {
    let template: FileTemplate?
    @Binding var isPresented: Bool
    let onSave: (FileTemplate) -> Void

    @FRState private var name: String = ""
    @FRState private var fileExtension: String = ""
    @FRState private var content: String = ""

    private var isEditing: Bool { template != nil }

    /// 去掉首尾空白与用户顺手带上的点
    private var cleanExtension: String {
        fileExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private var cleanName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isExtensionValid: Bool {
        !cleanExtension.isEmpty && SafeFileName.isValid(baseName: "untitled", ext: cleanExtension)
    }

    /// 已有同后缀的类型时提醒（不拦截：两者会同时出现在子菜单里）
    private var duplicateName: String? {
        guard isExtensionValid else { return nil }
        let ext = cleanExtension.lowercased()
        let others = NewFileTemplateCatalog.resolvedTemplates(
            order: [], customTemplates: SharedConfig.shared.customFileTemplates.filter { $0.id != template?.id })
        guard let match = others.first(where: { $0.fileExtension.lowercased() == ext }) else { return nil }
        return match.isCustom ? match.name : NSLocalizedString(match.name, comment: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                FRIconChip(systemName: "doc.badge.plus", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isEditing ? "编辑文件模板" : "新建文件模板")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(FRTheme.text)
                    Text("出现在访达右键「新建文件」子菜单中")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                field("名称", hint: "可留空，留空时菜单里显示后缀名") {
                    TextField("例如：配置文件", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                field("后缀", hint: nil) {
                    HStack(spacing: 4) {
                        Text(verbatim: ".")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundColor(FRTheme.mute)
                        TextField("conf", text: $fileExtension)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 150)
                    }
                }

                field("默认内容", hint: "新建的文件会写入这些文字；留空则新建空白文件") {
                    TextEditor(text: $content)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 120)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FRTheme.field))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(FRTheme.fieldBorder, lineWidth: 1)
                        )
                }
            }

            statusLine

            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.frSecondary)

                Button(isEditing ? "保存" : "添加") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.frPrimary)
                .disabled(!isExtensionValid)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(FRTheme.window)
        .onAppear {
            if let t = template {
                name = t.name
                fileExtension = t.fileExtension
                content = t.content
            }
        }
    }

    /// 表单下方的一行状态：后缀非法时报错，否则预览新建出来的文件名，同后缀已存在时另加提醒
    @ViewBuilder
    private var statusLine: some View {
        if !cleanExtension.isEmpty && !isExtensionValid {
            Label("文件后缀不能包含 / 或控制字符", systemImage: "exclamationmark.circle")
                .font(.system(size: 12))
                .foregroundColor(FRTheme.danger)
        } else if isExtensionValid {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                    Text("新建出的文件名")
                    Text(verbatim: "untitled.\(cleanExtension)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(FRTheme.text)
                }
                .font(.system(size: 12))
                .foregroundColor(FRTheme.mute)

                if let duplicateName {
                    Label(String(format: NSLocalizedString("已有同后缀的「%@」，两者都会出现在子菜单中", comment: ""), duplicateName),
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.warnText)
                }
            }
        }
    }

    private func field<Content: View>(_ title: LocalizedStringKey, hint: LocalizedStringKey?,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(FRTheme.text)
            content()
            if let hint {
                Text(hint)
                    .font(.system(size: 11.5))
                    .foregroundColor(FRTheme.mute)
            }
        }
    }

    private func submit() {
        guard isExtensionValid else { return }
        let id = template?.id ?? UUID().uuidString
        onSave(FileTemplate(id: id, name: cleanName, fileExtension: cleanExtension, content: content))
        isPresented = false
    }
}
