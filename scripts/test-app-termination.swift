import AppKit
import FinderRightKit

// 仅运行无窗口的测试进程，使用真实退出代理；不退出或修改已安装的 App。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        precondition(IPCWatcher.shared.completed, "退出前必须排空 IPC")
        precondition(FinderRightService.backgroundJobs.isIdle, "退出前必须完成文件任务")
        precondition(IPCWatcher.shared.shutdownCount == 1, "退出应排空一次")
        precondition(CustomCommandController.shared.cancelled, "退出前必须停止自定义命令")
        print("PASS: \(CommandLine.arguments[1]) 主队列发起退出并完成收尾")
    }
}

enum FinderRightService {
    static let backgroundJobs = BackgroundJobs()
}

final class CustomCommandController {
    static let shared = CustomCommandController()
    private(set) var cancelled = false
    func cancelAll() { cancelled = true }
}

final class UpdateChecker {
    static let shared = UpdateChecker()
    var isInstallingUpdate = true
}

final class IPCWatcher {
    static let shared = IPCWatcher()
    var completed = false
    var shutdownCount = 0
    let queue = DispatchQueue(label: "test.termination.ipc")

    func shutdown(notifyDrained: @escaping () -> Void) {
        shutdownCount += 1
        queue.async {
            DispatchQueue.main.sync { self.completed = true }
            notifyDrained()
        }
    }
}

@main
struct TerminationChecks {
    static func main() throws {
        if CommandLine.arguments.count == 1 {
            for scenario in ["更新退出", "普通退出"] {
                let child = Process()
                child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                child.arguments = [scenario]
                try child.run()
                child.waitUntilExit()
                precondition(child.terminationStatus == 0, "\(scenario) 未正常结束")
            }
            return
        }

        UpdateChecker.shared.isInstallingUpdate = CommandLine.arguments[1] == "更新退出"
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        app.delegate = delegate
        // 保持文件任务在途，并要求主队列参与收尾，覆盖安装时的真实等待关系。
        FinderRightService.backgroundJobs.run(on: .global()) {
            Thread.sleep(forTimeInterval: 0.15)
            DispatchQueue.main.sync {}
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
            fputs("FAIL: 退出死锁，主队列未完成收尾\n", stderr)
            exit(1)
        }
        DispatchQueue.main.async { ApplicationTermination.request() }
        withExtendedLifetime(delegate) { app.run() }
    }
}
