import SwiftUI
import AppKit
import FinderRightKit

struct DeveloperToolsTab: View {
    @FRState private var isEnabled = SharedConfig.shared.developerToolsEnabled
    @FRState private var commands = SharedConfig.shared.developerCommands
    @FRState private var order = SharedConfig.shared.developerMenuOrder
    @FRState private var dropTargetId: String?
    @FRState private var editingCommand: DeveloperCommand?

    private var menuOrder: [String] {
        MenuFeatureCatalog.normalizedOrder(order, defaults: MenuFeatureCatalog.developerFeatureIds + commands.map(\.menuId))
    }

    var body: some View {
        FRPage(title: "开发者工具") {
            FRSection("通用") {
                FRCard {
                    FRRow(title: Text("启用开发者工具")) {
                        FRSwitch(label: "启用开发者工具", isOn: Binding(
                            get: { isEnabled },
                            set: {
                                isEnabled = $0
                                SharedConfig.shared.developerToolsEnabled = $0
                                if ServiceShortcutSync.run() { NSUpdateDynamicServices() }
                                FinderShortcutInterceptor.shared.refresh()
                            }))
                    }
                }
            }

            if isEnabled {
                FRSection {
                    HStack {
                        FRCaption("右键菜单功能")
                        Spacer()
                        Button("恢复默认顺序") {
                            order = []
                            SharedConfig.shared.developerMenuOrder = []
                        }
                        .buttonStyle(.frLink)
                        .disabled(menuOrder == MenuFeatureCatalog.developerFeatureIds + commands.map(\.menuId))
                        Button {
                            editingCommand = DeveloperCommand(name: "", script: "")
                        } label: {
                            Label("添加命令…", systemImage: "plus")
                        }
                        .buttonStyle(.frPrimary)
                    }
                } content: {
                    FRCard {
                        ForEach(Array(menuOrder.enumerated()), id: \.element) { index, id in
                            if index > 0 { FRDivider() }
                            HStack(spacing: 10) {
                                FRGrip().draggable(id)
                                    .help("拖动调整在右键菜单中的顺序")
                                if let feature = MenuFeatureCatalog.feature(forId: id) {
                                    FeatureToggleRow(feature: feature)
                                } else if let command = commands.first(where: { $0.menuId == id }) {
                                    commandRow(command)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(dropTargetId == id ? FRTheme.selection : Color.clear)
                            .dropDestination(for: String.self) { ids, _ in
                                guard let source = ids.first else { return false }
                                return move(source, to: id)
                            } isTargeted: { targeted in
                                dropTargetId = targeted ? id : nil
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $editingCommand) { command in
            EditDeveloperCommandSheet(command: command) { updated in
                if let index = commands.firstIndex(where: { $0.id == updated.id }) { commands[index] = updated }
                else { commands.append(updated) }
                SharedConfig.shared.developerCommands = commands
            }
        }
    }

    private func commandRow(_ command: DeveloperCommand) -> some View {
        HStack(spacing: 12) {
            FRIconChip(systemName: "terminal")
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: command.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                Text(verbatim: command.script)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(FRTheme.mute)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Button { editingCommand = command } label: { Image(systemName: "pencil") }
                .buttonStyle(.frLink)
                .help("编辑命令")
                .accessibilityLabel("编辑命令")
            Button {
                commands.removeAll { $0.id == command.id }
                SharedConfig.shared.developerCommands = commands
                order = menuOrder
                SharedConfig.shared.developerMenuOrder = order
            } label: { Image(systemName: "trash") }
                .buttonStyle(.frLink)
                .help("删除命令")
                .accessibilityLabel("删除命令")
            FRSwitch(label: "启用命令", isOn: Binding(
                get: { command.isEnabled },
                set: { enabled in
                    guard let index = commands.firstIndex(where: { $0.id == command.id }) else { return }
                    commands[index].isEnabled = enabled
                    SharedConfig.shared.developerCommands = commands
                }))
        }
    }

    private func move(_ id: String, to target: String) -> Bool {
        dropTargetId = nil
        var updated = menuOrder
        guard id != target, let from = updated.firstIndex(of: id), let to = updated.firstIndex(of: target) else { return false }
        updated.insert(updated.remove(at: from), at: to)
        order = updated
        SharedConfig.shared.developerMenuOrder = updated
        return true
    }
}

private struct EditDeveloperCommandSheet: View {
    @Environment(\.dismiss) private var dismiss
    let command: DeveloperCommand
    let onSave: (DeveloperCommand) -> Void
    @FRState private var name = ""
    @FRState private var script = ""

    private var updated: DeveloperCommand {
        DeveloperCommand(id: command.id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                         script: script, isEnabled: command.isEnabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("自定义命令").font(.system(size: 19, weight: .bold))
            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.system(size: 12, weight: .medium))
                TextField("菜单名称", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("命令（zsh）").font(.system(size: 12, weight: .medium))
                TextEditor(text: $script)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 170)
                    .background(FRTheme.field)
                    .cornerRadius(7)
                Text("选中项通过 \"$@\" 传入；后台运行，不支持交互输入。")
                    .font(.system(size: 12)).foregroundColor(FRTheme.mute)
            }
            Text("命令可修改文件，不支持撤销。")
                .font(.system(size: 12)).foregroundColor(FRTheme.mute)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.frSecondary).keyboardShortcut(.cancelAction)
                Button("保存") { onSave(updated); dismiss() }
                    .buttonStyle(.frPrimary).keyboardShortcut(.defaultAction)
                    .disabled(!updated.isValid)
            }
        }
        .padding(22)
        .frame(width: 500)
        .foregroundColor(FRTheme.text)
        .background(FRTheme.window)
        .onAppear { name = command.name; script = command.script }
    }
}
