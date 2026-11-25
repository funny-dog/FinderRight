import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 功能 Tab

struct FeaturesTab: View {
    @FRState private var badgeOwnershipReclaim: Bool = SharedConfig.shared.badgeOwnershipReclaim
    @FRState private var copyPathFormat: CopyPathFormat = SharedConfig.shared.copyPathFormat
    @FRState private var copyFileNameFormat: CopyFileNameFormat = SharedConfig.shared.copyFileNameFormat
    @FRState private var copyFileContentMaxSizeKB: Int = SharedConfig.shared.copyFileContentMaxSizeKB
    @FRState private var featureOrder: [MenuFeature] = MenuFeatureCatalog.ordered(by: SharedConfig.shared.menuOrder).filter { !MenuFeatureCatalog.developerFeatureIds.contains($0.id) }
    @FRState private var dropTargetId: String?
    @ObservedObject private var globalShortcut = GlobalDirectoryShortcut.shared
    @ObservedObject private var clipboardService = ClipboardHistoryService.shared
    @ObservedObject private var clipboardShortcut = GlobalClipboardShortcut.shared
    @ObservedObject private var screenshotService = ScreenshotService.shared

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
            copyOptionsSection
            clipboardSection
            screenshotSection
            enhancementsSection
            quickLookSection
        }
        .onAppear {
            featureOrder = MenuFeatureCatalog.ordered(by: SharedConfig.shared.menuOrder).filter { !MenuFeatureCatalog.developerFeatureIds.contains($0.id) }
            screenshotService.refreshPermission()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenshotService.refreshPermission()
        }
    }

    // MARK: 访达增强

    private var enhancementsSection: some View {
        FRSection("访达增强") {
            FRCard {
                FRRow(title: Text("打开路径全局快捷键"),
                      subtitle: Text("可在其他应用中用同一快捷键唤起")) {
                    FRSwitch(label: "打开路径快捷键全局生效", isOn: Binding(
                        get: { globalShortcut.isEnabled },
                        set: { setGlobalShortcut($0) }))
                }
                if let message = globalShortcut.errorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.warnText)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }

                FRDivider()

                // 其他访达扩展（如 Keka、Pearcleaner）可能占用角标显示权，导致剪切角标不显示。开启后，仅当所在目录有已剪切的文件时，FinderRight 才会短暂重启这些扩展以取回显示权（每次访达启动至多一次）。
                FRRow(title: Text("自动解决剪切角标冲突")) {
                    FRSwitch(label: "自动解决角标冲突", isOn: Binding(
                        get: { badgeOwnershipReclaim },
                        set: { newValue in
                            badgeOwnershipReclaim = newValue
                            SharedConfig.shared.badgeOwnershipReclaim = newValue
                        }
                    ))
                }
            }

            FRFootnote(Text("开启后可能隐藏网盘等扩展的同步角标。"))
        }
    }

    private func setGlobalShortcut(_ enabled: Bool) {
        guard enabled else {
            globalShortcut.setEnabled(false)
            refreshGlobalShortcut()
            return
        }
        guard SharedConfig.shared.shortcut(forActionId: FinderKeyTakeover.goToDirectoryActionId) != nil else {
            globalShortcut.setEnabled(true)
            return
        }
        let dialog = FRDialog(
            title: NSLocalizedString("让打开路径快捷键全局生效？", comment: ""),
            message: NSLocalizedString("开启后，在其他应用中按下该组合也会打开 FinderRight，可能覆盖原有操作（包括打开、保存对话框中的按键）。无法检测所有应用的快捷键冲突；注册成功也不代表没有冲突。", comment: ""),
            symbol: "keyboard", tone: .warning,
            buttons: [NSLocalizedString("开启全局生效", comment: ""), NSLocalizedString("取消", comment: "")])
        dialog.present { response in
            guard response == 0 else { return }
            globalShortcut.setEnabled(true)
            refreshGlobalShortcut()
        }
    }

    private func refreshGlobalShortcut() {
        FinderShortcutInterceptor.shared.refresh()
        if ServiceShortcutSync.run() { NSUpdateDynamicServices() }
    }

    // MARK: 剪贴板

    private var clipboardSection: some View {
        FRSection("剪贴板") {
            FRCard {
                FRRow(title: Text("启用剪贴板"),
                      subtitle: Text("本机记录最近复制的文本、图片与文件，关闭时清空")) {
                    FRSwitch(label: "启用剪贴板", isOn: Binding(
                        get: { clipboardService.isEnabled },
                        set: { clipboardService.setEnabled($0) }))
                }

                if clipboardService.isEnabled {
                    FRDivider()
                    FRRow(title: Text("记录密码等敏感内容"),
                          subtitle: Text("同时记录「密码」应用及敏感、临时内容")) {
                        FRSwitch(label: "记录密码等敏感内容", isOn: Binding(
                            get: { clipboardService.recordSensitive },
                            set: { clipboardService.setRecordSensitive($0) }))
                    }
                }

                if let message = clipboardShortcut.errorMessage {
                    FRDivider()
                    Text(verbatim: message)
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.warnText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }

            FRFootnote(Text("全局快捷键请在「快捷键」页设置。"))
        }
    }

    // MARK: 截图

    private var screenshotModeSubtitle: LocalizedStringKey {
        switch screenshotService.mode {
        case .system:
            return LocalizedStringKey("唤起系统原生截图（⌘⇧5），免录制权限")
        case .snapshot:
            return LocalizedStringKey("定格屏幕框选，可标注、复制或保存")
        }
    }

    private var screenshotSection: some View {
        FRSection("截图") {
            FRCard {
                FRRow(title: Text("启用截图"),
                      subtitle: Text("通过菜单栏或全局快捷键快速截图")) {
                    FRSwitch(label: "启用截图", isOn: Binding(
                        get: { screenshotService.isEnabled },
                        set: { screenshotService.setEnabled($0) }))
                }

                if screenshotService.isEnabled {
                    FRDivider()
                    FRRow(title: Text("截图方式"), subtitle: Text(screenshotModeSubtitle)) {
                        FRSegmentedPicker(
                            label: "截图方式",
                            selection: Binding(
                                get: { screenshotService.mode },
                                set: { screenshotService.setMode($0) }
                            ),
                            ScreenshotMode.allCases,
                            titleKey: \.titleKey
                        )
                    }

                    if screenshotService.mode == .snapshot && !screenshotService.hasScreenCaptureAccess {
                        FRDivider()
                        FRRow(title: Text("需要「屏幕录制」权限"),
                              subtitle: Text("未授权时无法截取其他应用窗口")) {
                            HStack(spacing: 8) {
                                Button("重新检测") { screenshotService.refreshPermission() }
                                    .buttonStyle(.frSecondary)
                                Button("授权屏幕录制…") { screenshotService.requestScreenCapturePermission() }
                                    .buttonStyle(.frPrimary)
                            }
                        }
                    }
                }

                if let message = screenshotService.errorMessage {
                    FRDivider()
                    Text(verbatim: message)
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.warnText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                }
            }

            FRFootnote(Text("全局快捷键请在「快捷键」页设置。"))
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
                    featureOrder = MenuFeatureCatalog.regular
                }
                .buttonStyle(.frLink)
                .disabled(featureOrder.map(\.id) == MenuFeatureCatalog.regular.map(\.id))
                .padding(.trailing, 4)
            }
        } content: {
            FRCard {
                ForEach(Array(featureOrder.enumerated()), id: \.element.id) { index, feature in
                    if index > 0 { FRDivider() }
                    featureRow(feature)
                }
            }

            FRFootnote(Text("关闭项不显示在右键菜单，拖动 ≡ 可排序。"))
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frDropTarget(dropTargetId == feature.id)
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

    // MARK: 复制选项

    private var copyOptionsSection: some View {
        FRSection("复制选项") {
            FRCard {
                FRRow(
                    title: Text("复制路径格式"),
                    subtitle: Text(verbatim: copyPathExample)
                        .font(.system(size: 11.5, design: .monospaced))
                ) {
                    FRPicker(label: "复制路径格式", titleKey: copyPathFormat.titleKey, selection: Binding(
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

                FRRow(
                    title: Text("复制文件名格式"),
                    subtitle: Text(verbatim: copyFileNameExample)
                        .font(.system(size: 11.5, design: .monospaced))
                ) {
                    FRSegmentedPicker(
                        label: "复制文件名格式",
                        selection: Binding(
                            get: { copyFileNameFormat },
                            set: { newValue in
                                copyFileNameFormat = newValue
                                SharedConfig.shared.copyFileNameFormat = newValue
                            }
                        ),
                        CopyFileNameFormat.allCases,
                        titleKey: \.titleKey
                    )
                }

                FRDivider()

                FRRow(title: Text("复制文件内容上限"), subtitle: Text("单选且不超过此大小时显示")) {
                    let selectedPreset = CopyFileContentSizePreset(rawValue: copyFileContentMaxSizeKB) ?? .mb1
                    FRPicker(label: "复制文件内容上限", titleKey: selectedPreset.titleKey, selection: Binding(
                        get: {
                            CopyFileContentSizePreset(rawValue: copyFileContentMaxSizeKB) ?? .mb1
                        },
                        set: { newValue in
                            copyFileContentMaxSizeKB = newValue.rawValue
                            SharedConfig.shared.copyFileContentMaxSizeKB = newValue.rawValue
                        }
                    )) {
                        ForEach(CopyFileContentSizePreset.allCases) { preset in
                            Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                        }
                    }
                }
            }

            FRFootnote(Text("路径与文件名多选时每行一项（Shell 转义以空格分隔）；文件内容仅单选且不超过上限时显示。"))
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
                Text("检测到其他 Markdown 预览扩展，系统可能优先使用")
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
