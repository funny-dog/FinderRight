import Foundation

public enum OperationHistoryPresentation {
    private static func L(_ key: String) -> String { NSLocalizedString(key, comment: "operation history") }

    /// 一条记录的结果；状态文案、配色与筛选都从这里派生，避免多处各写一套判断
    public enum Outcome: CaseIterable {
        case completed, partial, failed, cancelled

        public init(_ record: OperationRecord) {
            if record.cancelled {
                self = .cancelled
            } else if record.failure == nil {
                self = .completed
            } else {
                self = record.results.isEmpty ? .failed : .partial
            }
        }

        public var titleKey: String {
            switch self {
            case .completed: return "已完成"
            case .partial: return "部分完成"
            case .failed: return "未完成"
            case .cancelled: return "已取消"
            }
        }

        public var needsAttention: Bool { self == .partial || self == .failed }
    }

    /// 同一天的记录，按时间倒序
    public struct DayGroup: Identifiable {
        public let day: Date
        public var records: [OperationRecord]
        public var id: Date { day }
    }

    public static func actionTitle(_ kind: OperationRecord.Kind) -> String {
        switch kind {
        case .createFile: return L("新建文件")
        case .cut: return L("剪切文件")
        case .compress: return L("压缩文件")
        case .decompress: return L("解压文件")
        case .paste: return L("粘贴文件")
        case .move: return L("移动文件")
        case .copy: return L("复制文件")
        case .undo: return L("撤销操作")
        case .symlink: return L("创建符号链接")
        }
    }

    public static func symbol(_ kind: OperationRecord.Kind) -> String {
        switch kind {
        case .createFile: return "doc.badge.plus"
        case .cut: return "scissors"
        case .compress: return "archivebox"
        case .decompress: return "shippingbox"
        case .paste: return "doc.on.clipboard"
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        case .undo: return "arrow.uturn.backward"
        case .symlink: return "link.badge.plus"
        }
    }

    public static func status(_ record: OperationRecord) -> String {
        L(Outcome(record).titleKey)
    }

    public static func transferSuccessMessage(_ record: OperationRecord) -> String? {
        guard record.succeeded, !record.results.isEmpty,
              record.kind == .move || record.kind == .copy else { return nil }
        let format = record.kind == .move ? L("已移动 %d 项到“%@”") : L("已复制 %d 项到“%@”")
        let folder = folder(record)?.lastPathComponent ?? ""
        return String(format: format, record.results.count, OperationRecord.truncatedSubject(folder))
    }

    public static func dayTitle(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return L("今天") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return L("昨天") }
        return date.formatted(.dateTime.year().month().day())
    }

    /// 一次遍历按天分组：组按日期倒序，组内保持传入顺序
    public static func dayGroups(_ records: [OperationRecord], calendar: Calendar = .current) -> [DayGroup] {
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
    public static func folder(_ record: OperationRecord) -> URL? {
        record.location ?? record.results.first?.deletingLastPathComponent()
    }

    public static func displayPath(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    public static func failureSummary(_ record: OperationRecord) -> String {
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

public struct OperationHistoryFilter {
    public enum Status: Hashable, CaseIterable {
        case all, completed, partial, failed, cancelled

        public init(_ outcome: OperationHistoryPresentation.Outcome) {
            switch outcome {
            case .completed: self = .completed
            case .partial: self = .partial
            case .failed: self = .failed
            case .cancelled: self = .cancelled
            }
        }

        public var titleKey: String {
            switch self {
            case .all: return "全部"
            case .completed: return "已完成"
            case .partial: return "部分完成"
            case .failed: return "未完成"
            case .cancelled: return "已取消"
            }
        }

        public func matches(_ record: OperationRecord) -> Bool {
            self == .all || self == Status(OperationHistoryPresentation.Outcome(record))
        }
    }

    public static let kinds: [OperationRecord.Kind] = [.createFile, .cut, .paste, .move, .copy, .symlink, .compress, .decompress, .undo]
    public var searchText = ""
    public var kind: OperationRecord.Kind?
    public var status = Status.all

    public init(searchText: String = "", kind: OperationRecord.Kind? = nil, status: Status = .all) {
        self.searchText = searchText
        self.kind = kind
        self.status = status
    }

    public var isActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind != nil || status != .all
    }

    public func apply(to records: [OperationRecord]) -> [OperationRecord] {
        matchingKindAndSearch(records).filter(status.matches)
    }

    /// 在当前搜索词与操作类型下，各状态各有多少条；状态标签上的数字据此显示
    public func statusCounts(in records: [OperationRecord]) -> [Status: Int] {
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

