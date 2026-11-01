import Foundation

/// 退出前的等待策略：由「是否因更新而交接」决定，与「是否静默自动更新」分开。
///
/// 之前直接读自动安装标记，手动点击更新被当成普通退出，只等 30 秒就交接安装；
/// 现在手动与自动都等到文件任务完成，普通退出的 30 秒上限不变。
enum ExitWaitPolicy {
    /// 因更新而退出时等到文件任务完成；普通退出沿用 30 秒上限（由调用方控制超时）
    static func waitsForBackgroundJobs(isUpdating: Bool, isAutomaticInstall: Bool) -> Bool {
        isUpdating
    }
}
