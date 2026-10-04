import Foundation

/// 「移动到 / 复制到常用目录」的纯逻辑：菜单显示名与移动前检查。扩展与主 App 共用。
public enum FavoriteDirectories {

    /// 子菜单里每个常用目录的显示名：默认取目录名；目录名重复时附上上级路径加以区分
    /// （如两个 Downloads：「Downloads — ~」「Downloads — /Volumes/E」）。
    public static func displayNames(for paths: [String], home: String) -> [String] {
        let names = paths.map { path -> String in
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? path : name
        }
        var counts: [String: Int] = [:]
        names.forEach { counts[$0, default: 0] += 1 }
        return zip(paths, names).map { path, name in
            guard counts[name, default: 0] > 1 else { return name }
            let parent = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
            return "\(name) — \(PathFormatter.string(for: [parent], format: .tilde, home: home))"
        }
    }
}

/// 移动 / 复制单个项目到目标目录前的检查。
public enum FileTransferCheck: Equatable {
    /// 可以执行
    case ok
    /// 移动到它当前所在的目录：无需操作
    case alreadyInDestination
    /// 目标就是该项目本身或位于它内部（文件夹放进自己里面）
    case destinationInsideSource

    public enum Mode: String {
        case move, copy
    }

    /// 只做路径层面的判断（不访问文件系统），调用方需传入已规范化的绝对路径
    public static func check(source: String, destinationDirectory: String, mode: Mode) -> FileTransferCheck {
        let src = trimmed(source), dest = trimmed(destinationDirectory)
        if dest == src || dest.hasPrefix(src + "/") {
            return .destinationInsideSource
        }
        if mode == .move, (src as NSString).deletingLastPathComponent == dest {
            return .alreadyInDestination
        }
        return .ok
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
