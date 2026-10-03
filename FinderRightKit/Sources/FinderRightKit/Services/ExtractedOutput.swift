import Foundation

/// 解压产物的落位规则（对齐系统「归档实用工具」）。
///
/// 压缩包先解到同卷的暂存目录，再按顶层内容决定放出什么：
/// - 顶层只有一项（忽略 `__MACOSX`、`.DS_Store`）→ 直接把这一项放到压缩包旁边，
///   避免 `foo.zip` 里本就有 `foo/` 时解出 `foo/foo/…` 的双层嵌套；
/// - 否则（多项、空包、唯一项是隐藏文件）→ 整个暂存目录改名为与压缩包同名的文件夹。
/// 重名时依次尝试 `name-2`、`name-3`…（文件与包保留扩展名：`report-2.pdf`、`Foo-2.app`）。
public enum ExtractedOutput {

    /// 不计入「顶层项」的系统杂项；单项放出时随暂存目录一并删除
    static let ignoredNames: Set<String> = ["__MACOSX", ".DS_Store"]

    /// - Parameters:
    ///   - extractedRoot: 解压输出目录（必须与 directory 同卷，原子改名要求）
    ///   - directory: 最终放置目录（压缩包所在目录）
    ///   - folderName: 需要整体放出时使用的文件夹名（压缩包去掉扩展名）
    /// - Returns: 最终放出的文件或文件夹
    public static func place(extractedRoot: URL, into directory: URL, folderName: String) throws -> URL {
        let entries = try FileManager.default
            .contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey])
            .filter { !ignoredNames.contains($0.lastPathComponent) }

        // 唯一项是隐藏文件时不单独放出：用户在访达里会看不到解压结果
        if entries.count == 1, let only = entries.first, !only.lastPathComponent.hasPrefix(".") {
            let values = try? only.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let keepExtension = values?.isDirectory != true || values?.isPackage == true
            return try move(only, into: directory, preferredName: only.lastPathComponent, keepExtension: keepExtension)
        }
        return try move(extractedRoot, into: directory, preferredName: folderName, keepExtension: false)
    }

    /// 第 n 次尝试的名字：n == 0 为原名，之后从 `-2` 起编号
    public static func candidateName(_ preferred: String, keepExtension: Bool, attempt n: Int) -> String {
        guard n > 0 else { return preferred }
        let ext = keepExtension ? (preferred as NSString).pathExtension : ""
        guard !ext.isEmpty else { return "\(preferred)-\(n + 1)" }
        return "\((preferred as NSString).deletingPathExtension)-\(n + 1).\(ext)"
    }

    private static func move(_ source: URL, into directory: URL, preferredName: String, keepExtension: Bool) throws -> URL {
        try ExclusiveRename.move(source, into: directory) { n in
            candidateName(preferredName, keepExtension: keepExtension, attempt: n)
        }
    }
}
