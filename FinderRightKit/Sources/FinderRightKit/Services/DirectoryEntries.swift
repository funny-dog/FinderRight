import Foundation

/// 用 POSIX opendir / readdir 列出目录的直接子项名（不含 `.`、`..`）。
///
/// FileManager 的 contentsOfDirectory / enumerator 会把所有以 `._` 开头的文件藏起来，
/// 不只是 AppleDouble，连恰好以 `._` 开头的普通文件也看不到；需要完整列出时用这里。
enum DirectoryEntries {

    static func names(in directory: URL) throws -> [String] {
        guard let dir = opendir(directory.path) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
