import Foundation
import FinderRightKit

@main
struct GitStatusChecks {
    static func main() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("FinderRight-git-check-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("repo with space\n")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        @discardableResult
        func git(_ args: [String], at directory: URL? = nil, allowFailure: Bool = false) throws -> Int32 {
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                            "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"] + args,
                currentDirectoryURL: directory ?? root)
            precondition(allowFailure || result.status == 0, result.stderr)
            return result.status
        }
        func write(_ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func entry(_ path: String, in snapshot: GitStatusSnapshot) -> GitStatusEntry {
            guard let value = snapshot.entries.first(where: { $0.path == path }) else { fatalError("缺少状态：\(path)") }
            return value
        }
        func check(_ value: Bool) { precondition(value) }
        func expectFailure(_ work: () throws -> Void) {
            do { try work(); fatalError("应拒绝不支持的输入") } catch { }
        }
        try git(["init", "-b", "main"])
        let unborn = try GitStatusSnapshot.read(at: root)
        precondition(unborn.branch == "main" && unborn.entries.isEmpty)
        try write("first.txt", "first\n")
        try git(["add", "."])
        let initial = try GitStatusSnapshot.read(at: root)
        let added = try GitFileComparison.read(root: root, entry: entry("first.txt", in: initial), scope: .staged)
        precondition(added.left.text.isEmpty && added.right.text == "first\n")
        let special = "src/中文 space\n--.txt"
        try write(special, "base\n")
        try write("delete.txt", "delete\n")
        try write("cached.txt", "cached\n")
        try write("old name.txt", "renamed\n")
        try write(".gitattributes", "*.txt diff=fixture\n")
        try write(".gitignore", "ignored/\n")
        try git(["add", "."])
        try git(["commit", "-m", "fixture"])
        check(try GitStatusSnapshot.read(at: root).entries.isEmpty)
        try write(special, "staged\n")
        try git(["add", "--", special])
        try write(special, "working\n")
        let renamed = "新 name\n.txt"
        try git(["mv", "--", "old name.txt", renamed])
        try fm.removeItem(at: root.appendingPathComponent("delete.txt"))
        try write("new/nested.txt", "new\n")
        try write("ignored/hidden.txt", "hidden\n")
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary.bin"))
        let marker = sandbox.appendingPathComponent("external-was-run")
        let helper = sandbox.appendingPathComponent("external.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        try git(["config", "core.fsmonitor", helper.path])
        try git(["config", "diff.external", helper.path])
        try git(["config", "diff.fixture.textconv", helper.path])
        let indexBefore = try Data(contentsOf: root.appendingPathComponent(".git/index"))
        let fileBefore = try Data(contentsOf: root.appendingPathComponent(special))
        let snapshot = try GitStatusSnapshot.read(at: root.appendingPathComponent("src"))
        precondition(snapshot.root.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        let mm = entry(special, in: snapshot)
        precondition(mm.indexStatus == "M" && mm.worktreeStatus == "M" && mm.hasStaged && mm.hasUnstaged)
        let staged = try GitFileComparison.read(root: root, entry: mm, scope: .staged)
        let unstaged = try GitFileComparison.read(root: root, entry: mm, scope: .unstaged)
        precondition(staged.left.text == "base\n" && staged.right.text == "staged\n")
        precondition(unstaged.left.text == "staged\n" && unstaged.right.text == "working\n")
        let rename = entry(renamed, in: snapshot)
        precondition(rename.originalPath == "old name.txt" && rename.indexStatus == "R")
        check(try GitFileComparison.read(root: root, entry: rename, scope: .staged).left.text == "renamed\n")
        let deleted = try GitFileComparison.read(root: root, entry: entry("delete.txt", in: snapshot), scope: .unstaged)
        precondition(deleted.left.text == "delete\n" && deleted.right.text.isEmpty)
        let untrackedEntry = entry("new/nested.txt", in: snapshot)
        precondition(untrackedEntry.isUntracked && untrackedEntry.hasUnstaged && !untrackedEntry.hasStaged)
        let untracked = try GitFileComparison.read(root: root, entry: untrackedEntry, scope: .unstaged)
        precondition(untracked.left.text.isEmpty && untracked.right.text == "new\n")
        precondition(!snapshot.entries.contains { $0.path.hasPrefix("ignored/") })
        expectFailure { _ = try GitFileComparison.read(root: root, entry: entry("binary.bin", in: snapshot), scope: .unstaged) }
        check(try Data(contentsOf: root.appendingPathComponent(".git/index")) == indexBefore)
        check(try Data(contentsOf: root.appendingPathComponent(special)) == fileBefore)
        precondition(!fm.fileExists(atPath: marker.path), "读取 Git 不得运行 fsmonitor、external diff 或 textconv")
        print("✓ Git：未提交仓库、MM、重命名特殊文件名、删除、未跟踪目录、二进制限制与只读检查通过")

        try git(["rm", "--cached", "cached.txt"])
        let removedFromIndex = try GitStatusSnapshot.read(at: root)
        precondition(removedFromIndex.entries.filter { $0.path == "cached.txt" }.count == 1)
        let removed = entry("cached.txt", in: removedFromIndex)
        precondition(removed.hasStaged && removed.hasUnstaged && removed.isUntracked)
        let removal = try GitFileComparison.read(root: root, entry: removed, scope: .staged)
        let remaining = try GitFileComparison.read(root: root, entry: removed, scope: .unstaged)
        precondition(removal.left.text == "cached\n" && removal.right.text.isEmpty)
        precondition(remaining.left.text.isEmpty && remaining.right.text == "cached\n")
        try git(["add", "--", "delete.txt"])
        let stagedDeletion = try GitStatusSnapshot.read(at: root)
        let stagedDeleted = try GitFileComparison.read(root: root, entry: entry("delete.txt", in: stagedDeletion), scope: .staged)
        precondition(stagedDeleted.left.text == "delete\n" && stagedDeleted.right.text.isEmpty)
        try write("first.txt", "first\r\n")
        let endings = try GitStatusSnapshot.read(at: root)
        let endingDiff = try GitFileComparison.read(root: root, entry: entry("first.txt", in: endings), scope: .unstaged)
        precondition(endingDiff.result.differentLineEndings && endingDiff.result.additions == 0)
        try write("first.txt", "first\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("first.txt").path)
        let permissions = try GitStatusSnapshot.read(at: root)
        let permissionDiff = try GitFileComparison.read(root: root, entry: entry("first.txt", in: permissions), scope: .unstaged)
        precondition(permissionDiff.result.additions == 0 && permissionDiff.result.deletions == 0)
        try write("link-target.txt", "target\n")
        try fm.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: root.appendingPathComponent("link-target.txt"))
        let withLink = try GitStatusSnapshot.read(at: root)
        expectFailure { _ = try GitFileComparison.read(root: root, entry: entry("link.txt", in: withLink), scope: .unstaged) }
        try Data(repeating: 65, count: ComparisonDocument.maxBytes + 1).write(to: root.appendingPathComponent("large.txt"))
        let withLarge = try GitStatusSnapshot.read(at: root)
        expectFailure { _ = try GitFileComparison.read(root: root, entry: entry("large.txt", in: withLarge), scope: .unstaged) }
        expectFailure { _ = try GitStatusSnapshot.read(at: sandbox) }
        try git(["reset", "--hard", "HEAD"])
        try fm.removeItem(at: root.appendingPathComponent("new"))
        try fm.removeItem(at: root.appendingPathComponent("binary.bin"))
        try fm.removeItem(at: root.appendingPathComponent("link.txt"))
        try fm.removeItem(at: root.appendingPathComponent("link-target.txt"))
        try fm.removeItem(at: root.appendingPathComponent("large.txt"))
        try git(["checkout", "--detach"])
        check(try GitStatusSnapshot.read(at: root).branch.contains("HEAD"))
        try git(["checkout", "main"])
        let worktree = sandbox.appendingPathComponent("worktree")
        try git(["worktree", "add", "-b", "linked", worktree.path])
        check(try GitStatusSnapshot.read(at: worktree).branch == "linked")
        print("✓ Git：链接、过大文件、无仓库、分离 HEAD 与 worktree 检查通过")

        try git(["checkout", "-b", "other"])
        try write("first.txt", "theirs\n")
        try git(["add", "first.txt"])
        try git(["commit", "-m", "other"])
        try git(["checkout", "main"])
        try write("first.txt", "ours\n")
        try git(["add", "first.txt"])
        try git(["commit", "-m", "main"])
        check(try git(["merge", "other"], allowFailure: true) != 0)
        let conflicted = try GitStatusSnapshot.read(at: root)
        let conflict = entry("first.txt", in: conflicted)
        precondition(conflict.isConflict && conflict.hasUnstaged)
        let diff = try GitFileComparison.read(root: root, entry: conflict, scope: .unstaged)
        precondition(diff.left.text == "ours\n" && diff.right.text.contains("<<<<<<<"))
        try git(["merge", "--abort"])
        try git(["rm", "first.txt"])
        try git(["commit", "-m", "delete ours"])
        check(try git(["merge", "other"], allowFailure: true) != 0)
        let deletedConflict = try GitStatusSnapshot.read(at: root)
        let deletedOurs = entry("first.txt", in: deletedConflict)
        precondition(deletedOurs.isConflict && deletedOurs.indexStatus == "D")
        let deletedConflictDiff = try GitFileComparison.read(root: root, entry: deletedOurs, scope: .unstaged)
        precondition(deletedConflictDiff.left.text.isEmpty && deletedConflictDiff.right.text == "theirs\n")
        print("✓ Git：暂存删除并保留文件、换行与权限变化、内容冲突与我方删除冲突通过")
    }
}
