import Foundation

public enum DeveloperFileToolError: LocalizedError {
    case noRepository, notDirectory, unreadableDirectory

    public var errorDescription: String? {
        switch self {
        case .noRepository:
            return NSLocalizedString("找不到 Git 仓库，剪贴板未改变", comment: "developer tools")
        case .notDirectory:
            return NSLocalizedString("请选择普通文件夹，不支持符号链接或文件包", comment: "developer tools")
        case .unreadableDirectory:
            return NSLocalizedString("无法完整读取目录，剪贴板未改变", comment: "developer tools")
        }
    }
}

public enum ProjectRelativePath {
    public static func paths(for urls: [URL]) throws -> [String] {
        try urls.map { input in
            let url = input.standardizedFileURL
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            var root = attributes[.type] as? FileAttributeType == .typeDirectory ? url : url.deletingLastPathComponent()
            while true {
                let marker = root.appendingPathComponent(".git")
                if let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path) {
                    let type = attributes[.type] as? FileAttributeType
                    var isRepository = type == .typeDirectory
                    if type == .typeRegular {
                        // worktree/submodule 的 .git 是小型指向文件，不读取任意大的伪造标记。
                        let handle = try FileHandle(forReadingFrom: marker)
                        defer { try? handle.close() }
                        let data = try handle.read(upToCount: 4096) ?? Data()
                        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        isRepository = text.hasPrefix("gitdir:") && !text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                    if isRepository {
                        if url.path == root.path { return "." }
                        return String(url.path.dropFirst(root.path == "/" ? 1 : root.path.count + 1))
                    }
                }
                let parent = root.deletingLastPathComponent()
                guard parent.path != root.path else { throw DeveloperFileToolError.noRepository }
                root = parent
            }
        }
    }
}

public enum DirectoryTree {
    private static let excludedNames: Set<String> = [
        ".git", "node_modules", ".venv", "venv", "__pycache__", ".build", "build", "dist", ".next", ".DS_Store"
    ]
    private static let maxDepth = 4
    private static let maxEntries = 1_000
    private static let maxBytes = 128 * 1024

    private struct Entry {
        let url: URL
        let directory: Bool
        let expandable: Bool
    }

    public static func render(at input: URL) throws -> String {
        let root = input.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              try root.resourceValues(forKeys: [.isPackageKey]).isPackage != true else {
            throw DeveloperFileToolError.notDirectory
        }
        var lines = [root.path == "/" ? "/" : escaped(root.lastPathComponent) + "/"]
        var bytes = lines[0].utf8.count
        var count = 0
        var stopped = false

        func append(_ line: String) {
            guard !stopped else { return }
            // 留出末尾截断提示，输出始终不超过固定字节上限。
            guard bytes + line.utf8.count + 1 <= maxBytes - 8 else {
                lines.append("…")
                stopped = true
                return
            }
            lines.append(line)
            bytes += line.utf8.count + 1
        }

        func visit(_ directory: URL, prefix: String, depth: Int) throws {
            guard !stopped else { return }
            var enumerationError: Error?
            guard let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isPackageKey],
                options: [.skipsSubdirectoryDescendants], errorHandler: { _, error in
                    enumerationError = error
                    return false
                }) else { throw DeveloperFileToolError.unreadableDirectory }
            var entries: [Entry] = []
            let remaining = maxEntries - count
            while let url = enumerator.nextObject() as? URL {
                guard !excludedNames.contains(url.lastPathComponent) else { continue }
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let isDirectory = attributes[.type] as? FileAttributeType == .typeDirectory
                let isPackage = isDirectory ? (try url.resourceValues(forKeys: [.isPackageKey]).isPackage == true) : false
                entries.append(Entry(url: url, directory: isDirectory, expandable: isDirectory && !isPackage))
                // 有界截取后再排序，避免巨大目录在生成第一个字符前就耗尽资源。
                if entries.count > remaining { break }
            }
            if enumerationError != nil { throw DeveloperFileToolError.unreadableDirectory }
            entries.sort {
                if $0.directory != $1.directory { return $0.directory }
                return $0.url.lastPathComponent < $1.url.lastPathComponent
            }
            for (index, entry) in entries.enumerated() {
                guard !stopped else { return }
                guard count < maxEntries else {
                    append(prefix + "└── …")
                    stopped = true
                    return
                }
                let last = index == entries.count - 1
                let branch = last ? "└── " : "├── "
                let suffix = entry.directory ? "/" : ""
                let limited = entry.expandable && depth >= maxDepth
                append(prefix + branch + escaped(entry.url.lastPathComponent) + suffix + (limited ? " …" : ""))
                count += 1
                if entry.expandable && !limited {
                    try visit(entry.url, prefix: prefix + (last ? "    " : "│   "), depth: depth + 1)
                }
            }
        }
        try visit(root, prefix: "", depth: 1)
        return lines.joined(separator: "\n")
    }

    private static func escaped(_ name: String) -> String {
        name.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x5C: return "\\\\"
            case 0x0A: return "\\n"
            case 0x0D: return "\\r"
            case 0x09: return "\\t"
            case 0..<0x20, 0x7F...0x9F, 0x2028, 0x2029: return "\\u{\(String(scalar.value, radix: 16))}"
            default: return String(scalar)
            }
        }.joined()
    }
}
