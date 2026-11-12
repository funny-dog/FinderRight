import Foundation
import Darwin

/// 磁盘占用统计与展示（纯逻辑，可单测）。
///
/// 为什么不用 `FileManager.enumerator`：它每取一个文件的属性都要一次系统调用，
/// 实测 `~/Documents`（6 万文件）单线程约 360–470 ms；`getattrlistbulk` 一次调用
/// 批量返回一批目录项，配合 4 路并发可降到 ~140 ms，右键菜单才来得及同步显示。
///
/// 口径：用分配大小（`ATTR_FILE_ALLOCSIZE`）而不是逻辑大小，与访达「大小（磁盘上的）」
/// 一致——稀疏文件、压缩文件的实际占盘才是用户关心的数字。符号链接不跟随、不计数，
/// 与访达「显示简介」一致，避免链接环导致重复统计或无限递归。
public enum DiskUsage {

    /// 扫描并发度。实测 8 / 16 路反而更慢（APFS 元数据锁与 IO 争用），4 路最稳。
    public static let defaultConcurrency = 4

    // MARK: - 对外入口

    /// 计算文件或目录的磁盘占用（字节）。读不到、不是常规文件/目录、或统计过程中
    /// 出现无法判定完整性错误时返回 nil——调用方应显示「无法计算」而不是 0。
    ///
    /// - Parameters:
    ///   - url: 目标路径
    ///   - deadline: 超过该时刻立即放弃并返回 nil，保证调用方不会被大目录卡住
    ///   - isCancelled: 额外取消条件（例如菜单已关闭）
    public static func allocatedBytes(
        at url: URL,
        deadline: Date? = nil,
        concurrency: Int = defaultConcurrency,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Int64? {
        guard url.isFileURL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        if !isDir.boolValue {
            return regularFileAllocatedSize(atPath: url.path)
        }
        return directoryAllocatedBytes(
            at: url.path,
            deadline: deadline,
            concurrency: concurrency,
            isCancelled: isCancelled
        )
    }

    /// 菜单/提示里显示的大小文本（1.2 GB、459.2 MB……）。用十进制 + file 计数风格，与访达一致
    public static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 菜单目标解析

    /// 解析右键菜单中应展示磁盘占用的目标 URL。
    /// - 空白处（.container）：目标为当前所在目录。
    /// - 选中项（.items）：单选文件夹或常规文件时作为目标；多选或非文件/目录（包括符号链接）返回 nil。
    /// - 其他位置（.sidebar 等）：返回 nil。
    public static func target(
        location: MenuTargetLocation,
        selected: [URL],
        directory: URL?,
        isRegularDirectory: (URL) -> Bool = { url in
            var statInfo = stat()
            guard lstat(url.path, &statInfo) == 0 else { return false }
            return (statInfo.st_mode & S_IFMT) == S_IFDIR
        },
        isRegularFile: (URL) -> Bool = { url in
            var statInfo = stat()
            guard lstat(url.path, &statInfo) == 0 else { return false }
            return (statInfo.st_mode & S_IFMT) == S_IFREG
        }
    ) -> URL? {
        switch location {
        case .container:
            guard let directory, isRegularDirectory(directory) else { return nil }
            return directory
        case .items:
            guard selected.count == 1, let url = selected.first else { return nil }
            if isRegularDirectory(url) { return url }
            if isRegularFile(url) { return url }
            return nil
        case .sidebar:
            return nil
        }
    }

    // MARK: - 目录直属项占用分析

    /// 扫描目录的直接子项占用并降序排列。
    /// - 符号链接不跟随、不进入；
    /// - 用户取消时立即中止并返回 nil；
    /// - 个别子目录若无权限读取则安全跳过，不让单项权限阻断整体统计；
    /// - 仅统计真实目录与常规文件，过滤套接字、管道等特殊文件。
    public static func inspectDirectChildren(
        at directoryURL: URL,
        deadline: Date? = nil,
        isCancelled: @escaping () -> Bool = { false }
    ) -> DiskUsageBreakdown? {
        guard directoryURL.isFileURL else { return nil }

        // 验证根路径是真实目录且不跟随符号链接
        var statInfo = stat()
        guard lstat(directoryURL.path, &statInfo) == 0,
              (statInfo.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }

        func shouldStop() -> Bool {
            if isCancelled() { return true }
            if let deadline, Date() >= deadline { return true }
            return false
        }

        if shouldStop() { return nil }

        guard let entries = try? BulkDirectoryAttributes.entries(atPath: directoryURL.path) else {
            return nil
        }

        var dirCount = 0
        var fileCount = 0
        var rawItems: [(name: String, path: String, isDirectory: Bool, bytes: Int64)] = []

        for entry in entries {
            if shouldStop() {
                // 如果是用户主动取消或全局超时，整份退出
                return nil
            }
            let itemPath = (directoryURL.path as NSString).appendingPathComponent(entry.name)
            if entry.isDirectory {
                dirCount += 1
                let subURL = URL(fileURLWithPath: itemPath)
                if let bytes = allocatedBytes(at: subURL, deadline: deadline, isCancelled: shouldStop) {
                    rawItems.append((name: entry.name, path: itemPath, isDirectory: true, bytes: bytes))
                }
            } else if entry.isRegularFile {
                fileCount += 1
                rawItems.append((name: entry.name, path: itemPath, isDirectory: false, bytes: entry.allocatedSize))
            }
            // 忽略符号链接、套接字、管道等非目录且非普通文件的子项
        }

        if isCancelled() { return nil }

        rawItems.sort { $0.bytes > $1.bytes }

        let totalBytes = rawItems.reduce(0) { $0 + $1.bytes }
        let items = rawItems.map { raw in
            DiskUsageItem(
                name: raw.name,
                path: raw.path,
                isDirectory: raw.isDirectory,
                bytes: raw.bytes,
                totalBytes: totalBytes
            )
        }

        return DiskUsageBreakdown(
            directoryURL: directoryURL,
            totalBytes: totalBytes,
            items: items,
            directDirectoryCount: dirCount,
            directFileCount: fileCount
        )
    }

    // MARK: - 单文件

    /// 普通文件的分配大小。符号链接、目录、读不到时返回 nil
    static func regularFileAllocatedSize(atPath path: String) -> Int64?  {
        var info = stat()
        // lstat：链接本身按其自身大小计，不跟随到目标
        guard lstat(path, &info) == 0 else { return nil }
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        return Int64(info.st_blocks) * 512
    }

    // MARK: - 目录

    static func directoryAllocatedBytes(
        at rootPath: String,
        deadline: Date?,
        concurrency: Int,
        isCancelled: @escaping () -> Bool
    ) -> Int64? {
        // 顶层子目录分片给并发线程；根目录自身这一层在当前线程处理
        guard let subdirs = immediateSubdirectories(of: rootPath) else { return nil }

        let lock = NSLock()
        var total: Int64 = 0
        var failed = false
        var cancelled = false
        var timedOut = false

        func record(cancelledNow: Bool, failedNow: Bool, timedOutNow: Bool) {
            lock.lock()
            deferred: do {
                if cancelledNow { cancelled = true }
                if failedNow { failed = true }
                if timedOutNow { timedOut = true }
            }
            lock.unlock()
        }

        /// 每个工作线程的停止条件：菜单关闭、超时、或已有分片失败/取消
        func shouldStop() -> Bool {
            if isCancelled() { return true }
            if let deadline, Date() >= deadline { return true }
            lock.lock()
            let stop = cancelled || timedOut || failed
            lock.unlock()
            return stop
        }

        let group = DispatchGroup()
        let semaphore = DispatchSemaphore(value: max(1, concurrency))

        for sub in subdirs {
            if shouldStop() { break }
            group.enter()
            semaphore.wait()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { semaphore.signal(); group.leave() }
                var acc: Int64 = 0
                let outcome = accumulate(path: sub, into: &acc, shouldStop: shouldStop)
                if outcome == .stopped { record(cancelledNow: true, failedNow: false, timedOutNow: false); return }
                if outcome == .failed { record(cancelledNow: false, failedNow: true, timedOutNow: false); return }
                lock.lock()
                let (sum, overflow) = total.addingReportingOverflow(acc)
                if overflow { failed = true } else { total = sum }
                lock.unlock()
            }
        }

        // 根目录这一层（含根下的普通文件）
        if !shouldStop() {
            var acc: Int64 = 0
            let outcome = accumulate(path: rootPath, into: &acc, shouldStop: shouldStop, descend: false)
            if outcome == .stopped { record(cancelledNow: true, failedNow: false, timedOutNow: false) }
            if outcome == .failed { record(cancelledNow: false, failedNow: true, timedOutNow: false) }
            lock.lock()
            let (sum, overflow) = total.addingReportingOverflow(acc)
            if overflow { failed = true } else { total = sum }
            lock.unlock()
        }

        group.wait()

        lock.lock()
        let wasCancelled = cancelled, wasFailed = failed, wasTimedOut = timedOut
        lock.unlock()

        if wasCancelled || wasFailed || wasTimedOut { return nil }
        if let deadline, Date() >= deadline { return nil }
        if isCancelled() { return nil }
        return total
    }

    /// 根目录下的直接子目录（不递归）。读不到根目录时返回 nil
    static func immediateSubdirectories(of path: String) -> [String]? {
        var result: [String] = []
        guard let entries = try? BulkDirectoryAttributes.entries(atPath: path) else { return nil }
        for entry in entries where entry.isDirectory {
            result.append(path + "/" + entry.name)
        }
        return result
    }

    enum AccumulateOutcome { case ok, stopped, failed }

    /// 递归累加 `path` 下的普通文件分配大小。
    ///
    /// - Parameter descend: false 时只看该目录这一层的文件，子目录交给并发分片处理
    static func accumulate(
        path: String,
        into total: inout Int64,
        shouldStop: @escaping () -> Bool,
        descend: Bool = true
    ) -> AccumulateOutcome {
        var stack = [path]
        while let dir = stack.popLast() {
            if shouldStop() { return .stopped }
            guard let entries = try? BulkDirectoryAttributes.entries(atPath: dir) else {
                // 单个子目录读不到（权限、已删除）不应让整棵树失败：访达同样会跳过
                if dir == path { return .failed }
                continue
            }
            for entry in entries {
                if entry.isDirectory {
                    if descend { stack.append(dir + "/" + entry.name) }
                } else if entry.isRegularFile {
                    let (sum, overflow) = total.addingReportingOverflow(entry.allocatedSize)
                    if overflow { return .failed }
                    total = sum
                }
            }
        }
        return .ok
    }
}

// MARK: - getattrlistbulk 批量读取目录项

/// 用 `getattrlistbulk` 一次系统调用读回整批目录项的名称、类型与分配大小。
///
/// 相比 `FileManager.enumerator`（每项一次 stat），这是目录大小统计能进到百毫秒级的关键。
enum BulkDirectoryAttributes {

    struct Entry {
        let name: String
        /// 分配大小（磁盘实际占用）。目录项为 0
        let allocatedSize: Int64
        let isDirectory: Bool
        let isRegularFile: Bool
    }

    enum BulkError: Error {
        case openFailed(errno: Int32)
        case notDirectory
    }

    /// 读取目录的直接子项（不含 . 与 ..）
    static func entries(atPath path: String) throws -> [Entry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw BulkError.openFailed(errno: errno) }
        defer { close(fd) }

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE)
        attrList.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)

        // 256 KiB 一批：经验值，再大对小目录是浪费，再小会多几次调用
        let bufferSize = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var result: [Entry] = []
        while true {
            let count = withUnsafeMutablePointer(to: &attrList) { listPtr in
                getattrlistbulk(fd, listPtr, buffer, bufferSize, 0)
            }
            if count == 0 { break }              // 读完
            if count < 0 {
                if errno == EINTR { continue }
                throw BulkError.openFailed(errno: errno)
            }
            var cursor = buffer
            for _ in 0..<count {
                // 缓冲区不保证 4/8 字节对齐，必须用 loadUnaligned，否则 arm64 上直接崩溃
                let entryLength = Int(cursor.loadUnaligned(as: UInt32.self))
                guard entryLength > 0 else { break }
                var field = cursor.advanced(by: MemoryLayout<UInt32>.size)
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field = field.advanced(by: MemoryLayout<attribute_set_t>.size)

                var name = ""
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let reference = field.loadUnaligned(as: attrreference_t.self)
                    let namePtr = field.advanced(by: Int(reference.attr_dataoffset))
                        .assumingMemoryBound(to: CChar.self)
                    name = String(cString: namePtr)
                    field = field.advanced(by: MemoryLayout<attrreference_t>.size)
                }

                var objectType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field = field.advanced(by: MemoryLayout<fsobj_type_t>.size)
                }

                var allocated: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    allocated = Int64(field.loadUnaligned(as: off_t.self))
                    field = field.advanced(by: MemoryLayout<off_t>.size)
                }

                if !name.isEmpty, name != ".", name != ".." {
                    result.append(Entry(
                        name: name,
                        allocatedSize: allocated,
                        isDirectory: objectType == UInt32(VDIR.rawValue),
                        isRegularFile: objectType == UInt32(VREG.rawValue)
                    ))
                }
                cursor = cursor.advanced(by: entryLength)
            }
        }
        return result
    }
}

// MARK: - 结果缓存

/// 目录占用结果的进程内缓存（带有效期）。
///
/// 大目录扫一次要几秒，而用户常会「关掉菜单、又点开」：命中缓存就能立刻给出数字。
/// 有效期不宜长——文件随时在变，过期的数字比没有数字更误导。
public final class DiskUsageCache {

    private struct Item {
        let bytes: Int64
        let storedAt: Date
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private let capacity: Int

    public init(capacity: Int = 128) {
        self.capacity = max(1, capacity)
    }

    public func value(for path: String, ttl: TimeInterval, now: Date = Date()) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard let item = items[path] else { return nil }
        if now.timeIntervalSince(item.storedAt) > ttl {
            items.removeValue(forKey: path)
            return nil
        }
        return item.bytes
    }

    public func store(_ bytes: Int64, for path: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if items.count >= capacity, items[path] == nil {
            // 容量满：丢掉最早写入的一项，避免无限增长
            if let oldest = items.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
                items.removeValue(forKey: oldest)
            }
        }
        items[path] = Item(bytes: bytes, storedAt: now)
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
    }
}

// MARK: - 在途任务

/// 一次目录占用计算任务：同一路径同时只有一个在算，调用方可以只等一小会儿就放弃，
/// 而任务本身继续跑完并写入缓存。
///
/// 为什么需要它：大目录（几十万文件）要算几秒，而右键菜单只能等 250 ms。若任务随调用方一起
/// 放弃，就永远算不出结果、缓存也永远建不起来——表现为「大目录永远不显示大小」。这里让任务
/// 独立于等待方存活：第一次请求超时返回，后台算完后写入缓存，下一次右键立刻命中。
public final class DiskUsageJob {

    /// 同一路径的在途任务：所有等待者各自持有信号量，任务完成时全部唤醒
    private final class Task {
        var waiters: [DispatchSemaphore] = []
    }

    private static let lock = NSLock()
    private static var inFlight: [String: Task] = [:]

    /// 执行（或复用）一次计算。返回 nil 表示在 waitTimeout 内没能拿到结果。
    ///
    /// - Parameters:
    ///   - url: 要统计的路径
    ///   - path: 归一化后的缓存键
    ///   - scanDeadline: 任务自身的计算截止时间
    ///   - waitTimeout: 调用方愿意等待的时间
    public static func run(
        url: URL,
        path: String,
        scanDeadline: Date?,
        waitTimeout: TimeInterval,
        cache: DiskUsageCache,
        cacheTTL: TimeInterval,
        queue: DispatchQueue = .global(qos: .userInitiated)
    ) -> Int64? {
        if let cached = cache.value(for: path, ttl: cacheTTL) { return cached }

        let mySignal = DispatchSemaphore(value: 0)
        var isNewTask = false

        lock.lock()
        if let existing = inFlight[path] {
            // 已有同一路径的任务在算：登记为等待者，避免重复扫盘
            existing.waiters.append(mySignal)
        } else {
            let task = Task()
            task.waiters.append(mySignal)
            inFlight[path] = task
            isNewTask = true
        }
        lock.unlock()

        if isNewTask {
            queue.async {
                let bytes = DiskUsage.allocatedBytes(at: url, deadline: scanDeadline)
                if let bytes { cache.store(bytes, for: path) }
                // 先摘掉在途登记，再唤醒全部等待者：唤醒后它们直接读缓存
                lock.lock()
                let waiters = inFlight.removeValue(forKey: path)?.waiters ?? []
                lock.unlock()
                for waiter in waiters { waiter.signal() }
            }
        }

        if mySignal.wait(timeout: .now() + waitTimeout) != .success {
            // 超时离开：把自己从等待者里摘掉，任务本身继续跑完并写缓存
            lock.lock()
            inFlight[path]?.waiters.removeAll { $0 === mySignal }
            lock.unlock()
            return cache.value(for: path, ttl: cacheTTL)
        }
        return cache.value(for: path, ttl: cacheTTL)
    }

    /// 仅供测试：清空在途状态
    public static func resetForTesting() {
        lock.lock()
        inFlight.removeAll()
        lock.unlock()
    }
}

// MARK: - 占用详情数据模型

public struct DiskUsageItem: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let bytes: Int64
    public let formattedSize: String
    public let percentage: Double

    public init(name: String, path: String, isDirectory: Bool, bytes: Int64, totalBytes: Int64) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.formattedSize = DiskUsage.formatted(bytes)
        self.percentage = totalBytes > 0 ? min(1.0, max(0.0, Double(bytes) / Double(totalBytes))) : 0.0
    }
}

public struct DiskUsageBreakdown: Equatable {
    public let directoryURL: URL
    public let totalBytes: Int64
    public let formattedTotalSize: String
    public let items: [DiskUsageItem]
    public let directDirectoryCount: Int
    public let directFileCount: Int

    public init(
        directoryURL: URL,
        totalBytes: Int64,
        items: [DiskUsageItem],
        directDirectoryCount: Int,
        directFileCount: Int
    ) {
        self.directoryURL = directoryURL
        self.totalBytes = totalBytes
        self.formattedTotalSize = DiskUsage.formatted(totalBytes)
        self.items = items
        self.directDirectoryCount = directDirectoryCount
        self.directFileCount = directFileCount
    }
}
