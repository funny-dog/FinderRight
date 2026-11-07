import Foundation
import FinderRightKit

@main
struct GitPullPushChecks {
    static func main() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent("FinderRight-git-remote-\(UUID().uuidString)")
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }

        let remote = sandbox.appendingPathComponent("remote.git")
        let origin = sandbox.appendingPathComponent("origin")
        let peer = sandbox.appendingPathComponent("peer")

        @discardableResult
        func git(_ arguments: [String], at directory: URL, allowFailure: Bool = false) throws -> String {
            // 输出必须落在仓库之外，否则临时文件会出现在 git status 里干扰断言
            let output = sandbox.appendingPathComponent(".out-\(UUID().uuidString)")
            fm.createFile(atPath: output.path, contents: nil)
            defer { try? fm.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output)
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                            "-c", "commit.gpgSign=false", "-c", "user.name=Fixture",
                            "-c", "user.email=fixture@example.invalid"] + arguments,
                currentDirectoryURL: directory, standardOutput: handle)
            try handle.close()
            let text = (try? String(contentsOf: output, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            precondition(allowFailure || result.status == 0, "git \(arguments.joined(separator: " ")) 失败：\(result.stderr)")
            return text
        }
        func write(_ path: String, _ text: String, at directory: URL) throws {
            let file = directory.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        func expect(_ check: (Error) -> Bool = { _ in true }, _ work: () throws -> Void) {
            do { try work(); fatalError("应拒绝该操作") }
            catch { precondition(check(error), error.localizedDescription) }
        }
        func snapshot(_ directory: URL) throws -> GitStatusSnapshot {
            do { return try GitStatusSnapshot.read(at: directory) }
            catch { fatalError(error.localizedDescription) }
        }

        // 1. 建立一个带远端的仓库，并用 file:// 明确说明测试用的是本地协议
        try git(["init", "--bare", "-b", "main", remote.path], at: sandbox)
        try git(["init", "-b", "main", origin.path], at: sandbox)
        try write("a.txt", "first\n", at: origin)
        try git(["add", "."], at: origin)
        try git(["commit", "-m", "feat: 初始提交"], at: origin)
        try git(["remote", "add", "origin", "file://" + remote.path], at: origin)
        // 生产环境只放行 https/ssh/git；测试用 file 协议，因此这里显式配置一次，
        // 避免测试依赖用户全局 Git 配置，也证明拉取/推送走的是真实传输层。
        try git(["config", "protocol.file.allow", "always"], at: origin)

        let initial = try snapshot(origin)
        precondition(initial.hasRemote && initial.upstream == nil, "刚添加远端时还没有上游")

        // 2. 推送：没有上游时 push 会失败，界面据此提示先设置跟踪分支
        expect { _ = try GitLocalRepository.perform(.push(remoteBranch: nil), at: origin) }

        // 3. 显式推送分支后，上游才建立
        try GitLocalRepository.perform(.push(remoteBranch: "main"), at: origin)
        try git(["fetch", "origin"], at: origin)
        try git(["branch", "--set-upstream-to=origin/main", "main"], at: origin)
        let tracked = try snapshot(origin)
        precondition(tracked.upstream == "origin/main", "建立上游后应识别 origin/main")
        precondition(tracked.ahead == 0 && tracked.behind == 0, "建立上游后应显示同步")

        // 4. 本地多一次提交 → ahead = 1，推送后归零
        try write("a.txt", "second\n", at: origin)
        try git(["add", "."], at: origin)
        try git(["commit", "-m", "feat: 本地提交"], at: origin)
        let aheadOne = try snapshot(origin)
        precondition(aheadOne.ahead == 1 && aheadOne.behind == 0, "本地领先应统计为 ahead=1")
        try GitLocalRepository.perform(.push(remoteBranch: nil), at: origin)
        try git(["fetch", "origin"], at: origin)
        let afterPush = try snapshot(origin)
        precondition(afterPush.ahead == 0, "推送后不应再领先")

        // 5. 另一个克隆提交并推送 → 本地 behind = 1；拉取后工作区拿到新内容
        try git(["clone", remote.path, peer.path], at: sandbox)
        try git(["config", "user.name", "Fixture"], at: peer)
        try git(["config", "user.email", "fixture@example.invalid"], at: peer)
        try write("a.txt", "from peer\n", at: peer)
        try git(["add", "."], at: peer)
        try git(["commit", "-m", "feat: 远端提交"], at: peer)
        try git(["push", "origin", "main"], at: peer)

        let beforeFetch = try snapshot(origin)
        precondition(beforeFetch.behind == 0, "未 fetch 前还不知道落后")
        try git(["fetch", "origin"], at: origin)
        let afterFetch = try snapshot(origin)
        precondition(afterFetch.behind == 1, "fetch 后应显示落后 1 个提交")

        // 6. 真正的拉取：必须更新 HEAD 与工作区，而不是只 fetch
        try GitLocalRepository.perform(.pull(rebase: false), at: origin)
        let pulledText = try String(contentsOf: origin.appendingPathComponent("a.txt"), encoding: .utf8)
        precondition(pulledText == "from peer\n", "拉取必须把远端内容合并进工作区")
        let afterPull = try snapshot(origin)
        precondition(afterPull.ahead == 0 && afterPull.behind == 0 && afterPull.entries.isEmpty,
                     "拉取后应与远端同步且工作区干净")

        // 7. 冲突场景：拉取失败要报错，且不能静默丢数据
        try write("a.txt", "local conflict\n", at: origin)
        try git(["commit", "-am", "feat: 本地冲突"], at: origin)
        try write("a.txt", "remote conflict\n", at: peer)
        try git(["commit", "-am", "feat: 远端冲突"], at: peer)
        try git(["push", "origin", "main"], at: peer)
        expect({ $0.localizedDescription.contains("Git 操作失败") }) {
            _ = try GitLocalRepository.perform(.pull(rebase: false), at: origin)
        }
        let conflicted = try snapshot(origin)
        precondition(conflicted.entries.contains(where: \.isConflict) || conflicted.behind == 1,
                     "拉取冲突应保留可诊断状态，不能假装成功")
        try git(["merge", "--abort"], at: origin, allowFailure: true)
        try git(["reset", "--hard", "origin/main"], at: origin)

        // 8. 变基模式可用
        try write("a.txt", "remote rebase\n", at: peer)
        try git(["commit", "-am", "feat: 变基用远端提交"], at: peer)
        try git(["push", "origin", "main"], at: peer)
        try git(["fetch", "origin"], at: origin)
        try GitLocalRepository.perform(.pull(rebase: true), at: origin)
        let rebasedText = try String(contentsOf: origin.appendingPathComponent("a.txt"), encoding: .utf8)
        precondition(rebasedText == "remote rebase\n", "变基拉取后应更新工作区")

        print("✓ Git 远程：推送/拉取、ahead-behind 统计、真正更新工作区、冲突失败与变基通过")

        // 10. 带中文与空格的远端路径
        let spacedRemote = sandbox.appendingPathComponent("远端 仓库.git")
        try git(["init", "--bare", "-b", "main", spacedRemote.path], at: sandbox)
        let spacedOrigin = sandbox.appendingPathComponent("spaced")
        try git(["init", "-b", "main", spacedOrigin.path], at: sandbox)
        try write("b.txt", "b\n", at: spacedOrigin)
        try git(["add", "."], at: spacedOrigin)
        try git(["commit", "-m", "feat: 中文远端"], at: spacedOrigin)
        try git(["remote", "add", "origin", "file://" + spacedRemote.path], at: spacedOrigin)
        try git(["config", "protocol.file.allow", "always"], at: spacedOrigin)
        try GitLocalRepository.perform(.push(remoteBranch: "main"), at: spacedOrigin)
        let pushedLog = try git(["log", "-1", "--format=%s"], at: spacedRemote)
        precondition(pushedLog == "feat: 中文远端", "中文远端应收到提交")
        print("✓ Git 远程：含中文与空格的远端路径推送通过")
    }
}
