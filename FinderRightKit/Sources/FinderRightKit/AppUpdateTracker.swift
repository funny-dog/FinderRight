import Foundation

/// 应用更新检测与启动追踪（纯数据与纯逻辑，可独立单测）。
public enum AppUpdateTracker {
    public struct Decision: Equatable {
        /// 是否为全新首次安装启动
        public let isFirstLaunch: Bool
        /// 是否为应用更新后的首次启动（版本号或构建号变化）
        public let isAppUpdated: Bool
        /// 上次记录的版本
        public let previousVersion: String?
        /// 上次记录的构建号
        public let previousBuild: String?

        public init(
            isFirstLaunch: Bool,
            isAppUpdated: Bool,
            previousVersion: String?,
            previousBuild: String?
        ) {
            self.isFirstLaunch = isFirstLaunch
            self.isAppUpdated = isAppUpdated
            self.previousVersion = previousVersion
            self.previousBuild = previousBuild
        }
    }

    /// 根据上次记录的版本与当前版本评估本次启动类型。
    /// - 若两者均未记录过，视为首次安装启动（不触发更新重启）。
    /// - 若已记录过历史版本且版本号或构建号有变化，视为应用更新后的启动。
    public static func evaluate(
        lastVersion: String?,
        lastBuild: String?,
        currentVersion: String,
        currentBuild: String
    ) -> Decision {
        let isFirst = (lastVersion == nil && lastBuild == nil)
        if isFirst {
            return Decision(
                isFirstLaunch: true,
                isAppUpdated: false,
                previousVersion: nil,
                previousBuild: nil
            )
        }

        let versionChanged = (lastVersion != currentVersion)
        let buildChanged = (lastBuild != currentBuild)
        let isUpdated = versionChanged || buildChanged

        return Decision(
            isFirstLaunch: false,
            isAppUpdated: isUpdated,
            previousVersion: lastVersion,
            previousBuild: lastBuild
        )
    }
}
