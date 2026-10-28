import SwiftUI
import AppKit
import FinderRightKit

/// 与其他设置页一致：弹窗以 sheet 挂在设置窗口上，找不到窗口时才退回模态。
/// 不在 SwiftUI 的按钮动作里直接 runModal，否则弹窗显示出来后按钮点不动
func presentOperationHistoryDialog(_ dialog: FRDialog, completion: @escaping (Int?) -> Void = { _ in }) {
    if let window = NSApp.keyWindow {
        dialog.beginSheet(for: window, completion: completion)
    } else {
        completion(dialog.runModal())
    }
}

struct StatusFilterChip: View {
    let status: OperationHistoryFilter.Status
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(LocalizedStringKey(status.titleKey))
                Text(verbatim: "\(count)")
                    .monospacedDigit()
                    .foregroundColor(isSelected ? FRTheme.accentText.opacity(0.75) : FRTheme.mute)
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundColor(isSelected ? FRTheme.accentText : FRTheme.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(isSelected ? FRTheme.selection : FRTheme.field))
            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : FRTheme.fieldBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct OperationHistoryRow: View {
    let record: OperationRecord
    @Binding var isExpanded: Bool
    @FRState private var isHovering = false
    @FRState private var showTechnicalDetails = false

    private var outcome: OperationHistoryPresentation.Outcome { OperationHistoryPresentation.Outcome(record) }
    private var actionTitle: String { OperationHistoryPresentation.actionTitle(record.kind) }
    private var folder: URL? { OperationHistoryPresentation.folder(record) }
    /// 撤销记录的结果是被还原的原文件，与「处理后的文件」含义不同，不提供定位
    private var canRevealResults: Bool { !record.results.isEmpty && record.kind != .undo }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                details
                    .transition(.opacity)
            }
        }
    }

    // MARK: 摘要行

    private var header: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: record.subject)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(FRTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitle
            }
            .help(record.subject)
            Spacer(minLength: 8)
            if outcome != .completed {
                FRChip(text: Text(LocalizedStringKey(outcome.titleKey)), kind: chipKind)
            }
            Text(record.date, style: .time)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundColor(FRTheme.mute)
            quickReveal
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(FRTheme.mute)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? FRTheme.hover : Color.clear)
                .padding(4)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilitySummary))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
        .accessibilityAction(named: Text("在访达中显示")) { revealResults() }
    }

    private var icon: some View {
        Image(systemName: OperationHistoryPresentation.symbol(record.kind))
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(tint)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tintBackground))
            .accessibilityHidden(true)
    }

    private var subtitle: some View {
        HStack(spacing: 4) {
            Text(verbatim: actionTitle)
                .layoutPriority(1)
            if let folder {
                Text(verbatim: "·")
                Text(verbatim: OperationHistoryPresentation.displayPath(folder))
                    .truncationMode(.middle)
            }
        }
        .font(.system(size: 11.5))
        .foregroundColor(FRTheme.mute)
        .lineLimit(1)
    }

    /// 悬停时出现的定位按钮；不悬停时仍占位，避免时间列左右跳动
    private var quickReveal: some View {
        Button(action: revealResults) {
            Image(systemName: "magnifyingglass.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(FRTheme.accentText)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("在访达中显示"))
        .opacity(isHovering && canRevealResults ? 1 : 0)
        .allowsHitTesting(isHovering && canRevealResults)
    }

    // MARK: 展开详情

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if outcome.needsAttention {
                failureCallout
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    detailLabel("完成时间")
                    Text(record.date, format: .dateTime.year().month().day().hour().minute().second())
                        .foregroundColor(FRTheme.text)
                }
                if let folder {
                    GridRow {
                        detailLabel("所在位置")
                        Text(verbatim: OperationHistoryPresentation.displayPath(folder))
                            .foregroundColor(FRTheme.text)
                            .textSelection(.enabled)
                            .help(folder.path)
                    }
                }
                if !record.results.isEmpty {
                    GridRow {
                        detailLabel("结果文件")
                        resultList
                    }
                }
            }
            actions
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 52)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
    }

    private func detailLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .foregroundColor(FRTheme.mute)
            .gridColumnAlignment(.leading)
    }

    private var resultList: some View {
        let shown = record.results.prefix(3)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(shown), id: \.self) { url in
                Text(verbatim: url.lastPathComponent)
                    .foregroundColor(FRTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(url.path)
            }
            if record.results.count > shown.count {
                Text("另外 \(record.results.count - shown.count) 项")
                    .foregroundColor(FRTheme.mute)
            }
        }
    }

    private var failureCallout: some View {
        VStack(alignment: .leading, spacing: 6) {
            if outcome == .partial {
                Text("已完成 \(record.results.count) 项，其余项目未完成")
                    .fontWeight(.semibold)
            }
            Text(verbatim: OperationHistoryPresentation.failureSummary(record))
            if let technical = record.failure, !technical.isEmpty {
                DisclosureGroup(isExpanded: $showTechnicalDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: technical)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(FRTheme.mute)
                            .textSelection(.enabled)
                        Button("拷贝") { copyTechnicalDetails(technical) }
                            .buttonStyle(.frLink)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("技术信息")
                        .foregroundColor(FRTheme.warnText)
                }
            }
        }
        .foregroundColor(FRTheme.text)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FRTheme.warnBackground))
    }

    @ViewBuilder
    private var actions: some View {
        let canOpenFolder = folder != nil && !canRevealResults
        if canRevealResults || canOpenFolder {
            HStack(spacing: 16) {
                if canRevealResults {
                    Button(action: revealResults) {
                        Label("在访达中显示", systemImage: "magnifyingglass")
                    }
                }
                if canOpenFolder {
                    Button(action: openFolder) {
                        Label("打开所在文件夹", systemImage: "folder")
                    }
                }
            }
            .buttonStyle(.frLink)
        }
    }

    // MARK: 状态与配色

    private var chipKind: FRChip.Kind {
        switch outcome {
        case .completed: return .ok
        case .partial, .failed: return .warn
        case .cancelled: return .neutral
        }
    }

    private var tint: Color {
        switch outcome {
        case .completed: return FRTheme.accentText
        case .partial, .failed: return FRTheme.warnText
        case .cancelled: return FRTheme.mute
        }
    }

    private var tintBackground: Color {
        switch outcome {
        case .completed: return FRTheme.selection
        case .partial, .failed: return FRTheme.warnBackground
        case .cancelled: return FRTheme.hover
        }
    }

    private var accessibilitySummary: String {
        let time = record.date.formatted(date: .omitted, time: .shortened)
        return [record.subject, actionTitle, OperationHistoryPresentation.status(record), time].joined(separator: ", ")
    }

    // MARK: 动作

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
    }

    private func revealResults() {
        guard canRevealResults else { return }
        let existing = record.results.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            presentOperationHistoryDialog(FRDialog(title: NSLocalizedString("找不到结果文件", comment: "history"),
                                   message: NSLocalizedString("这些文件可能已被移动、改名或删除。历史记录保留的是操作完成时的位置。", comment: "history"),
                                   symbol: "folder.badge.questionmark", buttons: [NSLocalizedString("好", comment: "history")]))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    private func openFolder() {
        guard let folder else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            presentOperationHistoryDialog(FRDialog(title: NSLocalizedString("找不到这个文件夹", comment: "history"),
                                   message: NSLocalizedString("它可能已被移动、改名或删除。历史记录保留的是操作发生时的位置。", comment: "history"),
                                   symbol: "folder.badge.questionmark", buttons: [NSLocalizedString("好", comment: "history")]))
            return
        }
        NSWorkspace.shared.open(folder)
    }

    private func copyTechnicalDetails(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
