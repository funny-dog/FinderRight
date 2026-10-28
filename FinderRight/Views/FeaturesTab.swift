import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 功能 Tab

struct FeaturesTab: View {
    @FRState private var badgeOwnershipReclaim: Bool = SharedConfig.shared.badgeOwnershipReclaim
    @FRState private var copyPathFormat: CopyPathFormat = SharedConfig.shared.copyPathFormat
    @FRState private var copyFileNameFormat: CopyFileNameFormat = SharedConfig.shared.copyFileNameFormat
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

    /// 演示当前复制文件名格式
    private var copyFileNameExample: String {
        switch copyFileNameFormat {
        case .full:
            return "报告 2026.tar.gz"
        case .withoutExtension:
            return "报告 2026.tar"
        }
    }

    var body: some View {
        FRPage(title: "功能", subtitle: "选择出现在右键菜单中的功能，拖动调整顺序") {
            menuSection
            copyPathSection
            copyFileNameSection
            copyContentSection
            CutQueueSection()
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

    // MARK: 复制文件名

    private var copyFileNameSection: some View {
        FRSection("复制文件名") {
            FRCard {
                FRRow(title: Text("复制格式")) {
                    FRPicker(label: "复制格式", selection: Binding(
                        get: { copyFileNameFormat },
                        set: { newValue in
                            copyFileNameFormat = newValue
                            SharedConfig.shared.copyFileNameFormat = newValue
                        }
                    )) {
                        ForEach(CopyFileNameFormat.allCases) { format in
                            Text(LocalizedStringKey(format.titleKey)).tag(format)
                        }
                    }
                }

                FRDivider()

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("示例")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                    Text(verbatim: copyFileNameExample)
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

            FRFootnote(Text("不含扩展名时仅去除普通文件最后一段扩展名（如 report.tar.gz → report.tar）；目录（含 .app 包）与无扩展名文件保持原名。多选时每行一项。"))
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

/// 队列详情收在设置中，菜单栏保持简洁。
private struct CutQueueSection: View {
    @State private var paths: [String] = []
    @State private var errorMessage: String?

    var body: some View {
        FRSection("剪切 / 粘贴") {
            FRCard {
                DisclosureGroup {
                    ForEach(paths, id: \.self) { path in
                        FRRow(title: Text(verbatim: (path as NSString).lastPathComponent),
                              subtitle: Text(verbatim: path)) {
                            Button("移除") { remove(path) }
                                .buttonStyle(.frSecondary)
                                .accessibilityLabel(Text(String(format: NSLocalizedString("移除：%@", comment: "cut queue"), path)))
                        }
                    }
                } label: {
                    Text(String(format: NSLocalizedString("已剪切 %d 项", comment: "cut queue"), paths.count))
                }
                .padding(16)
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .foregroundColor(FRTheme.danger)
                        .padding(16)
                }
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(CutQueueChangeNotifier.name))) { _ in refresh() }
    }

    private func refresh() { paths = FinderRightService.pendingCutPaths() }

    private func remove(_ path: String) {
        do {
            try FinderRightService.removePendingCutPath(path)
            errorMessage = nil
        } catch CutQueueStore.RemovalError.pasteInProgress {
            errorMessage = NSLocalizedString("正在粘贴，请完成后再移除剪切项", comment: "cut queue")
        } catch {
            errorMessage = String(format: NSLocalizedString("移除剪切项失败：%@", comment: "cut queue"), error.localizedDescription)
        }
        refresh()
    }
}
