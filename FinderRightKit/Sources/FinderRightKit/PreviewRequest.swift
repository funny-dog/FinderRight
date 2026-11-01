import Foundation

/// 每次预览独立取消；已排队的工作仍可运行，但不能再读取文件或重复交付结果。
public final class PreviewRequest {
    private let lock = NSLock()
    private var cancelled = false
    private var completion: ((Error?) -> Void)?

    public init(completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func checkCancellation() throws {
        if isCancelled { throw CocoaError(.userCancelled) }
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        finish(CocoaError(.userCancelled))
    }

    public func finish(_ error: Error? = nil) {
        lock.lock()
        let callback = completion
        completion = nil
        let result: Error? = cancelled ? CocoaError(.userCancelled) : error
        lock.unlock()
        if let callback { DispatchQueue.main.async { callback(result) } }
    }
}
