import Foundation

/// 串行请求的受理闸门：关闭入口后拒绝新请求，并为「已受理请求全部处理完」提供回调。
///
/// 关闭方不得同步等待排空：已受理的请求可能还要回到发起关闭的线程完成
/// （例如 IPC 请求处理中回主线程写剪贴板），「主线程等队列、队列等主线程」会死锁。
/// 这里只登记回调，等待由调用方异步进行。
public final class RequestDrainGate {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var closed = false

    /// - Parameter queue: 承载请求的串行队列
    public init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// 关闭入口并登记排空回调；回调在队列上执行一次，位于所有已受理请求之后。
    /// 受理与登记关闭共用同一把锁，保证回调不会插进「已通过检查但还没入队」的请求前面
    public func close(notifyDrained: @escaping () -> Void) {
        lock.lock()
        closed = true
        queue.async(execute: notifyDrained)
        lock.unlock()
    }

    /// 受理一个请求：入口关闭后返回 false；否则在队列上异步执行并返回 true
    @discardableResult
    public func accept(_ work: @escaping () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        queue.async(execute: work)
        return true
    }
}
