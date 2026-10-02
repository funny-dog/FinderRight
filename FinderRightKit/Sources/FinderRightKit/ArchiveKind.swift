import Foundation

/// 可解压压缩包的识别规则。FinderSync 扩展（决定是否显示「解压」菜单）与主 App 的
/// Services（过滤非压缩包）共用这一份，避免两处后缀列表不一致。
public enum ArchiveKind {

    /// 支持解压的后缀（小写；兼容 .tar.gz / .tar.bz2 等复合后缀，因为它们本身也以 .gz / .bz2 结尾）
    public static let suffixes = [".zip", ".tar", ".gz", ".tgz", ".bz2", ".tbz",
                                  ".xz", ".txz", ".7z", ".rar"]

    public static func isArchive(fileName: String) -> Bool {
        let name = fileName.lowercased()
        return suffixes.contains { name.hasSuffix($0) }
    }
}
