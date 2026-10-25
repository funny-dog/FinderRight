import AppKit
import FinderRightKit

/// 不开窗口：验证目录检查与图标读取不占主线程，慢目录不阻塞其他项目。
@main
struct FavoriteDirectoryStatusChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finderright-favorites-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("folder.replaced")
        try Data().write(to: file)
        let missing = root.appendingPathComponent("missing")
        precondition(FavoriteDirectoryAvailability.isAvailable(root.path) == true)
        precondition(FavoriteDirectoryAvailability.isAvailable(file.path) == false)
        precondition(FavoriteDirectoryAvailability.isAvailable(missing.path) == false)

        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let lock = NSLock()
        var slowCalls = 0
        let status = FavoriteDirectoryStatus(check: { path in
            precondition(!Thread.isMainThread, "目录检查必须在后台执行")
            if path == "slow" {
                lock.lock()
                slowCalls += 1
                lock.unlock()
                precondition(release.wait(timeout: .now() + 5) == .success)
                return true
            }
            if path == "unknown" { return nil }
            return FavoriteDirectoryAvailability.isAvailable(path)
        }, icon: { path in
            precondition(!Thread.isMainThread, "目录图标必须在后台读取")
            precondition(path == root.path || path == file.path || path == "slow", "无效或状态不明的路径不应读取图标")
            return NSImage(size: NSSize(width: 16, height: 16))
        })
        let paths = [root.path, file.path, missing.path, "unknown", "slow"]
        status.refresh(paths)
        precondition(status.entries.isEmpty, "刷新不能同步等待 I/O")
        wait {
            status.entries[root.path] != nil && status.entries[file.path] != nil
                && status.entries[missing.path] != nil && status.entries["unknown"] != nil
        }
        precondition(status.entries[root.path]?.available == true && status.entries[root.path]?.icon != nil)
        precondition(status.entries[file.path]?.available == false)
        precondition(status.entries[missing.path]?.available == false)
        precondition(status.entries["unknown"]?.available == nil && status.entries["unknown"]?.icon == nil)
        precondition(status.entries["slow"] == nil, "慢目录不能阻塞其他目录的状态更新")
        status.refresh(paths)
        release.signal()
        wait { status.entries["slow"] != nil }
        lock.lock()
        let calls = slowCalls
        lock.unlock()
        precondition(calls == 1, "在途目录不应重复派发检查")

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        status.refresh([file.path])
        wait { status.entries[file.path]?.available == true }
        precondition(status.entries.count == 1, "删除的配置不应留在状态缓存中")
        status.refresh([])
        precondition(status.entries.isEmpty)
        print("✓ 常用目录状态检查通过（后台状态与图标、慢目录隔离、普通文件失效、状态不明、在途去重、恢复与移除）")
    }

    private static func wait(_ completed: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !completed() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        precondition(completed(), "目录状态异步更新超时")
    }
}
