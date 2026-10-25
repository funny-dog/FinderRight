import Foundation
import Darwin

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

    /// 把设置页输入框里的文本拆成候选路径，兼容「复制路径」的各种格式：
    /// 绝对路径、~ 路径、file:// URL 每行一项；终端转义路径以空格分隔，支持单引号、双引号与反斜杠转义。
    /// 只做文本层面的拆分与反转义，存在性、是否目录与白名单由调用方校验。
    public static func candidatePaths(fromInput text: String) -> [String] {
        text.components(separatedBy: .newlines).flatMap { rawLine -> [String] in
            // 路径必以 / 或 ~ 开头，去掉行首空白不会误伤；行尾空格可能是真实目录名的一部分，保留
            let line = String(rawLine.drop(while: { $0 == " " || $0 == "\t" }))
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
            if line.lowercased().hasPrefix("file://") {
                guard let url = URL(string: line), url.isFileURL else { return [line] }
                return [url.path]
            }
            if line.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" }),
               let words = shellWords(line) {
                return words
            }
            return [line]
        }
    }

    /// 按 shell 规则拆词；引号不配对时返回 nil，由调用方按普通路径处理（如目录名本身含单引号）
    static func shellWords(_ line: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var chars = line.makeIterator()
        while let c = chars.next() {
            switch c {
            case " ", "\t":
                if inWord { words.append(current); current = ""; inWord = false }
            case "'":
                inWord = true
                var closed = false
                while let q = chars.next() {
                    if q == "'" { closed = true; break }
                    current.append(q)
                }
                guard closed else { return nil }
            case "\"":
                inWord = true
                var closed = false
                while let q = chars.next() {
                    if q == "\"" { closed = true; break }
                    if q == "\\" {
                        // 双引号内反斜杠只转义 " \ $ `，其余原样保留
                        guard let next = chars.next() else { return nil }
                        if !"\"\\$`".contains(next) { current.append(q) }
                        current.append(next)
                    } else {
                        current.append(q)
                    }
                }
                guard closed else { return nil }
            case "\\":
                inWord = true
                guard let next = chars.next() else { return nil }
                current.append(next)
            default:
                inWord = true
                current.append(c)
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

/// Finder 菜单只读取内存；每个目录独立在后台检查，避免断开的网络盘阻塞右键或其他目录。
public final class FavoriteDirectoryAvailability {
    private let lock = NSLock()
    private var entries: [String: (unavailable: Bool, checkedAt: TimeInterval)] = [:]
    private var checking: Set<String> = []
    private let check: (String) -> Bool?

    public init(check: ((String) -> Bool?)? = nil) {
        self.check = check ?? Self.isAvailable
    }

    /// nil 表示权限或设备状态不明，不能据此认定目录失效；调用方须在后台检查。
    public static func isAvailable(_ path: String) -> Bool? {
        var info = stat()
        if stat(path, &info) == 0 { return info.st_mode & S_IFMT == S_IFDIR }
        return errno == ENOENT || errno == ENOTDIR ? false : nil
    }

    // shortcut: 按需每隔 5 秒后台复查，结果在下次展开菜单时生效；需要实时变化时接入目录事件通知。
    public func unavailablePaths(in paths: [String], now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Set<String> {
        let paths = Set(paths)
        lock.lock()
        entries = entries.filter { paths.contains($0.key) }
        let unavailable = Set(entries.filter { $0.value.unavailable }.keys)
        let refresh = paths.filter { path in
            !checking.contains(path) && (entries[path].map { now - $0.checkedAt >= 5 } ?? true)
        }
        checking.formUnion(refresh)
        lock.unlock()

        for path in refresh {
            DispatchQueue.global(qos: .utility).async {
                let unavailable = self.check(path) == false
                self.lock.lock()
                self.entries[path] = (unavailable, now)
                self.checking.remove(path)
                self.lock.unlock()
            }
        }
        return unavailable
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
