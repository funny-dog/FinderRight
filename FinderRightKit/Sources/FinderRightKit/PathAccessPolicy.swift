import Foundation

/// 主 App 文件操作的路径访问策略（纯字符串逻辑，便于单测）。
///
/// 主 App 持有「完全磁盘访问」，它拉起的 ditto / tar / cp 子进程也继承这一授权。IPC 与 Services
/// 入口无法鉴别调用方，若放行整个 home，任意同用户进程都能借它读走 FDA 专属数据（例如把
/// ~/Library/Messages 压缩成不受保护的 ~/Library/Messages.zip）。因此在原有白名单之上，
/// 再拒绝一批只有 FDA 才能访问的数据目录。这是快速缓解，根治需要校验调用方签名。
public enum PathAccessPolicy {

    public enum Role: Equatable {
        /// 会被读取或移动的源（压缩项、剪切项、压缩包）
        case source
        /// 写入目标目录（新建文件、粘贴目标）
        case destination
    }

    /// 相对 home 的 FDA 专属数据目录。比较时不区分大小写：APFS 默认大小写不敏感，
    /// `~/library/MESSAGES` 与 `~/Library/Messages` 是同一个目录
    public static let protectedHomeRelativePaths: [String] = [
        "Library/Messages",
        "Library/Mail",
        "Library/Safari",
        "Library/Cookies",
        "Library/Containers",
        "Library/Group Containers",
        "Library/Calendars",
        "Library/Suggestions",
        "Library/HomeKit",
        "Library/IdentityServices",
        "Library/Accounts",
        "Library/Keychains",
        "Library/Biome",
        "Library/PersonalizationPortrait",
        "Library/Metadata/CoreSpotlight",
        "Library/Application Support/com.apple.TCC",
        "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CallHistoryTransactions",
        "Library/Application Support/Knowledge",
        "Library/Application Support/MobileSync",
    ]

    /// - Parameters:
    ///   - path: 已展开 `~` 并解析过符号链接的绝对路径（解析由调用方负责，见 FinderRightService.isPathAllowed）
    ///   - home / temporaryDirectory: 同样需已解析符号链接
    public static func isAllowed(_ path: String, role: Role, home: String, temporaryDirectory: String) -> Bool {
        let p = standardize(path)
        let h = standardize(home)
        let tmp = standardize(temporaryDirectory)

        // 1. 原有白名单：真实 home、外接卷、临时目录
        let inHome = p == h || p.hasPrefix(h + "/")
        let inVolumes = p == "/Volumes" || p.hasPrefix("/Volumes/")
        let inTmp = p == tmp || p.hasPrefix(tmp + "/") || p.hasPrefix("/private/tmp/") || p.hasPrefix("/tmp/")
        guard inHome || inVolumes || inTmp else { return false }

        let lower = p.lowercased()

        // 2. 照片图库与时间机器备份：位置不固定，按路径特征识别
        let components = lower.split(separator: "/")
        if components.contains(where: { $0.hasSuffix(".photoslibrary") || $0 == "backups.backupdb" }) {
            return false
        }
        if lower == "/volumes/.timemachine" || lower.hasPrefix("/volumes/.timemachine/") {
            return false
        }

        // 3. home 下的 FDA 专属数据目录
        let lowerHome = h.lowercased()
        for relative in protectedHomeRelativePaths {
            let protectedPath = lowerHome + "/" + relative.lowercased()
            // 位于受保护目录内：读取、写入都拒绝
            if lower == protectedPath || lower.hasPrefix(protectedPath + "/") {
                return false
            }
            // 源路径是受保护目录的祖先（如 ~/Library、~）：压缩或移动它会把受保护数据一并带走
            if role == .source && protectedPath.hasPrefix(lower + "/") {
                return false
            }
        }
        return true
    }

    private static func standardize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
