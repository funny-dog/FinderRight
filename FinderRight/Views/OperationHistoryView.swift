import SwiftUI
import AppKit
import FinderRightKit

enum OperationHistoryPresentation {
    private static func L(_ key: String) -> String { NSLocalizedString(key, comment: "operation history") }

    /// 一条记录的结果；状态文案、配色与筛选都从这里派生，避免多处各写一套判断
    enum Outcome: CaseIterable {
        case completed, partial, failed, cancelled

        init(_ record: OperationRecord) {
            if record.cancelled {
                self = .cancelled
            } else if record.failure == nil {
                self = .completed
            } else {
                self = record.results.isEmpty ? .failed : .partial
            }
        }

        var titleKey: String {
            switch self {
            case .completed: return "已完成"
            case .partial: return "部分完成"
            case .failed: return "未完成"
            case .cancelled: return "已取消"
            }
        }

        var needsAttention: Bool { self == .partial || self == .failed }
    }

    /// 同一天的记录，按时间倒序
    struct DayGroup: Identifiable {
        let day: Date
        var records: [OperationRecord]
        var id: Date { day }
    }

    static func actionTitle(_ kind: OperationRecord.Kind) -> String {
        switch kind {
        case .createFile: return L("新建文件")
        case .cut: return L("剪切文件")
        case .compress: return L("压缩文件")
        case .decompress: return L("解压文件")
        case .paste: return L("粘贴文件")
        case .move: return L("移动文件")
        case .copy: return L("复制文件")
        case .undo: return L("撤销操作")
        }
    }

    static func symbol(_ kind: OperationRecord.Kind) -> String {
        switch kind {
        case .createFile: return "doc.badge.plus"
        case .cut: return "scissors"
        case .compress: return "archivebox"
        case .decompress: return "shippingbox"
        case .paste: return "doc.on.clipboard"
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        case .undo: return "arrow.uturn.backward"
        }
    }

    static func status(_ record: OperationRecord) -> String {
        L(Outcome(record).titleKey)
    }

    static func transferSuccessMessage(_ record: OperationRecord) -> String? {
        guard record.succeeded, !record.results.isEmpty,
              record.kind == .move || record.kind == .copy else { return nil }
        let format = record.kind == .move ? L("已移动 %d 项到“%@”") : L("已复制 %d 项到“%@”")
        let folder = folder(record)?.lastPathComponent ?? ""
        return String(format: format, record.results.count, OperationRecord.truncatedSubject(folder))
    }

    static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L("今天") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return L("昨天") }
        return date.formatted(.dateTime.year().month().day())
    }

    /// 一次遍历按天分组：组按日期倒序，组内保持传入顺序
    static func dayGroups(_ records: [OperationRecord], calendar: Calendar = .current) -> [DayGroup] {
        var groups: [DayGroup] = []
        var indexByDay: [Date: Int] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.date)
            if let index = indexByDay[day] {
                groups[index].records.append(record)
            } else {
                indexByDay[day] = groups.count
                groups.append(DayGroup(day: day, records: [record]))
            }
        }
        return groups.sorted { $0.day > $1.day }
    }

    /// 失败记录用于定位的文件夹：优先记录时的位置，其次结果文件所在目录
    static func folder(_ record: OperationRecord) -> URL? {
        record.location ?? record.results.first?.deletingLastPathComponent()
    }

    static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    static func failureSummary(_ record: OperationRecord) -> String {
        let details = (record.failure ?? "").lowercased()
        if details.contains("permission") || details.contains("denied") || details.contains("not permitted") || details.contains("权限") || details.contains("不允许") {
            return L("无法访问文件或写入目标文件夹。请检查文件夹权限，必要时在设置中授予完全磁盘访问权限。")
        }
        if details.contains("no space") || details.contains("disk full") || details.contains("空间不足") || details.contains("磁盘已满") {
            return L("磁盘剩余空间不足。请腾出空间后重试。")
        }
        if details.contains("password") || details.contains("encrypted") || details.contains("密码") || details.contains("加密") {
            return L("压缩包需要正确的密码，或使用了暂不支持的加密方式。请确认密码与压缩包格式。")
        }
        if details.contains("no such file") || details.contains("not found") || details.contains("does not exist") || details.contains("doesn’t exist") || details.contains("不存在") || details.contains("找不到") {
            return L("找不到所需的文件或文件夹。它可能已被移动或删除，请确认位置后重试。")
        }
        if details.contains("already exists") || details.contains("file exists") || details.contains("同名") || details.contains("冲突") {
            return L("目标位置已有同名项目。请处理同名文件后重试。")
        }
        if !record.results.isEmpty {
            return L("部分项目已完成，其余项目未能处理。请查看详细信息，确认未完成的文件后再重试。")
        }
        if record.kind == .decompress {
            return L("未能解开这个压缩包。请确认文件完整、格式受支持，再重试。")
        }
        return L("这次操作未能完成。请确认文件仍在原处、目标文件夹可以写入，再重试。")
    }
}

struct OperationHistoryFilter {
    enum Status: Hashable, CaseIterable {
        case all, completed, partial, failed, cancelled

        init(_ outcome: OperationHistoryPresentation.Outcome) {
            switch outcome {
            case .completed: self = .completed
            case .partial: self = .partial
            case .failed: self = .failed
            case .cancelled: self = .cancelled
            }
        }

        var titleKey: String {
            switch self {
            case .all: return "全部"
            case .completed: return "已完成"
            case .partial: return "部分完成"
            case .failed: return "未完成"
            case .cancelled: return "已取消"
            }
        }

        func matches(_ record: OperationRecord) -> Bool {
            self == .all || self == Status(OperationHistoryPresentation.Outcome(record))
        }
    }

    static let kinds: [OperationRecord.Kind] = [.createFile, .cut, .paste, .move, .copy, .compress, .decompress, .undo]
    var searchText = ""
    var kind: OperationRecord.Kind?
    var status = Status.all

    var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != nil || status != .all
    }

    func apply(to records: [OperationRecord]) -> [OperationRecord] {
        matchingKindAndSearch(records).filter(status.matches)
    }

    /// 在当前搜索词与操作类型下，各状态各有多少条；状态标签上的数字据此显示
    func statusCounts(in records: [OperationRecord]) -> [Status: Int] {
        let candidates = matchingKindAndSearch(records)
        var counts: [Status: Int] = [.all: candidates.count]
        for record in candidates {
            counts[Status(OperationHistoryPresentation.Outcome(record)), default: 0] += 1
        }
        return counts
    }

    private func matchingKindAndSearch(_ records: [OperationRecord]) -> [OperationRecord] {
        let terms = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
        return records.filter { record in
            guard kind == nil || record.kind == kind else { return false }
            guard !terms.isEmpty else { return true }
            var fields = [record.subject, OperationHistoryPresentation.actionTitle(record.kind),
                          record.kind.rawValue, OperationHistoryPresentation.status(record), record.failure ?? ""]
            if OperationHistoryPresentation.Outcome(record).needsAttention {
                fields.append(OperationHistoryPresentation.failureSummary(record))
            }
            for url in record.results + (record.location.map { [$0] } ?? []) {
                fields.append(url.path)
                fields.append(OperationHistoryPresentation.displayPath(url))
            }
            return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
        }
    }
}

/// 与其他设置页一致：弹窗以 sheet 挂在设置窗口上，找不到窗口时才退回模态。
/// 不在 SwiftUI 的按钮动作里直接 runModal，否则弹窗显示出来后按钮点不动
private func presentDialog(_ dialog: FRDialog, completion: @escaping (Int?) -> Void = { _ in }) {
    if let window = NSApp.keyWindow {
        dialog.beginSheet(for: window, completion: completion)
    } else {
        completion(dialog.runModal())
    }
}

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
            // 原说明（仅在项目中保留）：历史记录用于回看操作，不代表每条都能撤销。当前仍通过访达右键或 ⌘Z 撤销上一次操作。
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
            // 原说明（仅在项目中保留）：记录新建、剪切、粘贴、移动、复制、压缩解压和撤销的结果
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
            presentDialog(dialog) { choice in
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
        presentDialog(dialog) { if $0 == 0 { store.clear() } }
    }
}

/// 状态筛选标签：文字 + 数量，选中时用强调色底
private struct StatusFilterChip: View {
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

private struct OperationHistoryRow: View {
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
            presentDialog(FRDialog(title: NSLocalizedString("找不到结果文件", comment: "history"),
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
            presentDialog(FRDialog(title: NSLocalizedString("找不到这个文件夹", comment: "history"),
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
