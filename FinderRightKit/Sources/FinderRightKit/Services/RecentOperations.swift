import Foundation

/// 一次后台操作（压缩 / 解压 / 粘贴）的结果。
public struct OperationRecord: Equatable {

    public enum Kind: String {
        case compress, decompress, paste, move, copy
    }

    public let kind: Kind
    /// 操作对象的显示名（文件名或「N 个项目」）
    public let subject: String
    /// 失败原因；nil 表示成功
    public let failure: String?
    /// 成功时产出的文件，供「在访达中显示」
    public let results: [URL]
    public let date: Date
    /// 用户主动取消（如加密包的密码框点了「取消」）：既不算成功，也不算需要提醒的失败
    public let cancelled: Bool

    public var succeeded: Bool { failure == nil && !cancelled }

    public init(kind: Kind, subject: String, failure: String? = nil, results: [URL] = [],
                cancelled: Bool = false, date: Date = Date()) {
        self.kind = kind
        self.subject = subject
        self.failure = failure
        self.results = results
        self.cancelled = cancelled
        self.date = date
    }

    /// 把子进程 stderr 这类长文本压成适合菜单与对话框显示的摘要：
    /// 取前几行非空内容，超长截断。全空时返回 nil，由调用方换用退出码等兜底文案。
    public static func summary(of text: String, maxLines: Int = 3, maxLength: Int = 300) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        var joined = lines.prefix(maxLines).joined(separator: "\n")
        if joined.count > maxLength {
            joined = String(joined.prefix(maxLength)) + "…"
        } else if lines.count > maxLines {
            joined += "\n…"
        }
        return joined
    }

    /// 菜单里显示的操作对象名：过长时从中间截断，保留开头与结尾（含扩展名）。
    /// 菜单宽度由最长一项决定，长文件名会把整个菜单撑宽，完整名称由调用方放进 toolTip。
    /// 宽度按显示宽度计：中日韩等全角字符算 2，其余算 1。
    public static func truncatedSubject(_ subject: String, maxWidth: Int = 32) -> String {
        let chars = Array(subject)
        let widths = chars.map(displayWidth)
        guard widths.reduce(0, +) > maxWidth else { return subject }

        // 省略号占 1，剩余宽度前多后少地分给开头和结尾
        let budget = max(2, maxWidth - 1)
        let tailBudget = budget * 2 / 5
        let headBudget = budget - tailBudget

        var head = 0, used = 0
        while head < chars.count, used + widths[head] <= headBudget {
            used += widths[head]; head += 1
        }
        var tail = chars.count, tailUsed = 0
        while tail > head, tailUsed + widths[tail - 1] <= tailBudget {
            tailUsed += widths[tail - 1]; tail -= 1
        }
        return String(chars[..<head]) + "…" + String(chars[tail...])
    }

    /// 粗略的显示宽度：U+2E80 之后（中日韩部首、假名、汉字、谚文、全角符号、emoji）按全角算
    private static func displayWidth(_ char: Character) -> Int {
        (char.unicodeScalars.first?.value ?? 0) >= 0x2E80 ? 2 : 1
    }
}

/// 最近的后台操作记录（仅内存，主 App 退出即清空）。
///
/// 压缩 / 解压 / 粘贴在 IPC 受理后异步执行，之前失败只写日志、用户无从得知。
/// 这里集中记录结果，菜单栏据此列出「最近操作」，并在有未查看的失败时提示。
/// 不走系统通知：避免任何通知权限弹窗。
/// 该功能为可选项，默认关闭；关闭时不记录任何结果。
public final class RecentOperations {

    /// 默认关闭，由主 App 启动时按用户设置开启
    public static let shared = RecentOperations(isEnabled: false)

    /// 记录变化后在主线程发出
    public static let didChangeNotification = Notification.Name("com.finderright.recentOperationsDidChange")

    public let capacity: Int

    private let lock = NSLock()
    private var storage: [OperationRecord] = []
    private var unseenFailures = 0
    private var enabled: Bool

    public init(capacity: Int = 5, isEnabled: Bool = true) {
        self.capacity = max(1, capacity)
        self.enabled = isEnabled
    }

    /// 关闭后丢弃已有记录与失败提示，此后的 record 调用直接忽略
    public var isEnabled: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            let changed = enabled != newValue
            enabled = newValue
            let hadContent = !storage.isEmpty || unseenFailures != 0
            if !newValue {
                storage.removeAll()
                unseenFailures = 0
            }
            lock.unlock()
            if changed && hadContent { notifyChange() }
        }
    }

    /// 最新的在前
    public var records: [OperationRecord] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// 上次查看之后新增的失败数
    public var unseenFailureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return unseenFailures
    }

    /// 可在任意线程调用
    public func record(_ record: OperationRecord) {
        lock.lock()
        guard enabled else { lock.unlock(); return }
        storage.insert(record, at: 0)
        if storage.count > capacity { storage.removeLast(storage.count - capacity) }
        if !record.succeeded && !record.cancelled { unseenFailures += 1 }
        lock.unlock()
        notifyChange()
    }

    public func markFailuresSeen() {
        lock.lock()
        let changed = unseenFailures != 0
        unseenFailures = 0
        lock.unlock()
        if changed { notifyChange() }
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        unseenFailures = 0
        lock.unlock()
        notifyChange()
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}
