import Foundation

/// 新建文件名校验。
///
/// `createFile` 的 baseName / ext 会被直接拼进已通过白名单的目录路径；若其中带 `/` 或整体是 `..`，
/// 拼出的路径（如 `~/Desktop/../../../../tmp/x.txt`）会被内核解析到白名单之外，绕过路径校验。
/// 因此主 App 写文件前、设置界面保存模板后缀前，都必须经过这里。
public enum SafeFileName {

    /// macOS 文件名上限（APFS / HFS+ 均为 255 字节 UTF-8）
    public static let maxNameBytes = 255

    /// baseName 与 ext 组合成的文件名是否可以安全地作为**单个**路径分量使用。
    /// - Parameter ext: 可为空（表示无后缀）；非空时同样不得包含 `/` 等字符
    public static func isValid(baseName: String, ext: String) -> Bool {
        guard isValidPart(baseName), ext.isEmpty || isValidPart(ext) else { return false }
        let name = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        return name != "." && name != ".." && name.utf8.count <= maxNameBytes
    }

    /// 非空、不是 `.` / `..`、不含路径分隔符与 C0/C1 控制字符（含 NUL、换行）
    private static func isValidPart(_ part: String) -> Bool {
        guard !part.isEmpty, part != ".", part != ".." else { return false }
        return !part.unicodeScalars.contains { scalar in
            scalar == "/" || scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
        }
    }
}
