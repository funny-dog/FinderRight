import Foundation

/// 剪贴板历史最大记录条数预设
public enum ClipboardHistoryLimitPreset: Int, CaseIterable, Identifiable {
    case five = 5
    case ten = 10
    case fifteen = 15
    case twenty = 20

    public static let defaultLimit = 5

    public var id: Int { rawValue }

    public var titleKey: String {
        switch self {
        case .five: return "5 条"
        case .ten: return "10 条"
        case .fifteen: return "15 条"
        case .twenty: return "20 条"
        }
    }

    /// 规范化存储的条数配置，不在预设范围内时回退为默认 5 条
    public static func normalize(_ value: Int) -> Int {
        Self(rawValue: value)?.rawValue ?? defaultLimit
    }
}

/// 单条内存剪贴板历史记录
public struct ClipboardItem: Identifiable, Equatable {
    public enum Kind: Equatable {
        case text(String)
        case image(Data, pixelWidth: Int, pixelHeight: Int)
        case files([URL])
    }

    public let id: UUID
    public let kind: Kind
    public let copiedAt: Date

    public init(id: UUID = UUID(), kind: Kind, copiedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.copiedAt = copiedAt
    }

    /// 列表展示用的单行摘要文本（折叠连续空白并限制长度，避免超长文本拖慢排版）
    public var previewText: String {
        switch kind {
        case .text(let text):
            let prefix = String(text.prefix(512))
            let collapsed = prefix
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if collapsed.isEmpty {
                return text
            }
            return collapsed.count > 160 ? String(collapsed.prefix(160)) + "…" : collapsed
        case .image(_, let width, let height):
            return "\(width) × \(height)"
        case .files(let urls):
            guard let first = urls.first else { return "" }
            return first.lastPathComponent
        }
    }
}

/// 纯内存剪贴板历史存储（带容量上限与去重置顶）
public struct ClipboardHistoryStore: Equatable {
    public private(set) var items: [ClipboardItem] = []
    public private(set) var limit: Int

    public init(limit: Int = ClipboardHistoryLimitPreset.defaultLimit) {
        self.limit = ClipboardHistoryLimitPreset.normalize(limit)
    }

    /// 记录新内容：忽略空内容，若已存在相同内容则移至顶部，超出上限时淘汰最旧条目
    public mutating func record(_ kind: ClipboardItem.Kind, id: UUID = UUID(), now: Date = Date()) {
        switch kind {
        case .text(let string):
            guard !string.isEmpty else { return }
        case .image(let data, let width, let height):
            guard !data.isEmpty, width > 0, height > 0 else { return }
        case .files(let urls):
            guard !urls.isEmpty else { return }
        }

        items.removeAll { $0.kind == kind }
        items.insert(ClipboardItem(id: id, kind: kind, copiedAt: now), at: 0)
        trimToLimit()
    }

    public mutating func setLimit(_ newLimit: Int) {
        limit = ClipboardHistoryLimitPreset.normalize(newLimit)
        trimToLimit()
    }

    public mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    public mutating func clear() {
        items.removeAll()
    }

    private mutating func trimToLimit() {
        if items.count > limit {
            items.removeSubrange(limit...)
        }
    }
}
