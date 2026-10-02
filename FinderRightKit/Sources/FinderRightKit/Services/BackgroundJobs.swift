import Foundation

/// 在途后台任务（压缩、解压、粘贴）的计数器，供 App 退出前等待其完成。
///
/// 没有它时，菜单「退出」、自动更新、切换语言重启都会直接腰斩进行中的任务：
/// 留下半成品文件，或让粘贴只完成一半。
public final class BackgroundJobs {

    private let group = DispatchGroup()
    private let lock = NSLock()
    private var running = 0

    public init() {}

    public var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running == 0
    }

    /// 在 queue 上异步执行 work，并在其执行期间计为在途任务
    public func run(on queue: DispatchQueue, _ work: @escaping () -> Void) {
        lock.lock()
        running += 1
        lock.unlock()
        group.enter()
        queue.async {
            defer {
                self.lock.lock()
                self.running -= 1
                self.lock.unlock()
                self.group.leave()
            }
            work()
        }
    }

    /// 阻塞等待全部在途任务结束；超时返回 false
    @discardableResult
    public func waitUntilIdle(timeout: TimeInterval) -> Bool {
        group.wait(timeout: .now() + timeout) == .success
    }
}
