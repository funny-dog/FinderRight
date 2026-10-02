import Foundation

/// macOS Services 调用方的启发式校验。
///
/// Services 可以被任何 App 用 NSPerformService 程序化调用，剪贴板里的路径完全由调用方控制。
/// 剪切 / 压缩 / 解压会以「完全磁盘访问」身份读写文件；用户从访达右键「服务」菜单触发时访达
/// 必在前台，借此挡住后台进程的伪造调用。这只是缓解，不是鉴权。
public enum ServiceInvocationPolicy {

    public static let trustedFrontmostBundleIds: Set<String> = ["com.apple.finder"]

    public static func acceptsDestructiveService(frontmostBundleId: String?) -> Bool {
        guard let frontmostBundleId else { return false }
        return trustedFrontmostBundleIds.contains(frontmostBundleId)
    }
}
