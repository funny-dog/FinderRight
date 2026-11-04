import AppKit
import FinderRightKit

extension AppDelegate {
    // MARK: - 退出前等待后台任务

    /// 菜单退出、更新安装、切换语言重启都会走到这里。有压缩 / 解压 / 粘贴在途时延后退出：
    /// 因更新而退出时（不论手动点击还是定时触发）一定等到任务完成；普通退出最多等 30 秒
    /// （粘贴另有崩溃恢复兜底）。等待期间顺手关闭任务入口，避免「确认空闲」之后又挤进新任务。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        CustomCommandController.shared.cancelAll()
        let jobs = FinderRightService.backgroundJobs
        // 先关闭后台任务入口与 IPC 监听；已受理的 IPC 请求可能还要回主线程完成（例如写剪贴板），
        // 主线程必须保持可调度，所有等待都放在后台线程
        jobs.close()
        let quittingForUpdate = UpdateChecker.shared.isInstallingUpdate
        let ipcDrained = DispatchSemaphore(value: 0)
        IPCWatcher.shared.shutdown { ipcDrained.signal() }
        DispatchQueue.global(qos: .userInitiated).async {
            // 因更新而退出：IPC 排空也必须等到完成，在途文件操作不能被中断；
            // 普通退出：IPC 请求正常毫秒级完成，异常挂起时最多等 30 秒放行
            if quittingForUpdate {
                ipcDrained.wait()
                NSLog("[AppDelegate] IPC 请求已排空（更新退出）")
            } else {
                if ipcDrained.wait(timeout: .now() + 30) != .success {
                    NSLog("[AppDelegate] IPC 请求等待超时（30s），继续退出")
                }
            }
            var finished = false
            // 因更新而退出时不打断耗时文件操作；普通退出沿用原有 30 秒上限
            repeat {
                finished = jobs.closeAndWait(timeout: 30)
            } while quittingForUpdate && !finished
            NSLog("[AppDelegate] 后台任务\(finished ? "已完成" : "等待超时（30s）")，继续退出")
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                // 任务入口保持关闭到进程结束，防止收尾瞬间再挤进新任务。
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}
