import Foundation

/// 在途后台任务（压缩、解压、粘贴）的计数器，供 App 退出前等待其完成。
///
/// 没有它时，菜单「退出」、自动更新、切换语言重启都会直接腰斩进行中的任务：
/// 留下半成品文件，或让粘贴只完成一半。
public final class BackgroundJobs {

    private let group = DispatchGroup()
    private let lock = NSLock()
    private var running = 0
    private var open = true

    public init() {}

    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running == 0
    }

    /// 在 queue 上异步执行 work，并在其执行期间计为在途任务。
    ///
    /// 任务在关闭（`close()`）之后才被调度时直接丢弃：退出流程已经确认空闲并发出退出请求，
    /// 这时再接受新任务就会在任务进行中被系统终止。返回是否被接受。
    @discardableResult
    public func run(on queue: DispatchQueue, _ work: @escaping () -> Void) -> Bool {
        lock.lock()
        guard open else {
            lock.unlock()
            return false
        }
        running += 1
        group.enter()
        lock.unlock()
        queue.async {
            defer {
                self.lock.lock()
                self.running -= 1
                self.lock.unlock()
                self.group.leave()
            }
            work()
        }
        return true
    }

    /// 是否仍在受理新任务
    public var isAcceptingJobs: Bool {
        lock.lock()
        defer { lock.unlock() }
        return open
    }

    /// 关闭任务入口，不再受理新任务
    public func close() {
        lock.lock()
        open = false
        lock.unlock()
    }

    /// 关闭后再也不接受新任务，并等待全部在途任务结束；超时返回 false。
    ///
    /// 关闭与等待在同一个锁内完成，避免「检查空闲 → 系统退出」之间挤进新任务。
    public func closeAndWait(timeout: TimeInterval) -> Bool {
        close()
        return group.wait(timeout: .now() + timeout) == .success
    }

    /// 阻塞等待全部在途任务结束；超时返回 false
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }
}
