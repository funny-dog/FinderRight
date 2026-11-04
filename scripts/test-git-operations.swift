import Foundation
import FinderRightKit

@main
struct GitOperationChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FinderRight-git-operations-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        @discardableResult
        func git(_ args: [String]) throws -> String {
            let output = root.appendingPathComponent(".output-\(UUID().uuidString)")
            fm.createFile(atPath: output.path, contents: nil)
            defer { try? fm.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output)
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + args,
                currentDirectoryURL: root, standardOutput: handle)
            try handle.close()
            precondition(result.status == 0, result.stderr)
            return try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ path: String, _ text: String) throws {
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func expect(_ check: (Error) -> Bool = { _ in true }, _ work: () throws -> Void) {
            do { try work(); fatalError("应拒绝该操作") } catch { precondition(check(error), error.localizedDescription) }
        }
        func check(_ condition: Bool) { precondition(condition) }
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "commit.gpgSign", "false"])
        try git(["config", "core.hooksPath", root.appendingPathComponent(".git/hooks").path])
        let special = "src/中文 space\n:(glob)*.txt"
        try write(special, "staged\n")
        try write("other.txt", "other\n")
        try GitLocalRepository.perform(.stage([special]), at: root)
        var snapshot = try GitStatusSnapshot.read(at: root)
        precondition(snapshot.entries.first { $0.path == special }?.hasStaged == true)
        precondition(snapshot.entries.first { $0.path == "other.txt" }?.isUntracked == true)
        try write(special, "working\n")
        try GitLocalRepository.perform(.unstage([special]), at: root)
        snapshot = try GitStatusSnapshot.read(at: root)
        precondition(!snapshot.entries.contains(where: \.hasStaged))
        check(try String(contentsOf: root.appendingPathComponent(special), encoding: .utf8) == "working\n")
        try write(special, "staged\n")
        try GitLocalRepository.perform(.stage([special]), at: root)
        try write(special, "working\n")
        let preview = try GitLocalRepository.prepareCommit(at: root)
        precondition(preview.files == [special])
        let message = "feat: 首次提交\n\n保留正文和特殊字符 $() `literal`"
        try GitLocalRepository.perform(.commit(message: message, preview: preview), at: root)
        check(try git(["show", "HEAD:" + special]) == "staged")
        check(try git(["log", "-1", "--format=%B"]) == message)
        check(try String(contentsOf: root.appendingPathComponent(special), encoding: .utf8) == "working\n")
        print("✓ Git 操作：特殊路径按文件暂存、未首次提交时取消暂存、仅提交暂存内容与多行说明通过")

        try GitLocalRepository.perform(.createBranch("feature/中文"), at: root)
        precondition(trySnapshot(root).branch == "feature/中文")
        check(try String(contentsOf: root.appendingPathComponent(special), encoding: .utf8) == "working\n")
        try GitLocalRepository.perform(.stage([special]), at: root)
        try GitLocalRepository.perform(.commit(message: "feat: 分支修改", preview: GitLocalRepository.prepareCommit(at: root)), at: root)
        try GitLocalRepository.perform(.switchBranch("main"), at: root)
        try write(special, "local WIP\n")
        expect { _ = try GitLocalRepository.perform(.switchBranch("feature/中文"), at: root) }
        precondition(trySnapshot(root).branch == "main")
        check(try String(contentsOf: root.appendingPathComponent(special), encoding: .utf8) == "local WIP\n")
        try write(special, "staged\n")
        try GitLocalRepository.perform(.switchBranch("feature/中文"), at: root)
        precondition(trySnapshot(root).localBranches.contains("main"))
        for invalid in ["--detach", "../outside", "@{-1}"] {
            expect { _ = try GitLocalRepository.perform(.createBranch(invalid), at: root) }
        }
        expect { _ = try GitLocalRepository.perform(.switchBranch("origin/missing"), at: root) }
        expect { _ = try GitLocalRepository.perform(.stage(["../outside"]), at: root) }
        expect { _ = try GitLocalRepository.perform(.unstage(["."]), at: root) }
        print("✓ Git 操作：创建切换本地分支、阻止覆盖本地改动、无效分支和越界路径拒绝通过")

        let renamed = "src/rename \n*.txt"
        try fm.moveItem(at: root.appendingPathComponent(special), to: root.appendingPathComponent(renamed))
        try GitLocalRepository.perform(.stage([special, renamed]), at: root)
        snapshot = try GitStatusSnapshot.read(at: root)
        precondition(snapshot.entries.first { $0.path == renamed }?.originalPath == special)
        try GitLocalRepository.perform(.unstage([special, renamed]), at: root)
        precondition(!trySnapshot(root).entries.contains(where: \.hasStaged))
        precondition(fm.fileExists(atPath: root.appendingPathComponent(renamed).path))
        precondition(!fm.fileExists(atPath: root.appendingPathComponent(special).path))
        try GitLocalRepository.perform(.stage([special, renamed]), at: root)
        let stale = try GitLocalRepository.prepareCommit(at: root)
        let headBefore = try git(["rev-parse", "HEAD"])
        try GitLocalRepository.perform(.stage(["other.txt"]), at: root)
        expect({ if case GitOperationError.indexChanged = $0 { return true }; return false }) {
            _ = try GitLocalRepository.perform(.commit(message: "stale", preview: stale), at: root)
        }
        let refreshed = try GitLocalRepository.prepareCommit(at: root)
        try GitLocalRepository.perform(.createBranch("next"), at: root)
        expect({ if case GitOperationError.indexChanged = $0 { return true }; return false }) {
            _ = try GitLocalRepository.perform(.commit(message: "wrong branch", preview: refreshed), at: root)
        }
        check(try git(["rev-parse", "HEAD"]) == headBefore)
        let current = try GitLocalRepository.prepareCommit(at: root)
        expect { _ = try GitLocalRepository.perform(.commit(message: " \n ", preview: current), at: root) }
        print("✓ Git 操作：重命名取消暂存保留工作区、暂存区／分支变化时拒绝旧提交预览通过")

        let hook = root.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'fixture hook rejected this commit'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        expect({ $0.localizedDescription.contains("fixture hook rejected") }) {
            _ = try GitLocalRepository.perform(.commit(message: "hook", preview: current), at: root)
        }
        check(try git(["rev-parse", "HEAD"]) == headBefore)
        try fm.removeItem(at: hook)
        let signer = root.appendingPathComponent(".git/fixture-gpg")
        try "#!/bin/sh\necho 'fixture signing failed' >&2\nexit 1\n".write(to: signer, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: signer.path)
        try git(["config", "commit.gpgSign", "true"])
        try git(["config", "gpg.format", "openpgp"])
        try git(["config", "gpg.program", signer.path])
        expect({ $0.localizedDescription.contains("fixture signing failed") }) {
            _ = try GitLocalRepository.perform(.commit(message: "signed", preview: current), at: root)
        }
        check(try git(["rev-parse", "HEAD"]) == headBefore)
        try git(["config", "commit.gpgSign", "false"])
        try git(["config", "user.name", ""])
        expect { _ = try GitLocalRepository.perform(.commit(message: "identity", preview: current), at: root) }
        check(try git(["rev-parse", "HEAD"]) == headBefore)
        try git(["config", "user.name", "Fixture"])
        try GitLocalRepository.perform(.commit(message: "feat: 最终提交", preview: current), at: root)
        precondition(trySnapshot(root).entries.isEmpty)
        print("✓ Git 操作：遵循 hooks、签名和身份配置，失败保留暂存区，重新提交成功通过")
    }

    private static func trySnapshot(_ root: URL) -> GitStatusSnapshot {
        do { return try GitStatusSnapshot.read(at: root) }
        catch { fatalError(error.localizedDescription) }
    }
}
