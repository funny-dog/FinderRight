import Foundation
import Darwin

public enum GitDiffScope: String, CaseIterable { case unstaged, staged }

public struct GitStatusEntry: Identifiable, Equatable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: String
    public let worktreeStatus: String
    public var id: String { path }
    public var isUntracked: Bool { worktreeStatus == "?" }
    public var isConflict: Bool {
        ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(indexStatus + worktreeStatus)
    }
    public var hasStaged: Bool { !isConflict && indexStatus != " " && indexStatus != "?" }
    public var hasUnstaged: Bool { isUntracked || isConflict || worktreeStatus != " " }
}

public enum GitStatusError: LocalizedError {
    case notRepository, failed(String), timedOut, tooLarge, unsupportedFile, missingObject

    public var errorDescription: String? {
        switch self {
        case .notRepository: return NSLocalizedString("此位置不属于 Git 仓库", comment: "")
        case .failed(let detail): return String(format: NSLocalizedString("无法读取 Git 状态：%@", comment: ""), detail)
        case .timedOut: return NSLocalizedString("Git 读取超时，请稍后刷新", comment: "")
        case .tooLarge: return NSLocalizedString("Git 输出过大，暂不支持查看", comment: "")
        case .unsupportedFile: return NSLocalizedString("暂不支持符号链接或子模块的内容差异", comment: "")
        case .missingObject: return NSLocalizedString("无法读取本地 Git 对象，请刷新后重试", comment: "")
        }
    }
}

enum LocalGit {
    private final class ErrorOutput { var data = Data() }
    private final class TimeoutFlag {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); value = true; lock.unlock() }
        var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    struct Output { let status: Int32; let data: Data; let error: String }

    /// 需要在网络上通信的操作（拉取/推送）才放开协议白名单。
    ///
    /// 只读查询保持 `protocol.allow=never`：仓库里的子模块、`.gitmodules` 或配置
    /// 都不能诱使查看状态的代码去联网。远程操作由用户主动点击触发，
    /// 因此只允许 Git 自身支持的常见传输，仍禁掉 ext/file 这类可执行任意命令的协议。
    private static func transportArguments(writing: Bool) -> [String] {
        writing ? ["-c", "protocol.allow=never",
                   "-c", "protocol.https.allow=always",
                   "-c", "protocol.ssh.allow=always",
                   "-c", "protocol.git.allow=always"]
                : ["-c", "protocol.allow=never"]
    }

    static func run(at root: URL, _ arguments: [String], limit: Int = 8 * 1024 * 1024, writing: Bool = false) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false",
                             "-c", "core.untrackedCache=false"] + transportArguments(writing: writing) + ["-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        // 生产环境只放行常见网络传输；集成测试用 file:// 本地裸仓库，经环境变量显式追加。
        var allowed = writing ? "https:ssh:git" : ""
        if writing, let extra = ProcessInfo.processInfo.environment["FINDERRIGHT_GIT_ALLOW_PROTOCOL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty {
            allowed += ":" + extra
        }
        environment["GIT_ALLOW_PROTOCOL"] = allowed
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        if writing {
            environment["GIT_EDITOR"] = ":"
            environment["GIT_HTTP_LOW_SPEED_LIMIT"] = "1000"
            environment["GIT_HTTP_LOW_SPEED_TIME"] = "30"
            environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let timedOut = TimeoutFlag()
        let timer = DispatchWorkItem {
            if process.isRunning {
                timedOut.mark()
                kill(process.processIdentifier, SIGKILL)
            }
        }
        // 写入可能在运行 hooks 或签名，不以只读查询的时限强杀，避免留下半完成的 Git 操作。
        if !writing { DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer) }
        defer { timer.cancel() }
        let errorOutput = ErrorOutput()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                errorOutput.data.append(chunk)
                if errorOutput.data.count > 64 * 1024 { errorOutput.data = Data(errorOutput.data.suffix(64 * 1024)) }
            }
        }
        var data = Data(), exceeded = false
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            if !exceeded {
                if data.count + chunk.count > limit {
                    if writing {
                        data.append(chunk)
                        data = Data(data.suffix(limit))
                    } else {
                        exceeded = true
                        kill(process.processIdentifier, SIGKILL)
                    }
                } else { data.append(chunk) }
            }
        }
        process.waitUntilExit()
        group.wait()
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
        if timedOut.fired { throw GitStatusError.timedOut }
        if exceeded { throw GitStatusError.tooLarge }
        return Output(status: process.terminationStatus, data: data,
                      error: String(decoding: errorOutput.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func checked(at root: URL, _ arguments: [String], limit: Int = 8 * 1024 * 1024) throws -> Data {
        let result = try run(at: root, arguments, limit: limit)
        guard result.status == 0 else { throw GitStatusError.failed(result.error) }
        return result.data
    }
}

public struct GitStatusSnapshot {
    public let root: URL
    public let branch: String
    public let localBranches: [String]
    public let entries: [GitStatusEntry]
    /// 当前分支的远端跟踪分支（如 origin/main）；没有上游时为 nil
    public let upstream: String?
    /// 相对上游的领先 / 落后提交数
    public let ahead: Int
    public let behind: Int
    /// 是否存在任何远端（用于决定拉取/推送按钮是否可用）
    public let hasRemote: Bool

    public init(root: URL, branch: String, localBranches: [String], entries: [GitStatusEntry],
                upstream: String? = nil, ahead: Int = 0, behind: Int = 0, hasRemote: Bool = false) {
        self.root = root
        self.branch = branch
        self.localBranches = localBranches
        self.entries = entries
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.hasRemote = hasRemote
    }

    public static func read(at url: URL) throws -> Self {
        guard url.isFileURL else { throw GitStatusError.notRepository }
        let input = url.standardizedFileURL
        let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
        let directory = attributes[.type] as? FileAttributeType == .typeDirectory ? input : input.deletingLastPathComponent()
        let top = try LocalGit.run(at: directory, ["rev-parse", "--show-toplevel"])
        guard top.status == 0 else {
            if top.error.contains("not a git repository") || top.error.contains("must be run in a work tree") { throw GitStatusError.notRepository }
            throw GitStatusError.failed(top.error)
        }
        guard var path = String(data: top.data, encoding: .utf8), path.hasSuffix("\n") else { throw GitStatusError.notRepository }
        path.removeLast()
        let root = URL(fileURLWithPath: path, isDirectory: true)
        // NUL 分隔保留文件名中的换行；展开未跟踪目录，才能逐个选择文件查看差异。
        let data = try LocalGit.checked(at: root, ["status", "--porcelain=v1", "-b", "-z", "--untracked-files=all", "--ignore-submodules=dirty"])
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false)
        if tokens.last?.isEmpty == true { tokens.removeLast() }
        guard let header = tokens.first, let rawBranch = String(data: header.dropFirst(3), encoding: .utf8), header.starts(with: [35, 35, 32]) else {
            throw GitStatusError.failed(NSLocalizedString("无法解析 Git 输出", comment: ""))
        }
        var branch = rawBranch.components(separatedBy: "...")[0]
        for prefix in ["No commits yet on ", "Initial commit on "] where branch.hasPrefix(prefix) { branch.removeFirst(prefix.count) }
        if branch == "HEAD (no branch)" { branch = NSLocalizedString("分离的 HEAD", comment: "") }
        let entries = try Self.parseEntries(tokens: tokens[1...])
        let refs = try LocalGit.checked(at: root, ["for-each-ref", "--format=%(refname:strip=2)", "refs/heads/"])
        let branches = String(decoding: refs, as: UTF8.self).split(separator: "\n").map(String.init)
        let remotes = try LocalGit.run(at: root, ["remote"])
        let hasRemote = remotes.status == 0 && !remotes.data.isEmpty
        // 上游由用户在命令行里配置；这里只读，不替用户设置跟踪关系。
        var upstream: String?
        var ahead = 0, behind = 0
        let tracking = try LocalGit.run(at: root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])
        if tracking.status == 0, let raw = String(data: tracking.data, encoding: .utf8) {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { upstream = name }
        }
        if upstream != nil {
            let counts = try LocalGit.run(at: root, ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"])
            if counts.status == 0,
               let text = String(data: counts.data, encoding: .utf8) {
                let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                if parts.count == 2 {
                    ahead = Int(parts[0]) ?? 0
                    behind = Int(parts[1]) ?? 0
                }
            }
        }
        return Self(root: root, branch: branch, localBranches: branches, entries: entries,
                    upstream: upstream, ahead: ahead, behind: behind, hasRemote: hasRemote)
    }

    static func parseEntries(tokens: ArraySlice<Data>) throws -> [GitStatusEntry] {
        var entries: [GitStatusEntry] = []
        var positions: [String: Int] = [:]
        var index = tokens.startIndex
        while index < tokens.endIndex {
            let token = Array(tokens[index])
            guard token.count >= 4, token[2] == 32, let name = String(bytes: token.dropFirst(3), encoding: .utf8) else {
                throw GitStatusError.failed(NSLocalizedString("无法解析 Git 文件名", comment: ""))
            }
            let x = String(UnicodeScalar(token[0])), y = String(UnicodeScalar(token[1]))
            var original: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                index += 1
                guard index < tokens.endIndex, let old = String(data: tokens[index], encoding: .utf8) else {
                    throw GitStatusError.failed(NSLocalizedString("无法解析 Git 文件名", comment: ""))
                }
                original = old
            }
            if let position = positions[name] {
                // git rm --cached 会对同一路径分别报告暂存删除与未跟踪，合并后仍可切换两侧差异。
                let previous = entries[position]
                guard (previous.indexStatus == "D" && x == "?") || (previous.isUntracked && x == "D") else {
                    throw GitStatusError.failed(NSLocalizedString("无法解析 Git 输出", comment: ""))
                }
                entries[position] = GitStatusEntry(path: name, originalPath: nil, indexStatus: "D", worktreeStatus: "?")
            } else {
                positions[name] = entries.count
                entries.append(GitStatusEntry(path: name, originalPath: original, indexStatus: x, worktreeStatus: y))
            }
            index += 1
        }
        return entries
    }
}

public struct GitFileComparison {
    public let left: ComparisonDocument
    public let right: ComparisonDocument
    public let result: FileComparisonResult

    public static func read(root: URL, entry: GitStatusEntry, scope: GitDiffScope) throws -> Self {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("FinderRight-git-diff-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty")
        try Data().write(to: empty)

        func blob(_ spec: String, name: String) throws -> URL {
            let info = try LocalGit.run(at: root, ["cat-file", "-s", spec])
            if info.status != 0 {
                throw GitStatusError.missingObject
            }
            guard let size = Int(String(decoding: info.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw GitStatusError.missingObject
            }
            guard size <= ComparisonDocument.maxBytes else { throw FileComparisonError.tooLarge }
            let file = directory.appendingPathComponent(name)
            try LocalGit.checked(at: root, ["cat-file", "blob", spec], limit: ComparisonDocument.maxBytes).write(to: file)
            return file
        }

        func checkMode(_ args: [String]) throws {
            let data = try LocalGit.checked(at: root, args)
            for token in data.split(separator: 0) {
                if token.starts(with: Array("120000 ".utf8)) || token.starts(with: Array("160000 ".utf8)) {
                    throw GitStatusError.unsupportedFile
                }
            }
        }
        try checkMode(["ls-files", "--stage", "-z", "--", entry.path])
        if scope == .staged && entry.indexStatus != "A" {
            try checkMode(["ls-tree", "-z", "HEAD", "--", entry.originalPath ?? entry.path])
        }

        func worktree() throws -> URL {
            let file = root.appendingPathComponent(entry.path).standardizedFileURL
            let resolved = file.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.path + "/"),
                  (try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else {
                throw GitStatusError.unsupportedFile
            }
            return file
        }

        let leftURL: URL, rightURL: URL
        switch scope {
        case .staged:
            guard entry.hasStaged else { throw GitStatusError.missingObject }
            leftURL = entry.indexStatus == "A" ? empty : try blob("HEAD:\(entry.originalPath ?? entry.path)", name: "head")
            rightURL = entry.indexStatus == "D" ? empty : try blob(":0:\(entry.path)", name: "index")
        case .unstaged:
            guard entry.hasUnstaged else { throw GitStatusError.missingObject }
            if entry.isUntracked { leftURL = empty }
            else if entry.isConflict {
                leftURL = ["DD", "DU", "UA"].contains(entry.indexStatus + entry.worktreeStatus) ? empty : try blob(":2:\(entry.path)", name: "ours")
            }
            else { leftURL = try blob(":0:\(entry.path)", name: "index") }
            let missingConflictFile = entry.isConflict && !fm.fileExists(atPath: root.appendingPathComponent(entry.path).path)
            rightURL = entry.worktreeStatus == "D" && !entry.isConflict || missingConflictFile ? empty : try worktree()
        }
        let left = try ComparisonDocument.read(leftURL), right = try ComparisonDocument.read(rightURL)
        return Self(left: left, right: right, result: try FileComparisonResult.compare(left, right))
    }
}

public struct GitCommitPreview {
    public let files: [String]
    fileprivate let signature: Data
}

public enum GitLocalAction {
    case stage([String]), unstage([String]), switchBranch(String), createBranch(String)
    case commit(message: String, preview: GitCommitPreview)
    case fetch, pull(rebase: Bool), push(remoteBranch: String?)
}

public enum GitOperationError: LocalizedError {
    case invalidPath, invalidBranch, emptyMessage, nothingStaged, conflicts, indexChanged, failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPath: return NSLocalizedString("请选择仓库内的文件", comment: "")
        case .invalidBranch: return NSLocalizedString("分支名称无效或本地分支不存在", comment: "")
        case .emptyMessage: return NSLocalizedString("请填写提交说明", comment: "")
        case .nothingStaged: return NSLocalizedString("没有已暂存的改动", comment: "")
        case .conflicts: return NSLocalizedString("尚有未解决的冲突，请解决后暂存", comment: "")
        case .indexChanged: return NSLocalizedString("分支或暂存区已变化，请重新查看后提交", comment: "")
        case .failed(let detail): return String(format: NSLocalizedString("Git 操作失败：%@", comment: ""), detail)
        }
    }
}

public enum GitLocalRepository {
    private static let mutationLock = NSLock()

    public static func prepareCommit(at root: URL) throws -> GitCommitPreview {
        let snapshot = try GitStatusSnapshot.read(at: root)
        guard !snapshot.entries.contains(where: \.isConflict) else { throw GitOperationError.conflicts }
        let raw = try LocalGit.checked(at: snapshot.root, ["diff", "--cached", "--raw", "--no-abbrev", "--no-renames", "--no-ext-diff", "--no-textconv", "-z"])
        let tokens = raw.split(separator: 0)
        guard !tokens.isEmpty else { throw GitOperationError.nothingStaged }
        guard tokens.count % 2 == 0 else { throw GitStatusError.missingObject }
        let paths = try stride(from: 1, to: tokens.count, by: 2).map { index -> String in
            guard let path = String(data: tokens[index], encoding: .utf8) else { throw GitOperationError.invalidPath }
            return path
        }
        let head = try LocalGit.run(at: snapshot.root, ["rev-parse", "--verify", "HEAD"])
        let ref = try LocalGit.run(at: snapshot.root, ["symbolic-ref", "--quiet", "HEAD"])
        return GitCommitPreview(files: paths, signature: head.data + Data([0]) + ref.data + Data([0]) + raw)
    }

    @discardableResult
    public static func perform(_ action: GitLocalAction, at input: URL) throws -> String {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let snapshot = try GitStatusSnapshot.read(at: input)
        let root = snapshot.root
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == input.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw GitOperationError.invalidPath
        }
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("FinderRight-git-action-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let arguments: [String]
        switch action {
        case .stage(let paths), .unstage(let paths):
            guard !paths.isEmpty else { throw GitOperationError.invalidPath }
            var records = Data()
            for path in Set(paths).sorted() {
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
                      !components.contains(".."), !components.contains("."), components.first != ".git" else {
                    throw GitOperationError.invalidPath
                }
                records.append(contentsOf: path.utf8)
                records.append(0)
            }
            let list = directory.appendingPathComponent("paths")
            try records.write(to: list)
            let options = ["--pathspec-from-file=\(list.path)", "--pathspec-file-nul"]
            if case .stage = action { arguments = ["add", "--all"] + options }
            else { arguments = ["reset", "--quiet"] + options }
        case .switchBranch(let name), .createBranch(let name):
            guard !name.hasPrefix("-"), !name.isEmpty,
                  try LocalGit.run(at: root, ["check-ref-format", "refs/heads/" + name]).status == 0 else {
                throw GitOperationError.invalidBranch
            }
            if case .switchBranch = action {
                guard snapshot.localBranches.contains(name) else { throw GitOperationError.invalidBranch }
                arguments = ["switch", "--no-guess", "--", name]
            } else { arguments = ["switch", "--no-guess", "-c", name] }
        case .commit(let message, let preview):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitOperationError.emptyMessage }
            let current = try prepareCommit(at: root)
            guard preview.signature == current.signature else { throw GitOperationError.indexChanged }
            let file = directory.appendingPathComponent("message")
            try message.write(to: file, atomically: true, encoding: .utf8)
            arguments = ["commit", "--file", file.path]
        case .fetch:
            arguments = ["fetch", "--prune"]
        case .pull(let rebase):
            // 真正的拉取：先取回远端，再合并（或变基）到当前分支。
            // 只 fetch 不会更新工作区，却提示「已拉取」会误导用户；显式传 --no-rebase 避免未配置 pull.rebase 时分叉直接报错。
            arguments = rebase ? ["pull", "--rebase", "--no-edit"] : ["pull", "--no-rebase", "--no-edit"]
        case .push(let remoteBranch):
            // 有上游就按 upstream 推；指定了分支才显式推送 origin/<branch>。
            if let branch = remoteBranch {
                arguments = ["push", "origin", branch]
            } else {
                arguments = ["push"]
            }
        }

        let beforeHead = revision(of: "HEAD", at: root)
        let beforeUpstream = revision(of: "@{upstream}", at: root)
        let result = try LocalGit.run(at: root, arguments, limit: 128 * 1024, writing: true)
        guard result.status == 0 else {
            let detail = [String(decoding: result.data, as: UTF8.self), result.error].filter { !$0.isEmpty }.joined(separator: "\n")
            throw GitOperationError.failed(formattedFailureDetail(detail, for: action))
        }
        return formattedSuccessMessage(for: action, at: root, snapshot: snapshot,
                                       beforeHead: beforeHead, beforeUpstream: beforeUpstream, stderr: result.error)
            ?? String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func revision(of ref: String, at root: URL) -> String? {
        guard let output = try? LocalGit.run(at: root, ["rev-parse", "--verify", ref]),
              output.status == 0 else { return nil }
        let value = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func commitCount(at root: URL, range: String) -> Int {
        guard let output = try? LocalGit.run(at: root, ["rev-list", "--count", range]),
              output.status == 0 else { return 0 }
        return Int(String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    private static func latestCommitSummary(at root: URL) -> String? {
        guard let output = try? LocalGit.run(at: root, ["log", "-1", "--format=%h %s"]),
              output.status == 0 else { return nil }
        let value = String(decoding: output.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func formattedSuccessMessage(
        for action: GitLocalAction,
        at root: URL,
        snapshot: GitStatusSnapshot,
        beforeHead: String?,
        beforeUpstream: String?,
        stderr: String
    ) -> String? {
        switch action {
        case .fetch:
            guard let after = try? GitStatusSnapshot.read(at: root) else {
                return NSLocalizedString("已获取远端引用", comment: "")
            }
            guard let target = after.upstream else {
                return NSLocalizedString("已获取远端引用", comment: "")
            }
            if after.behind > 0 && after.ahead > 0 {
                return String(format: NSLocalizedString("已获取远端（%@）：本地领先 %d 个提交，落后 %d 个提交", comment: ""),
                              target, after.ahead, after.behind)
            }
            if after.behind > 0 {
                return String(format: NSLocalizedString("已获取远端（%@）：发现 %d 个新提交可拉取", comment: ""),
                              target, after.behind)
            }
            if after.ahead > 0 {
                return String(format: NSLocalizedString("已获取远端（%@）：本地领先 %d 个提交可推送", comment: ""),
                              target, after.ahead)
            }
            return String(format: NSLocalizedString("已获取远端（%@）：已是最新，无新提交", comment: ""), target)

        case .pull(let rebase):
            let afterHead = revision(of: "HEAD", at: root)
            let target = snapshot.upstream ?? NSLocalizedString("远端", comment: "")
            if beforeHead != nil && beforeHead == afterHead {
                if snapshot.entries.isEmpty {
                    return String(format: NSLocalizedString("已是最新，远端无新提交（%@）", comment: ""), target)
                }
                return String(format: NSLocalizedString("远端无新提交（%@），当前仅有本地未提交改动，无冲突", comment: ""), target)
            }
            let afterUpstream = revision(of: "@{upstream}", at: root)
            let count: Int
            if rebase, let beforeUpstream, let afterUpstream, beforeUpstream != afterUpstream {
                count = commitCount(at: root, range: "\(beforeUpstream)..\(afterUpstream)")
            } else if let beforeHead {
                count = commitCount(at: root, range: "\(beforeHead)..HEAD")
            } else {
                count = commitCount(at: root, range: "HEAD")
            }
            let latest = latestCommitSummary(at: root)
            let hasLocalEdits = !snapshot.entries.isEmpty
            if count > 0, let latest {
                let format = hasLocalEdits
                    ? NSLocalizedString("已从 %@ 拉取 %d 个新提交，本地改动无冲突（最新：%@）", comment: "")
                    : NSLocalizedString("已从 %@ 拉取 %d 个新提交（最新：%@）", comment: "")
                return String(format: format, target, count, latest)
            }
            let format = hasLocalEdits
                ? NSLocalizedString("已从 %@ 拉取更新，本地改动无冲突", comment: "")
                : NSLocalizedString("已从 %@ 拉取更新", comment: "")
            return String(format: format, target)

        case .push(let remoteBranch):
            let target = remoteBranch.map { "origin/\($0)" } ?? snapshot.upstream ?? NSLocalizedString("远端", comment: "")
            let afterUpstream = revision(of: "@{upstream}", at: root)
            if stderr.contains("Everything up-to-date") || (beforeUpstream != nil && beforeUpstream == afterUpstream && snapshot.ahead == 0) {
                return String(format: NSLocalizedString("已是最新，无需推送（%@）", comment: ""), target)
            }
            if snapshot.ahead > 0 {
                return String(format: NSLocalizedString("已推送 %d 个提交到 %@", comment: ""), snapshot.ahead, target)
            }
            return String(format: NSLocalizedString("已推送到 %@", comment: ""), target)

        case .stage, .unstage, .switchBranch, .createBranch, .commit:
            return nil
        }
    }

    private static func formattedFailureDetail(_ detail: String, for action: GitLocalAction) -> String {
        switch action {
        case .pull, .fetch, .push:
            let lower = detail.lowercased()
            let summary: String?
            if lower.contains("conflict") || lower.contains("automatic merge failed") || lower.contains("could not apply") {
                summary = NSLocalizedString("拉取产生合并冲突，请在上方标为「冲突」的文件中处理后暂存并提交", comment: "")
            } else if lower.contains("would be overwritten")
                        || lower.contains("your local changes")
                        || lower.contains("please commit your changes or stash them")
                        || lower.contains("unstaged changes")
                        || lower.contains("uncommitted changes") {
                summary = NSLocalizedString("拉取已中止：本地未提交的改动会与远端更新冲突，请先提交或还原本地改动后再试", comment: "")
            } else if lower.contains("reconcile divergent branches") || lower.contains("diverging branches") {
                summary = NSLocalizedString("本地与远端提交已分叉，请使用变基拉取或在终端处理分叉", comment: "")
            } else if lower.contains("authentication failed")
                        || lower.contains("could not read from remote")
                        || lower.contains("permission denied")
                        || lower.contains("unable to access")
                        || lower.contains("failed to connect")
                        || lower.contains("timed out")
                        || lower.contains("operation too slow") {
                summary = NSLocalizedString("无法连接或验证远程仓库，请检查网络、代理或凭据设置", comment: "")
            } else {
                summary = nil
            }
            guard let summary else { return detail }
            return detail.isEmpty ? summary : "\(summary)\n\(detail)"
        case .stage, .unstage, .switchBranch, .createBranch, .commit:
            return detail
        }
    }
}
