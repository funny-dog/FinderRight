import SwiftUI
import AppKit
import FinderRightKit

struct OperationHistoryView: View {
    let store: RecentOperations
    @AppStorage(RecentOperations.capacityKey) private var savedLimit = 100
    @FRState private var records: [OperationRecord]
    @FRState private var persistenceError: String?
    @FRState private var filter: OperationHistoryFilter
    @FRState private var expanded: Set<UUID>
    /// 取消调整保留条数时刷新下拉框，让它退回原来的选项
    @FRState private var limitPickerToken = 0

    init(store: RecentOperations = .shared, filter: OperationHistoryFilter = OperationHistoryFilter(),
         expanded: Set<UUID> = []) {
        self.store = store
        _records = FRState(initialValue: store.records)
        _persistenceError = FRState(initialValue: store.persistenceError)
        _filter = FRState(initialValue: filter)
        _expanded = FRState(initialValue: expanded)
    }

    var body: some View {
        FRPage(title: "操作历史", subtitle: "查看文件操作的结果，快速找到处理后的文件。") {
            preferences

            if persistenceError != nil {
                persistenceWarning
            }

            if records.isEmpty {
                emptyState
            } else {
                let counts = filter.statusCounts(in: records)
                let visible = filter.apply(to: records)
                toolbar(counts: counts, visibleCount: visible.count)
                if visible.isEmpty {
                    noMatches
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(OperationHistoryPresentation.dayGroups(visible)) { group in
                            daySection(group)
                        }
                    }
                }
            }
            // 历史记录用于回看操作，不代表每条都能撤销。当前仍通过访达右键或 ⌘Z 撤销上一次操作。
        }
        .onReceive(NotificationCenter.default.publisher(for: RecentOperations.didChangeNotification)) { notification in
            guard notification.object as? RecentOperations === store else { return }
            records = store.records
            persistenceError = store.persistenceError
            // 已被清理掉的记录不再占着展开状态
            expanded.formIntersection(records.map(\.id))
        }
    }

    // MARK: - 记录偏好

    private var preferences: some View {
        FRCard {
            // 记录新建、剪切、粘贴、移动、复制、压缩解压和撤销的结果
            FRRow(title: Text("保留历史记录")) {
                HStack(spacing: 10) {
                    FRPicker(label: "保留历史记录", selection: Binding(
                        get: { savedLimit },
                        set: { setLimit($0) }
                    )) {
                        Text("不保留").tag(0)
                        Text("最近 50 条").tag(50)
                        Text("最近 100 条").tag(100)
                        Text("最近 500 条").tag(500)
                    }
                    .id(limitPickerToken)
                    Button("清空历史", action: clearHistory)
                        .buttonStyle(.frSecondary)
                        .disabled(records.isEmpty)
                }
            }
        }
        .help(Text("仅保存在这台 Mac，重启后仍保留。超出条数时移除最早的记录，不会删除你的文件。"))
    }

    private var persistenceWarning: some View {
        Label("历史记录暂时无法保存到本机，当前记录仍可查看。请检查磁盘空间与文件夹权限。", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12))
            .foregroundColor(FRTheme.warnText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FRTheme.warnBackground))
    }

    // MARK: - 搜索与筛选

    private func toolbar(counts: [OperationHistoryFilter.Status: Int], visibleCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                searchField
                kindFilter
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    statusChips(counts)
                    Spacer(minLength: 8)
                    resultSummary(visibleCount)
                }
                VStack(alignment: .leading, spacing: 8) {
                    statusChips(counts)
                    resultSummary(visibleCount)
                }
                VStack(alignment: .leading, spacing: 8) {
                    FRPicker(label: "操作状态", selection: $filter.status) {
                        ForEach(OperationHistoryFilter.Status.allCases, id: \.self) { status in
                            Text(LocalizedStringKey(status.titleKey)).tag(status)
                        }
                    }
                    .controlSize(.small)
                    resultSummary(visibleCount)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(FRTheme.mute)
                .accessibilityHidden(true)
            TextField("搜索操作、文件名或位置", text: $filter.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(FRTheme.text)
                .accessibilityLabel(Text("搜索操作历史"))
            if !filter.searchText.isEmpty {
                Button { filter.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(FRTheme.mute)
                .help(Text("清除搜索"))
                .accessibilityLabel(Text("清除搜索"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FRTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(FRTheme.fieldBorder, lineWidth: 1))
        .help(Text("可匹配操作名称、文件名、路径和失败说明；多个关键词用空格分隔。"))
    }

    /// 只列出历史里出现过的操作类型，外加当前选中的那个
    private var kindFilter: some View {
        let present = Set(records.map(\.kind))
        let kinds = OperationHistoryFilter.kinds.filter { present.contains($0) || $0 == filter.kind }
        return FRPicker(label: "操作类型", selection: $filter.kind) {
            Text("全部操作").tag(Optional<OperationRecord.Kind>.none)
            ForEach(kinds, id: \.self) { kind in
                Text(verbatim: OperationHistoryPresentation.actionTitle(kind)).tag(Optional(kind))
            }
        }
    }

    /// 状态标签：数量为 0 的状态不显示（「全部」与当前选中项除外）
    private func statusChips(_ counts: [OperationHistoryFilter.Status: Int]) -> some View {
        HStack(spacing: 6) {
            ForEach(OperationHistoryFilter.Status.allCases, id: \.self) { status in
                let count = counts[status, default: 0]
                if status == .all || count > 0 || status == filter.status {
                    StatusFilterChip(status: status, count: count, isSelected: filter.status == status) {
                        filter.status = status
                    }
                }
            }
        }
        .fixedSize()
    }

    private func resultSummary(_ visibleCount: Int) -> some View {
        HStack(spacing: 10) {
            Group {
                if filter.isActive {
                    Text("\(visibleCount) / \(records.count) 条")
                } else {
                    Text("\(records.count) 条")
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundColor(FRTheme.mute)
            if filter.isActive {
                Button("重置筛选") { filter = OperationHistoryFilter() }
                    .buttonStyle(.frLink)
            }
        }
        .fixedSize()
    }

    // MARK: - 列表

    private func daySection(_ group: OperationHistoryPresentation.DayGroup) -> some View {
        FRSection {
            HStack(spacing: 6) {
                Text(verbatim: OperationHistoryPresentation.dayTitle(group.day))
                Text("\(group.records.count) 条")
                    .fontWeight(.regular)
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FRTheme.mute)
            .padding(.leading, 4)
        } content: {
            FRCard {
                ForEach(Array(group.records.enumerated()), id: \.element.id) { index, record in
                    if index > 0 { FRDivider().padding(.leading, 52) }
                    OperationHistoryRow(record: record, isExpanded: Binding(
                        get: { expanded.contains(record.id) },
                        set: { isOn in
                            if isOn { expanded.insert(record.id) } else { expanded.remove(record.id) }
                        }
                    ))
                }
            }
        }
    }

    private var noMatches: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .accessibilityHidden(true)
            Text("没有找到匹配的记录")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(FRTheme.text)
            Text("试试其他关键词，或重置操作类型和状态筛选。")
                .font(.system(size: 12.5))
                .multilineTextAlignment(.center)
            Button("重置筛选") { filter = OperationHistoryFilter() }
                .buttonStyle(.frSecondary)
                .padding(.top, 4)
        }
        .foregroundColor(FRTheme.mute)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: savedLimit == 0 ? "clock.badge.xmark" : "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
                .foregroundColor(FRTheme.mute)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(savedLimit == 0 ? "操作历史已关闭" : "还没有操作记录"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(FRTheme.text)
            Text(LocalizedStringKey(savedLimit == 0
                 ? "选择保留条数后，新的文件操作会出现在这里。不保留历史时，操作失败仍会提示。"
                 : "用 FinderRight 新建、移动或压缩文件后，就能在这里查看结果。"))
                .font(.system(size: 12.5))
                .foregroundColor(FRTheme.mute)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 330)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: - 操作

    private func setLimit(_ limit: Int) {
        if limit < store.records.count {
            let message = limit == 0
                ? NSLocalizedString("现有的历史记录会全部移除，之后也不再记录。这只影响历史记录，不会删除文件或改变撤销状态。", comment: "history")
                : NSLocalizedString("超出新条数的较早记录会被移除。这只影响历史记录，不会删除文件或改变撤销状态。", comment: "history")
            let dialog = FRDialog(title: NSLocalizedString("减少保留的历史记录？", comment: "history"),
                                  message: message,
                                  symbol: "clock.arrow.circlepath", tone: .warning,
                                  buttons: [NSLocalizedString("确认调整", comment: "history"), NSLocalizedString("取消", comment: "history")])
            presentOperationHistoryDialog(dialog) { choice in
                if choice == 0 { applyLimit(limit) } else { limitPickerToken += 1 }
            }
            return
        }
        applyLimit(limit)
    }

    private func applyLimit(_ limit: Int) {
        savedLimit = limit
        store.setCapacity(limit)
        records = store.records
        persistenceError = store.persistenceError
    }

    private func clearHistory() {
        let dialog = FRDialog(title: NSLocalizedString("清空操作历史？", comment: "history"),
                              message: NSLocalizedString("会清空所有操作历史，包括未显示的记录。不会删除文件，也不会影响当前可撤销的操作。清空后无法恢复这些记录。", comment: "history"),
                              symbol: "trash", tone: .warning,
                              buttons: [NSLocalizedString("清空历史", comment: "history"), NSLocalizedString("取消", comment: "history")])
        presentOperationHistoryDialog(dialog) { if $0 == 0 { store.clear() } }
    }
}

/// 状态筛选标签：文字 + 数量，选中时用强调色底
