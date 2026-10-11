import Foundation

/// macOS Services 调用方的启发式校验。
///
/// Services 可以被任何 App 用 NSPerformService 程序化调用，剪贴板里的路径完全由调用方控制。
/// 剪切 / 粘贴 / 压缩 / 解压会以「完全磁盘访问」身份读写文件；仅直接受理访达前台调用。
/// 系统可能先激活提供程序（云盘目录实测如此），剪切 / 粘贴在此情况下要求用户确认。这只是缓解，不是鉴权。
public enum ServiceInvocationPolicy {

    public static let trustedFrontmostBundleIds: Set<String> = ["com.apple.finder"]

    public static func acceptsDestructiveService(frontmostBundleId: String?) -> Bool {
        guard let frontmostBundleId else { return false }
        return trustedFrontmostBundleIds.contains(frontmostBundleId)
    }

    /// Services 可能激活提供程序；自身前台只允许弹出确认框，不能直接受理文件移动。
    public static func requiresServiceConfirmation(frontmostBundleId: String?, providerBundleId: String?) -> Bool {
        guard let providerBundleId, !providerBundleId.isEmpty else { return false }
        return frontmostBundleId == providerBundleId
    }

    /// 新建与常用目录传输始终先展示确认框；此处只允许进入交互流程，不授权直接读写。
    public static func acceptsInteractiveService(frontmostBundleId: String?, providerBundleId: String?) -> Bool {
        acceptsDestructiveService(frontmostBundleId: frontmostBundleId)
            || requiresServiceConfirmation(frontmostBundleId: frontmostBundleId, providerBundleId: providerBundleId)
    }

    /// 空白处服务可收到当前目录；选中文件夹时则收到该文件夹，拒绝猜测文件或多选的目标。
    public static func pasteDestination(for items: [URL]) -> URL? {
        guard items.count == 1, let url = items.first, url.isFileURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }
}
