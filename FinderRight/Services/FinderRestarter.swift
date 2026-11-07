import Foundation
import FinderRightKit

/// 应用更新后重启 Finder，确保系统彻底重新挂载最新的 FinderSync 扩展。
enum FinderRestarter {
    static let lastVersionKey = "FinderRight.lastAppVersion"
    static let lastBuildKey = "FinderRight.lastAppBuild"

    private static var didRestartThisSession = false
    private static let lock = NSLock()

    /// 检查是否为应用更新后的首次启动。如果是且尚未重启过，则立即重启 Finder 一次。
    /// - Returns: 是否触发了重启
    @discardableResult
    static func restartFinderIfUpdated(
        currentVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        currentBuild: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
        userDefaults: UserDefaults = .standard,
        runner: (String, [String]) -> Void = { exec, args in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: exec)
            proc.arguments = args
            try? proc.run()
        }
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let lastVersion = userDefaults.string(forKey: lastVersionKey)
        let lastBuild = userDefaults.string(forKey: lastBuildKey)

        let decision = AppUpdateTracker.evaluate(
            lastVersion: lastVersion,
            lastBuild: lastBuild,
            currentVersion: currentVersion,
            currentBuild: currentBuild
        )

        // 记录最新版本号与构建号
        userDefaults.set(currentVersion, forKey: lastVersionKey)
        userDefaults.set(currentBuild, forKey: lastBuildKey)

        guard decision.isAppUpdated else { return false }
        guard !didRestartThisSession else { return false }

        didRestartThisSession = true
        let oldDesc = "v\(decision.previousVersion ?? "?")(\(decision.previousBuild ?? "?"))"
        let newDesc = "v\(currentVersion)(\(currentBuild))"
        NSLog("[FinderRestarter] 检测到应用已从 %@ 更新至 %@，正在重启 Finder 以刷新右键扩展...", oldDesc, newDesc)
        runner("/usr/bin/killall", ["Finder"])
        return true
    }

    /// 供单测重置会话内防重标记
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        didRestartThisSession = false
    }
}
