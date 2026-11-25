import Foundation
import CoreServices

/// 监视一组文件夹的直接子项增删改名（FSEvents，文件夹粒度），有变化时在指定队列上回调。
///
/// 只关心被监视的文件夹本身：子孙目录里的变化（比如在下载文件夹深处编译代码）FSEvents 也会报，
/// 这里按事件路径过滤掉，避免无谓的核对。带 WatchRoot：被监视的文件夹本身或它的上级
/// 被移走、删除时同样回调（比如把整个父文件夹拖进废纸篓）。
final class DirectoryWatcher {

    private let queue: DispatchQueue
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    /// 被监视的真实路径，交给 FSEvents
    private var directories: Set<String> = []
    /// 同一组路径的小写形式，用来比对事件路径（见 canonical）
    private var watched: Set<String> = []

    /// - onChange: 在 queue 上调用。FSEvents 自带 0.3 秒合并，连续变化只回调一次
    init(queue: DispatchQueue, onChange: @escaping () -> Void) {
        self.queue = queue
        self.onChange = onChange
    }

    /// 换成监视这组文件夹；集合没变时什么也不做。只能在 queue 上调用
    func watch(_ directories: Set<String>) {
        let normalized = Set(directories.map(Self.canonical))
        guard normalized != self.directories else { return }
        stop()
        self.directories = normalized
        watched = Set(normalized.map { $0.lowercased() })
        guard !normalized.isEmpty else { return }

        // 实例在主 App 生命周期内常驻（FinderRightService 的类型级属性），不需要 retain 回调上下文
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let eventFlags = Array(UnsafeBufferPointer(start: flags, count: count))
            watcher.handle(paths: eventPaths, flags: eventFlags)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, Array(normalized) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            NSLog("[DirectoryWatcher] 无法创建 FSEvents 监视：%d 个文件夹", normalized.count)
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    // MARK: - 私有

    private func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        // 事件丢失（需要重新扫描）或被监视路径本身变化时一律核对；其余只认被监视文件夹自身的事件
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped)
        let relevant = zip(paths, flags).contains { path, flag in
            flag & rescan != 0 || watched.contains(Self.canonical(path).lowercased())
        }
        // 不在回调里直接调用：onChange 可能换监视的文件夹，在流自己的回调里停掉并释放它不安全
        if relevant { queue.async(execute: onChange) }
    }

    /// FSEvents 报的是真实路径（/private/tmp 而非 /tmp）且文件夹事件带结尾斜杠；
    /// 两边都用 realpath 规范化，取不到（已不存在）时退回原样。比对时再转小写：默认卷不区分大小写，
    /// 在区分大小写的卷上最多多核对一次，不会漏
    static func canonical(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let resolved = realpath(trimmed, nil) else { return trimmed }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// FSEvents 子树变更事件（目录粒度）。
struct FSEventChange {
    /// 发生变化的规范路径（去除结尾斜杠）
    let path: String
    /// 需要将 path 及其所有子孙路径一并视为变更（如 MustScanSubDirs / RootChanged / Mount）
    let includesDescendants: Bool
    /// 内核或用户队列丢事件，调用方应全量失效
    let requiresFullReset: Bool
}

/// 递归监视一组目录树的文件系统事件（FSEvents，目录粒度）。
///
/// 与只关注直接子项的 `DirectoryWatcher` 不同，这里接收整个子树的变化并回传路径与标志，
/// 供磁盘占用缓存被动失效与详情弹窗变更提示复用。
final class SubtreeWatcher {

    private final class CallbackBox {
        weak var owner: SubtreeWatcher?
        init(_ owner: SubtreeWatcher) { self.owner = owner }
    }

    private let queue: DispatchQueue
    private let latency: CFTimeInterval
    private let onChanges: ([FSEventChange]) -> Void
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var directories: Set<String> = []

    init(
        queue: DispatchQueue,
        latency: CFTimeInterval = 0.5,
        onChanges: @escaping ([FSEventChange]) -> Void
    ) {
        self.queue = queue
        self.latency = latency
        self.onChanges = onChanges
    }

    deinit {
        let activeStream: FSEventStreamRef? = {
            lock.lock()
            defer { lock.unlock() }
            let s = stream
            stream = nil
            return s
        }()
        if let activeStream {
            queue.async {
                FSEventStreamStop(activeStream)
                FSEventStreamInvalidate(activeStream)
                FSEventStreamRelease(activeStream)
            }
        }
    }

    /// 切换监视的根目录集合；集合不变时什么也不做，空集合时停止流以保持零常驻开销。
    func watch(_ directories: Set<String>) {
        let normalized = Set(directories.map(DirectoryWatcher.canonical))
        queue.async { [weak self] in
            self?.applyWatch(normalized)
        }
    }

    /// 停止监视并释放底层 FSEvents 流。
    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    // MARK: - 私有（仅在 queue 上执行）

    private func applyWatch(_ normalized: Set<String>) {
        guard normalized != directories else { return }
        stopOnQueue()
        directories = normalized
        guard !normalized.isEmpty else { return }

        let box = CallbackBox(self)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { ptr in
                guard let ptr else { return nil }
                _ = Unmanaged<CallbackBox>.fromOpaque(ptr).retain()
                return ptr
            },
            release: { ptr in
                guard let ptr else { return }
                Unmanaged<CallbackBox>.fromOpaque(ptr).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = box.owner else { return }
            let eventPaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let eventFlags = Array(UnsafeBufferPointer(start: flags, count: count))
            watcher.handle(paths: eventPaths, flags: eventFlags)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            Array(normalized) as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            NSLog("[SubtreeWatcher] 无法创建 FSEvents 监视：%d 个文件夹", normalized.count)
            directories = []
            return
        }
        lock.lock()
        stream = created
        lock.unlock()
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    private func stopOnQueue() {
        directories = []
        let activeStream: FSEventStreamRef? = {
            lock.lock()
            defer { lock.unlock() }
            let s = stream
            stream = nil
            return s
        }()
        guard let activeStream else { return }
        FSEventStreamStop(activeStream)
        FSEventStreamInvalidate(activeStream)
        FSEventStreamRelease(activeStream)
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let ignoreMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagHistoryDone | kFSEventStreamEventFlagEventIdsWrapped
        )
        let fullResetMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagUserDropped
        )
        let subtreeMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagRootChanged
                | kFSEventStreamEventFlagMount
                | kFSEventStreamEventFlagUnmount
        )

        var changes: [FSEventChange] = []
        changes.reserveCapacity(paths.count)
        for (rawPath, flag) in zip(paths, flags) {
            if flag & ignoreMask != 0, flag & ~ignoreMask == 0 { continue }
            let fullReset = (flag & fullResetMask) != 0
            let includesDescendants = (flag & subtreeMask) != 0
            let normalized = DirectoryWatcher.canonical(rawPath)
            changes.append(FSEventChange(
                path: normalized,
                includesDescendants: includesDescendants,
                requiresFullReset: fullReset
            ))
        }
        guard !changes.isEmpty else { return }
        // 延后到下一次 queue 调度，避免回调内部同步停止或重建流导致重入
        queue.async { [weak self] in
            self?.onChanges(changes)
        }
    }
}
