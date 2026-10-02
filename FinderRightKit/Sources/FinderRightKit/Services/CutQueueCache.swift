import Foundation

/// 剪切队列的只读缓存，供 FinderSync 扩展的角标回调热路径使用。
///
/// requestBadgeIdentifier 会为目录里每个可见文件各回调一次，每次都读盘解析 cut-queue.json，
/// 大目录下就是成千上万次重复 I/O。这里以文件的 inode + 大小 + 修改时间作为版本号：未变化时
/// 直接返回上次结果，只 stat 不读文件。CutQueueStore 总是原子替换写入，每次写都会产生新 inode，
/// 因此不会漏掉变化。
public final class CutQueueCache {

    private struct Version: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date
    }

    private let store: CutQueueStore
    private let lock = NSLock()
    private var hasLoaded = false
    private var version: Version?
    private var paths: Set<String> = []

    public init(store: CutQueueStore = CutQueueStore()) {
        self.store = store
    }

    /// 队列中全部源路径，已按 BadgeOwnershipProbe.normalize 规范化
    public func normalizedPaths() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let current = Self.version(of: store.queueURL)
        if hasLoaded && current == version {
            return paths
        }
        // 先 stat 后读：若读的瞬间文件又被替换，下次 stat 版本号不同会再读一次，不会长期停在旧内容
        paths = Set(store.read().map(BadgeOwnershipProbe.normalize))
        version = current
        hasLoaded = true
        return paths
    }

    /// 文件不存在时返回 nil
    private static func version(of url: URL) -> Version? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let modified = attrs[.modificationDate] as? Date else {
            return nil
        }
        return Version(inode: inode, size: size, modified: modified)
    }
}
