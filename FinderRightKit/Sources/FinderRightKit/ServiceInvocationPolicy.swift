import Foundation

/// macOS Services 调用方的启发式校验。
///
/// Services 可以被任何 App 用 NSPerformService 程序化调用，剪贴板里的路径完全由调用方控制。
/// 剪切 / 粘贴 / 压缩 / 解压会以「完全磁盘访问」身份读写文件；仅直接受理访达前台调用。
/// 系统可能先激活提供程序（云盘目录实测如此），剪切 / 粘贴在此情况下要求用户确认。这只是缓解，不是鉴权。
public enum ServiceInvocationPolicy {

    public static let trustedFrontmostBundleIds: Set<String> = ["com.apple.finder"]

    /// 推断服务的实际调用方。
    ///
    /// 经键盘快捷键触发服务时，系统会先把提供程序（本 App）激活到前台再派发（实测每次如此），
    /// 此时 frontmost 是本 App。若本 App 没有自己的窗口在前（用户并非在本 App 里操作），
    /// 实际调用方就是被激活前的前台应用。其余情况原样返回 frontmost。
    /// 这与 frontmost 校验一样只是缓解：后台 App 也能在访达在前时 NSPerformService，无法据此区分。
    public static func effectiveCaller(frontmostBundleId: String?,
                                       providerBundleId: String?,
                                       providerHasKeyWindow: Bool,
                                       previousFrontmostBundleId: String?) -> String? {
        guard let providerBundleId, !providerBundleId.isEmpty,
              frontmostBundleId == providerBundleId,
              !providerHasKeyWindow,
              let previous = previousFrontmostBundleId, previous != providerBundleId else {
            return frontmostBundleId
        }
        return previous
    }

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

    /// 粘贴 / 新建的目标目录：
    /// - 恰好一个文件夹：就是它（空白处服务收到的当前目录、或选中的目标文件夹）；
    /// - 否则（选中文件、多选）：选中项共同所在的目录，即用户正在浏览的文件夹——
    ///   快捷键调用时用户通常只是选着当前目录里的某个文件，不能因此拒绝。
    /// 选中项分属不同目录（如搜索结果）时无法确定目标，返回 nil。
    public static func pasteDestination(for items: [URL]) -> URL? {
        guard !items.isEmpty, items.allSatisfy(\.isFileURL) else { return nil }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if items.count == 1, let url = items.first,
           fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        guard items.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { return nil }
        let parents = Set(items.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        guard parents.count == 1, let parent = parents.first else { return nil }
        let url = URL(fileURLWithPath: parent, isDirectory: true)
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url
    }

    /// 终端与操作目标目录：选中项若是文件夹则用它本身，否则用其所在目录
    public static func targetDirectory(for url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    /// 校验单选普通文件入参
    public static func validateSingleFile(from urls: [URL]) -> URL? {
        guard urls.count == 1, let first = urls.first else { return nil }
        return first
    }

    /// 过滤出支持的解压归档文件
    public static func filterArchives(from urls: [URL]) -> [URL] {
        urls.filter { ArchiveKind.isArchive(fileName: $0.lastPathComponent) }
    }

    /// 校验输入项非空
    public static func validateNonEmpty(urls: [URL]) -> Bool {
        !urls.isEmpty
    }

    /// 校验常用目录传输前置条件
    public static func validateFavoritesTransfer(items: [URL], favorites: [String]) -> Bool {
        !items.isEmpty && !favorites.isEmpty
    }
}
