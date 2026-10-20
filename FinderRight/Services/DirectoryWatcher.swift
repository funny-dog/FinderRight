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
    private static func canonical(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let resolved = realpath(trimmed, nil) else { return trimmed }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
