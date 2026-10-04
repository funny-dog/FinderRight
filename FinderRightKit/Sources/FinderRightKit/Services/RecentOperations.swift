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

    public var succeeded: Bool { failure == nil }

    public init(kind: Kind, subject: String, failure: String? = nil, results: [URL] = [], date: Date = Date()) {
        self.kind = kind
        self.subject = subject
        self.failure = failure
        self.results = results
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
}

/// 最近的后台操作记录（仅内存，主 App 退出即清空）。
///
/// 压缩 / 解压 / 粘贴在 IPC 受理后异步执行，之前失败只写日志、用户无从得知。
/// 这里集中记录结果，菜单栏据此列出「最近操作」，并在有未查看的失败时提示。
/// 不走系统通知：避免任何通知权限弹窗。
public final class RecentOperations {

    public static let shared = RecentOperations()

    /// 记录变化后在主线程发出
    public static let didChangeNotification = Notification.Name("com.finderright.recentOperationsDidChange")

    public let capacity: Int

    private let lock = NSLock()
    private var storage: [OperationRecord] = []
    private var unseenFailures = 0

    public init(capacity: Int = 5) {
        self.capacity = max(1, capacity)
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
        storage.insert(record, at: 0)
        if storage.count > capacity { storage.removeLast(storage.count - capacity) }
        if !record.succeeded { unseenFailures += 1 }
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
