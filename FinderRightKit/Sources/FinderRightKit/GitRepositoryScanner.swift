import Foundation

public struct GitRepositoryItem: Identifiable, Equatable, Hashable {
    public let id: String
    public let url: URL
    public let name: String
    public let path: String
    public let displayPath: String
    public var branch: String
    public var statusDescription: String?
    public var isClean: Bool?
    public var lastModified: Date?

    public init(
        url: URL,
        branch: String = "",
        statusDescription: String? = nil,
        isClean: Bool? = nil,
        lastModified: Date? = nil
    ) {
        let standard = url.standardizedFileURL
        self.url = standard
        self.id = standard.path
        self.path = standard.path
        self.name = standard.lastPathComponent
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if standard.path == home {
            self.displayPath = "~"
        } else if standard.path.hasPrefix(home + "/") {
            self.displayPath = "~" + standard.path.dropFirst(home.count)
        } else {
            self.displayPath = standard.path
        }
        self.branch = branch
        self.statusDescription = statusDescription
        self.isClean = isClean
        self.lastModified = lastModified
    }
}

public enum GitRepositoryScanner {
    public static let defaultSkipNames: Set<String> = [
        "Library", ".Trash", ".cache", ".npm", ".cargo", ".rustup", ".gem",
        "OrbStack", ".orbstack", "Pods", "node_modules", "DerivedData", ".build",
        ".gemini", ".codex", ".workbuddy", ".qoder", ".workbuddy-ai", ".dsh",
        ".local", ".swiftpm", "Applications"
    ]

    /// 读取仓库的当前分支名称（纯文件读取，极速）
    public static func readBranch(at repoURL: URL) -> String {
        let gitPath = repoURL.appendingPathComponent(".git").path
        var headURL: URL?
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDir) {
            if isDir.boolValue {
                headURL = repoURL.appendingPathComponent(".git/HEAD")
            } else if let content = try? String(contentsOfFile: gitPath, encoding: .utf8),
                      content.hasPrefix("gitdir:") {
                let relative = content.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                let resolved = URL(fileURLWithPath: relative, relativeTo: repoURL).standardizedFileURL
                headURL = resolved.appendingPathComponent("HEAD")
            }
        }
        guard let headURL,
              let head = (try? String(contentsOf: headURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !head.isEmpty else {
            return ""
        }
        if head.hasPrefix("ref: refs/heads/") {
            return String(head.dropFirst("ref: refs/heads/".count))
        }
        if head.count >= 7 {
            return String(head.prefix(7))
        }
        return head
    }

    /// 快速检查仓库状态（工作区干净还是有改动）
    public static func readStatusSummary(at root: URL) -> (isClean: Bool, description: String)? {
        guard let output = try? LocalGit.run(at: root, ["status", "--porcelain=v1", "--ignore-submodules=dirty"]),
              output.status == 0 else {
            return nil
        }
        if output.data.isEmpty {
            return (true, NSLocalizedString("工作区干净", comment: ""))
        }
        let text = String(decoding: output.data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }
        let count = lines.count
        let desc = String(format: NSLocalizedString("%d 个改动", comment: ""), count)
        return (false, desc)
    }

    /// 在指定根目录下扫描 Git 仓库
    public static func scan(
        roots: [URL] = [FileManager.default.homeDirectoryForCurrentUser],
        maxDepth: Int = 6,
        skipNames: Set<String> = defaultSkipNames
    ) -> [GitRepositoryItem] {
        var foundURLs: [URL] = []
        var visitedPaths = Set<String>()
        let fm = FileManager.default

        for root in roots {
            scanDirectory(
                url: root.standardizedFileURL,
                currentDepth: 1,
                maxDepth: maxDepth,
                skipNames: skipNames,
                fileManager: fm,
                found: &foundURLs,
                visited: &visitedPaths
            )
        }

        return foundURLs.map { url in
            let branch = readBranch(at: url)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = attrs?[.modificationDate] as? Date
            return GitRepositoryItem(url: url, branch: branch, lastModified: mtime)
        }.sorted { (a, b) -> Bool in
            if let dateA = a.lastModified, let dateB = b.lastModified, dateA != dateB {
                return dateA > dateB
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    private static func scanDirectory(
        url: URL,
        currentDepth: Int,
        maxDepth: Int,
        skipNames: Set<String>,
        fileManager: FileManager,
        found: inout [URL],
        visited: inout Set<String>
    ) {
        let path = url.path
        guard visited.insert(path).inserted else { return }

        // 检查自身是否为 git 仓库
        let gitPath = url.appendingPathComponent(".git").path
        if fileManager.fileExists(atPath: gitPath) {
            found.append(url)
            return // 发现仓库后不再继续深入其子目录
        }

        guard currentDepth <= maxDepth else { return }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            var isDir: AnyObject?
            try? (item as NSURL).getResourceValue(&isDir, forKey: .isDirectoryKey)
            guard (isDir as? NSNumber)?.boolValue == true else { continue }

            var isSymlink: AnyObject?
            try? (item as NSURL).getResourceValue(&isSymlink, forKey: .isSymbolicLinkKey)
            if (isSymlink as? NSNumber)?.boolValue == true { continue }

            let name = item.lastPathComponent
            if skipNames.contains(name) || name.hasPrefix(".venv") { continue }

            scanDirectory(
                url: item,
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                skipNames: skipNames,
                fileManager: fileManager,
                found: &found,
                visited: &visited
            )
        }
    }
}
