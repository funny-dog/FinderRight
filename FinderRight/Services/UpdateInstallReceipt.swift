import Foundation
import FinderRightKit

/// 新版回执：替换脚本把待确认的安装写进 `Application Support/FinderRight/update-pending.plist`，
/// 新版完成基本初始化后删掉旧版备份与回执。
///
/// 只有收到回执才清理备份：替换脚本里「open 返回成功」不算——那只说明启动命令发出去了。
/// 新版自身走到初始化完成这一步（任何启动方式，含自动更新重启的后台启动）才算初始化成功；
/// 备份删除失败时保留回执，下次启动重试。
enum UpdateInstallReceipt {
    /// 回执与错误文件所在的目录；测试与集成脚本可临时指向候选目录，默认是真实用户目录
    private(set) static var directory: URL = IPCBridge.rootDirectory
    /// 参与核对的「当前运行实例」位置：别的副本（如开发目录）启动时不动安装位置的备份
    private(set) static var runningBundleURL: URL = Bundle.main.bundleURL

    static var receiptURL: URL { directory.appendingPathComponent("update-pending.plist") }

    static func useDirectory<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let original = directory
        directory = url
        defer { directory = original }
        return try body()
    }

    static func useRunningBundle<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let original = runningBundleURL
        runningBundleURL = url
        defer { runningBundleURL = original }
        return try body()
    }

    struct Receipt: Equatable {
        let version: String
        let backupPath: String
        let installedAt: String?
    }

    /// 读取待确认的回执；没有或无法解析时返回 nil（不能凭残缺内容删备份）
    static func load() -> Receipt? {
        guard let data = try? Data(contentsOf: receiptURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = plist["version"] as? String,
              let backup = plist["backup"] as? String else { return nil }
        return Receipt(version: version,
                       backupPath: backup,
                       installedAt: plist["installedAt"] as? String)
    }

    /// 是否应该在此次启动完成回执：当前版本已经不低于待确认版本，即认为新版初始化成功。
    /// 自动更新重启的后台启动同样走到了初始化完成，不能把它排除在确认之外，
    /// 否则静默更新会长期留下备份与待确认状态
    static func decide(receipt: Receipt?, currentVersion: String) -> Bool {
        guard let receipt else { return false }
        let current = UpdatePackageCheck.trimmingLeadingV(currentVersion)
        let expected = UpdatePackageCheck.trimmingLeadingV(receipt.version)
        // 已经不低于待确认的版本即视为新版初始化成功；之后用户又更新过，旧回执也一并完成
        return VersionComparator.compareVersions(current, expected) != .orderedAscending
    }

    /// 完成回执：核对运行实例后先删备份，备份确认不在了才删回执。
    /// 清理失败（或运行实例与回执目标不符）时保留回执，下次启动重试；重复调用是安全的
    static func complete() {
        guard let receipt = load() else { return }
        guard isRunningTargetInstance(backupPath: receipt.backupPath) else { return }
        if removeBackupIfSafe(at: receipt.backupPath) {
            try? FileManager.default.removeItem(at: receiptURL)
        }
    }

    /// 只核对与回执同一目标位置的运行实例：回执描述的是替换脚本安装的那个位置，
    /// 别处副本（开发构建、Translocation 副本）启动时不能替它清理
    private static func isRunningTargetInstance(backupPath: String) -> Bool {
        let target = URL(fileURLWithPath: backupPath).deletingLastPathComponent()
            .appendingPathComponent("FinderRight.app")
        return target.standardizedFileURL.path == runningBundleURL.standardizedFileURL.path
    }

    /// 只删除替换脚本约定命名的旧版备份目录，绝不按回执内容删任意路径；返回备份是否已确认不在
    @discardableResult
    private static func removeBackupIfSafe(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard url.lastPathComponent == "FinderRight.old.app",
              url.deletingLastPathComponent().standardizedFileURL.path != "/" else { return false }
        try? FileManager.default.removeItem(at: url)
        // 删除失败（占用、权限）时保留回执以便下次重试，绝不能删了回执却留下备份
        return !FileManager.default.fileExists(atPath: url.path)
    }
}
