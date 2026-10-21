import Foundation

/// 一次后台操作（压缩 / 解压 / 粘贴等）的结果。
public struct OperationRecord: Codable, Identifiable, Equatable {

    public enum Kind: String, Codable {
        case compress, decompress, paste, move, copy, undo, createFile, cut
    }

    public let id: UUID
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
    /// 用户操作所在文件夹，可用于失败记录
    public let location: URL?

    public var succeeded: Bool { failure == nil && !cancelled }

    public init(id: UUID = UUID(), kind: Kind, subject: String, failure: String? = nil, results: [URL] = [],
                cancelled: Bool = false, date: Date = Date(), location: URL? = nil) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.failure = failure
        self.results = results
        self.cancelled = cancelled
        self.date = date
        self.location = location
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

/// 最近的后台操作记录（可持久化到本地用户历史）。
public final class RecentOperations {

    public static let capacityKey = "operationHistoryLimit"

    /// 记录变化后在主线程发出
    public static let didChangeNotification = Notification.Name("com.finderright.recentOperationsDidChange")

    /// 每次记录完成（无论是否保留历史）在主线程发出，object 为 OperationRecord
    public static let didFinishNotification = Notification.Name("com.finderright.recentOperationsDidFinish")

    /// 默认本地持久化到用户 Application Support/FinderRight/operation-history.json
    public static let shared: RecentOperations = {
        let rawLimit = UserDefaults.standard.object(forKey: capacityKey) as? Int
        let cap = min(500, max(0, rawLimit ?? 100))
        let defaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FinderRight", isDirectory: true)
            .appendingPathComponent("operation-history.json", isDirectory: false)
        return RecentOperations(capacity: cap, storageURL: defaultURL)
    }()

    public var capacity: Int {
        lock.lock()
        defer { lock.unlock() }
        return _capacity
    }

    public var persistenceError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _persistenceError
    }

    private let storageURL: URL?
    private let lock = NSLock()
    private var _capacity: Int
    private var storage: [OperationRecord] = []
    private var _persistenceError: String?
    /// 磁盘上的历史文件没能完整读出、也没能留底：此时写入会抹掉读不出的记录，暂停保存，直到用户清空历史
    private var writeBlocked = false

    public init(capacity: Int = 100, storageURL: URL? = nil) {
        let validCapacity = min(500, max(0, capacity))
        self._capacity = validCapacity
        self.storageURL = storageURL
        self._persistenceError = nil

        guard let storageURL = storageURL else { return }

        guard validCapacity > 0 else {
            if FileManager.default.fileExists(atPath: storageURL.path) {
                do {
                    try FileManager.default.removeItem(at: storageURL)
                } catch {
                    self._persistenceError = error.localizedDescription
                }
            }
            return
        }

        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let data = try Data(contentsOf: storageURL)
                // 逐条解码：单条认不出（如降级后遇到新版本才有的操作类型）只跳过这一条
                let entries = try JSONDecoder().decode([LossyRecord].self, from: data)
                var loaded = entries.compactMap(\.record)
                if loaded.count < entries.count {
                    preserveUnreadableFile(at: storageURL)
                }
                loaded.sort { $0.date > $1.date }
                if loaded.count > validCapacity {
                    loaded = Array(loaded.prefix(validCapacity))
                }
                self.storage = loaded
            } catch {
                self.storage = []
                preserveUnreadableFile(at: storageURL)
                if !writeBlocked {
                    self._persistenceError = error.localizedDescription
                }
            }
        }
    }

    /// 读不出的历史文件在被新记录覆盖前，先复制一份到同目录的 `<名称>.unreadable.<扩展名>`（只保留最近一份）。
    /// 留底失败则暂停保存，宁可这次运行的新记录只在内存里，也不抹掉原文件。
    private func preserveUnreadableFile(at url: URL) {
        let backup = Self.unreadableBackupURL(for: url)
        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: url, to: backup)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        } catch {
            writeBlocked = true
            _persistenceError = error.localizedDescription
        }
    }

    static func unreadableBackupURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        return url.deletingLastPathComponent().appendingPathComponent(name + ".unreadable" + ext, isDirectory: false)
    }

    public func setCapacity(_ newCapacity: Int) {
        let target = min(500, max(0, newCapacity))
        lock.lock()
        guard _capacity != target else { lock.unlock(); return }
        _capacity = target
        if target == 0 {
            storage.removeAll()
            removeStorageFileLocked()
        } else {
            if storage.count > target { storage.removeLast(storage.count - target) }
            saveToDiskLocked()
        }
        lock.unlock()
        notifyChange()
    }

    /// 最新的在前
    public var records: [OperationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// 可在任意线程调用
    public func record(_ record: OperationRecord) {
        var shouldNotifyChange = false

        lock.lock()
        if _capacity > 0 {
            storage.append(record)
            storage.sort { $0.date > $1.date }
            if storage.count > _capacity {
                storage.removeLast(storage.count - _capacity)
            }
            saveToDiskLocked()
            shouldNotifyChange = true
        }
        lock.unlock()

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didFinishNotification, object: record)
            if shouldNotifyChange {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
        }
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        removeStorageFileLocked()
        lock.unlock()

        notifyChange()
    }

    /// 用户主动清空或关闭历史：读不出的旧文件也一并删除，之后恢复正常保存
    private func removeStorageFileLocked() {
        guard let url = storageURL, FileManager.default.fileExists(atPath: url.path) else {
            writeBlocked = false
            _persistenceError = nil
            return
        }
        do {
            try FileManager.default.removeItem(at: url)
            writeBlocked = false
            _persistenceError = nil
        } catch {
            _persistenceError = error.localizedDescription
        }
    }

    private func saveToDiskLocked() {
        guard let url = storageURL else { return }
        guard !writeBlocked else {
            _persistenceError = _persistenceError ?? "history file is unreadable and could not be backed up"
            return
        }
        do {
            let folder = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let encoder = JSONEncoder()
            let data = try encoder.encode(storage)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            _persistenceError = nil
        } catch {
            _persistenceError = error.localizedDescription
        }
    }

    private func notifyChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }
}

/// 解码失败时得到 nil 而不是抛错，让数组里的其他记录照常读出
private struct LossyRecord: Decodable {
    let record: OperationRecord?

    init(from decoder: Decoder) throws {
        record = try? OperationRecord(from: decoder)
    }
}
