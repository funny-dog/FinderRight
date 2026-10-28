import Foundation
import FinderRightKit

@main
struct CutQueueRemovalChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CutQueueStore(directory: directory)
        try store.write(["/a", "/b"])
        let remaining = try store.remove("/a")
        precondition(remaining == ["/b"] && store.read() == ["/b"])
        print("✓ 移除单项保留其余队列及顺序")
        try store.remove("/b")
        precondition(store.read().isEmpty && !FileManager.default.fileExists(atPath: store.queueURL.path))
        print("✓ 移除最后一项清空剪切状态")
        try store.write(["/a"])
        let batch = try store.take()!
        try store.write(["/b"])
        do {
            try store.remove("/b")
            preconditionFailure("粘贴在途时必须拒绝移除")
        } catch CutQueueStore.RemovalError.pasteInProgress {}
        precondition(store.read() == ["/b"])
        try store.finish(batch.id, retrying: batch.paths)
        precondition(store.read() == ["/b", "/a"])
        print("✓ 粘贴在途拒绝移除，失败路径仍可恢复")
        try store.remove("/a")
        try store.remove("/missing")
        precondition(store.read() == ["/b"])
        print("✓ 粘贴结算后允许移除，过期菜单路径不影响其余项目")
    }
}
