import Foundation
import FinderRightKit

@main
struct PreviewRequestChecks {
    static func main() throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(condition(), "预览取消回调超时")
        }
        var callbacks = 0
        let request = PreviewRequest { error in
            precondition(Thread.isMainThread)
            precondition((error as? CocoaError)?.code == .userCancelled)
            callbacks += 1
        }
        let queue = DispatchQueue(label: "test.preview.request")
        let gate = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); gate.wait() }
        entered.wait()
        queue.async {
            defer { finished.signal() }
            do {
                try request.checkCancellation()
                preconditionFailure("过期请求不得进入读取阶段")
            } catch {
                precondition((error as? CocoaError)?.code == .userCancelled)
                request.finish(error)
            }
        }
        request.cancel()
        request.cancel()
        wait { callbacks == 1 }
        gate.signal()
        precondition(finished.wait(timeout: .now() + 3) == .success)
        request.finish()
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        precondition(callbacks == 1)

        let running = PreviewRequest { error in
            precondition(Thread.isMainThread && (error as? CocoaError)?.code == .userCancelled)
            callbacks += 1
        }
        queue.async {
            defer { finished.signal() }
            do {
                try running.checkCancellation()
                entered.signal()
                gate.wait()
                try running.checkCancellation()
                preconditionFailure("在途任务应在下一个检查点停止")
            } catch { running.finish(error) }
        }
        entered.wait()
        running.cancel()
        gate.signal()
        precondition(finished.wait(timeout: .now() + 3) == .success)
        wait { callbacks == 2 }

        var success = 0
        let complete = PreviewRequest { error in precondition(error == nil); success += 1 }
        complete.finish()
        complete.finish(CocoaError(.fileReadUnknown))
        complete.cancel()
        wait { success == 1 }

        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for read in [
            { _ = try PreviewContents.folder(missing, isCancelled: { request.isCancelled }) },
            { _ = try PreviewContents.zip(missing, isCancelled: { request.isCancelled }) },
            { _ = try PreviewArchive.read(missing, request: request) },
            { _ = try PreviewDocument.read(missing, request: request) },
            { _ = try PreviewDocument.readMarkdown(missing, request: request) },
            { _ = try PreviewDatabase.read(missing, request: request) }
        ] {
            do { try read(); preconditionFailure("应先取消，不能读取不存在的文件") }
            catch { precondition((error as? CocoaError)?.code == .userCancelled) }
        }
        print("✓ 预览取消：排队任务跳过读取、在途检查点、主线程恰好一次回调、读取入口先检查取消")
    }
}
