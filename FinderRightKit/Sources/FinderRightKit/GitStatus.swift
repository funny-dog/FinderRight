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

private enum LocalGit {
    private final class ErrorOutput { var data = Data() }
    private final class TimeoutFlag {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); value = true; lock.unlock() }
        var fired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    struct Output { let status: Int32; let data: Data; let error: String }

    static func run(at root: URL, _ arguments: [String], limit: Int = 8 * 1024 * 1024, writing: Bool = false) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "--literal-pathspecs", "-c", "core.fsmonitor=false",
                             "-c", "core.untrackedCache=false", "-c", "protocol.allow=never", "-C", root.path] + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_NO_LAZY_FETCH"] = "1"
        environment["GIT_ALLOW_PROTOCOL"] = ""
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        if writing {
            environment["GIT_EDITOR"] = ":"
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
        var entries: [GitStatusEntry] = []
        var positions: [String: Int] = [:]
        var index = 1
        while index < tokens.count {
            let token = Array(tokens[index])
            guard token.count >= 4, token[2] == 32, let name = String(bytes: token.dropFirst(3), encoding: .utf8) else {
                throw GitStatusError.failed(NSLocalizedString("无法解析 Git 文件名", comment: ""))
            }
            let x = String(UnicodeScalar(token[0])), y = String(UnicodeScalar(token[1]))
            var original: String?
            if x == "R" || x == "C" || y == "R" || y == "C" {
                index += 1
                guard index < tokens.count, let old = String(data: tokens[index], encoding: .utf8) else {
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
        let refs = try LocalGit.checked(at: root, ["for-each-ref", "--format=%(refname:strip=2)", "refs/heads/"])
        let branches = String(decoding: refs, as: UTF8.self).split(separator: "\n").map(String.init)
        return Self(root: root, branch: branch, localBranches: branches, entries: entries)
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
    case pull(rebase: Bool), push(remoteBranch: String?)
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
        case .pull(let rebase):
            // 使用 fetch --prune 作为基础拉取
            arguments = [rebase ? "pull" : "fetch", "--prune"]
        case .push(let remoteBranch):
            // 直接 push 到 origin
            if let branch = remoteBranch {
                arguments = ["push", "origin", branch]
            } else {
                arguments = ["push"]
            }
        }
        
        let result = try LocalGit.run(at: root, arguments, limit: 128 * 1024, writing: true)
        guard result.status == 0 else {
            let detail = [String(decoding: result.data, as: UTF8.self), result.error].filter { !$0.isEmpty }.joined(separator: "\n")
            throw GitOperationError.failed(detail)
        }
        return String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
