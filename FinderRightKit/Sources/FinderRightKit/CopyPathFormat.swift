import Foundation

/// 「复制路径」写入剪贴板的格式（设置里选择，默认绝对路径）。
public enum CopyPathFormat: String, CaseIterable, Identifiable {
    /// /Users/me/Documents/a b.txt
    case absolute
    /// ~/Documents/a b.txt
    case tilde
    /// a b.txt
    case name
    /// '/Users/me/Documents/a b.txt'（多项以空格分隔，可直接粘贴为命令参数）
    case shellEscaped
    /// file:///Users/me/Documents/a%20b.txt
    case fileURL

    public var id: String { rawValue }

    /// 设置界面显示名的本地化 key
    public var titleKey: String {
        switch self {
        case .absolute: return "绝对路径"
        case .tilde: return "以 ~ 开头的路径"
        case .name: return "仅文件名"
        case .shellEscaped: return "终端转义路径"
        case .fileURL: return "文件 URL"
        }
    }
}

/// 按 CopyPathFormat 生成剪贴板文本。纯函数，扩展与主 App（「服务」菜单）共用。
public enum PathFormatter {

    /// - Parameter home: 真实用户主目录（沙箱扩展必须传 IPCBridge.realUserHomeDirectory，而非容器目录）
    public static func string(for urls: [URL], format: CopyPathFormat, home: String) -> String {
        let items = urls.map { item(for: $0, format: format, home: home) }
        // 终端转义格式用空格连接，粘贴进终端即为多个参数；其余每行一项
        return items.joined(separator: format == .shellEscaped ? " " : "\n")
    }

    static func item(for url: URL, format: CopyPathFormat, home: String) -> String {
        let path = url.path
        switch format {
        case .absolute:
            return path
        case .tilde:
            let home = home.hasSuffix("/") ? String(home.dropLast()) : home
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
            return path
        case .name:
            return url.lastPathComponent
        case .shellEscaped:
            return shellQuoted(path)
        case .fileURL:
            return URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath).absoluteString
        }
    }

    /// 只含安全字符时原样返回；否则用单引号包裹，内部单引号写成 '\''
    public static func shellQuoted(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
