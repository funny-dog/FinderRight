import Foundation

/// 「打开路径」与常用目录输入的路径解析；只定位文件或目录，不使用文件读写操作的路径白名单。
public enum DirectoryPath {
    public enum ValidationError: String, Error {
        case invalidPath = "请输入有效的绝对路径或以 ~/ 开头的路径"
        case unavailable = "路径不存在或无法访问"
        case notDirectory = "该路径不是目录"
    }

    public enum Target: Equatable {
        case directory(URL)
        case file(URL)
    }

    /// 只接受目录（常用目录），输入按原样解析
    public static func url(for input: String, home: String) throws -> URL {
        guard case .directory(let url) = try target(for: input, home: home) else { throw ValidationError.notDirectory }
        return url
    }

    /// 先按原样解析（真实名字可能带首尾空格），不存在时再试清理后的写法：
    /// 去掉首尾空白与引号，解析 file:// 链接和终端转义（与常用目录输入框同一套规则）。
    public static func resolve(_ input: String, home: String) throws -> Target {
        // 某个写法是合法的绝对路径但不存在时，报「不存在」比报「格式无效」更准确
        var error = ValidationError.invalidPath
        for candidate in candidates(for: input) {
            do {
                return try target(for: candidate, home: home)
            } catch let failure as ValidationError {
                if failure == .unavailable { error = .unavailable }
            }
        }
        throw error
    }

    private static func target(for input: String, home: String) throws -> Target {
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
        return isDirectory.boolValue
            ? .directory(URL(fileURLWithPath: path, isDirectory: true))
            : .file(URL(fileURLWithPath: path, isDirectory: false))
    }

    /// 依次尝试的写法，去重后保持顺序
    private static func candidates(for input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // 中文引号、直角引号不属于 shell 语法，剥掉后再按 shell 规则解析一遍
        let unquoted = unquotedTypographic(trimmed)
        let result = [input, trimmed]
            + FavoriteDirectories.candidatePaths(fromInput: input)
            + [unquoted] + FavoriteDirectories.candidatePaths(fromInput: unquoted)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    private static let typographicQuotes: [(Character, Character)] = [("“", "”"), ("‘", "’"), ("「", "」")]

    private static func unquotedTypographic(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              typographicQuotes.contains(where: { $0.0 == first && $0.1 == last }) else { return text }
        return String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
}
