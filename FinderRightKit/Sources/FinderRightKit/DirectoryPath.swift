import Foundation

/// 「前往目录」的路径校验；只打开目录，不使用文件读写操作的路径白名单。
public enum DirectoryPath {
    public enum ValidationError: String, Error {
        case invalidPath = "请输入有效的绝对路径或以 ~/ 开头的路径"
        case unavailable = "目录不存在或无法访问"
        case notDirectory = "该路径不是目录"
    }

    public static func url(for input: String, home: String) throws -> URL {
        let path: String
        if input == "~" {
            path = home
        } else if input.hasPrefix("~/") {
            path = home + input.dropFirst()
        } else {
            path = input
        }
        guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError.invalidPath }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ValidationError.unavailable
        }
        guard isDirectory.boolValue else { throw ValidationError.notDirectory }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
