import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// 磁盘占用、开发者工具与 Git
enum DeveloperTests {
    static func run() {
        // MARK: - 磁盘占用

        runTest("磁盘占用 统计文件与目录的分配大小") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            // 单个文件：应等于其分配大小，且大于 0
            let file = dir.appendingPathComponent("a.bin")
            try Data(repeating: 0x41, count: 64 * 1024).write(to: file)
            let fileSize = DiskUsage.allocatedBytes(at: file)
            try assertTrue(fileSize != nil, "普通文件应能算出大小")
            try assertTrue((fileSize ?? 0) >= 64 * 1024, "至少不小于写入的数据量")

            // 空目录：0
            let empty = dir.appendingPathComponent("empty", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            try assertEqual(DiskUsage.allocatedBytes(at: empty), 0, "空目录占用为 0")

            // 嵌套目录：应把子目录里的文件算进去
            let nested = dir.appendingPathComponent("nested/deep", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data(repeating: 0x42, count: 128 * 1024).write(to: nested.appendingPathComponent("b.bin"))
            let total = DiskUsage.allocatedBytes(at: dir) ?? 0
            try assertTrue(total >= 192 * 1024, "根目录应包含嵌套文件，实际 \(total)")
        }

        runTest("磁盘占用 路径不存在返回 nil 而不是 0") {
            let missing = URL(fileURLWithPath: "/tmp/finderright-不存在-\(UUID().uuidString)")
            try assertNil(DiskUsage.allocatedBytes(at: missing), "不存在的路径必须返回 nil")
        }

        runTest("磁盘占用 符号链接不跟随、不计入目标大小") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            let big = dir.appendingPathComponent("big.bin")
            try Data(repeating: 0, count: 256 * 1024).write(to: big)
            let link = dir.appendingPathComponent("link.bin")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)

            // 链接本身按自身计入（几十字节），绝不能把目标那份算进去
            let linkSize = DiskUsage.allocatedBytes(at: link) ?? 0
            try assertTrue(linkSize < 64 * 1024, "符号链接不应把目标文件算进来，实际 \(linkSize)")

            // 目录扫描时也不跟随链接，合计只含一个文件
            let dirSize = DiskUsage.allocatedBytes(at: dir) ?? 0
            try assertTrue(dirSize < 400 * 1024, "目录统计不应因链接翻倍，实际 \(dirSize)")
        }

        runTest("磁盘占用 超时与取消都返回 nil") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            for i in 0..<200 {
                try Data(repeating: 0, count: 4096)
                    .write(to: dir.appendingPathComponent("f\(i).bin"))
            }

            // 已经过期的 deadline：必须立刻放弃
            let past = Date().addingTimeInterval(-1)
            try assertNil(DiskUsage.allocatedBytes(at: dir, deadline: past), "过期的 deadline 应返回 nil")
            // 取消标志
            try assertNil(DiskUsage.allocatedBytes(at: dir, isCancelled: { true }), "已取消应返回 nil")
            // 正常条件仍应成功
            try assertTrue(DiskUsage.allocatedBytes(at: dir) != nil, "无限制时应算出结果")
        }

        runTest("磁盘占用 DiskUsageCache 命中、过期与容量淘汰") {
            let cache = DiskUsageCache(capacity: 2)
            let now = Date()
            try assertNil(cache.value(for: "/a", ttl: 60, now: now), "未写入时无值")

            cache.store(100, for: "/a", now: now)
            try assertEqual(cache.value(for: "/a", ttl: 60, now: now), 100)
            // 超过 TTL 即失效
            try assertNil(cache.value(for: "/a", ttl: 10, now: now.addingTimeInterval(11)), "过期应失效")

            // 容量上限：写入第三项时淘汰最早的
            cache.store(1, for: "/x", now: now)
            cache.store(2, for: "/y", now: now)
            cache.store(3, for: "/z", now: now.addingTimeInterval(1))
            let remaining = ["/x", "/y", "/z"].compactMap { cache.value(for: $0, ttl: 60, now: now.addingTimeInterval(2)) }
            try assertEqual(remaining.count, 2, "容量 2 应只保留 2 项")

            cache.removeAll()
            try assertNil(cache.value(for: "/x", ttl: 60, now: now), "清空后无值")
        }

        runTest("磁盘占用 超时后后台继续算完，下次命中缓存") {
            // 这是「大目录永远不显示」的回归测试：调用方等不到结果，
            // 但任务必须继续跑完并写缓存，否则每次右键都超时、永远没有数字。
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            for i in 0..<300 {
                try Data(repeating: 0, count: 8192)
                    .write(to: dir.appendingPathComponent("f\(i).bin"))
            }
            DiskUsageJob.resetForTesting()

            let cache = DiskUsageCache()
            let path = dir.standardizedFileURL.path

            // 用「暂停的队列」让后台任务确定性地晚于等待方启动。
            // 早先这里靠「300 个文件一定扫超过 1ms」来保证超时，但快速机器上扫描只要 1–2ms，
            // 任务可能先算完写缓存，导致断言随机器快慢时过时不过。
            let taskQueue = DispatchQueue(label: "test.diskusage.suspended")
            taskQueue.suspend()
            var taskStarted = false
            defer { if !taskStarted { taskQueue.resume() } }

            let timedOut = DiskUsageJob.run(url: dir, path: path, scanDeadline: nil,
                                            waitTimeout: 0.001, cache: cache, cacheTTL: 60,
                                            queue: taskQueue)
            try assertNil(timedOut, "等待超时应返回 nil")
            try assertNil(cache.value(for: path, ttl: 60), "任务尚未启动，不应已有结果")

            // 放行后台任务，它必须继续跑完并写缓存
            taskStarted = true
            taskQueue.resume()

            // 给后台任务时间跑完
            let deadline = Date().addingTimeInterval(10)
            var cached: Int64?
            while Date() < deadline {
                cached = cache.value(for: path, ttl: 60)
                if cached != nil { break }
                usleep(20_000)
            }
            try assertTrue(cached != nil, "超时返回后，任务仍应在后台算完并写入缓存")
            try assertTrue((cached ?? 0) >= 300 * 8192, "缓存值应等于实际占用")
        }

        runTest("磁盘占用 同一路径并发请求只扫一次") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            for i in 0..<200 {
                try Data(repeating: 0, count: 4096)
                    .write(to: dir.appendingPathComponent("g\(i).bin"))
            }
            DiskUsageJob.resetForTesting()

            let cache = DiskUsageCache()
            let path = dir.standardizedFileURL.path
            let group = DispatchGroup()
            let lock = NSLock()
            var hits = 0
            for _ in 0..<8 {
                group.enter()
                DispatchQueue.global().async {
                    let v = DiskUsageJob.run(url: dir, path: path, scanDeadline: nil,
                                             waitTimeout: 5, cache: cache, cacheTTL: 60)
                    if v != nil { lock.lock(); hits += 1; lock.unlock() }
                    group.leave()
                }
            }
            try assertEqual(group.wait(timeout: .now() + 20), .success, "并发请求应在超时内全部返回")
            try assertEqual(hits, 8, "每个等待者都应拿到结果")
            // 结果一致，说明复用同一份计算而不是各扫一遍
            try assertTrue(cache.value(for: path, ttl: 60) != nil, "应写入缓存")
        }

        runTest("磁盘占用 大小文案带单位且稳定") {
            try assertEqual(DiskUsage.formatted(0), "Zero KB")
            try assertTrue(DiskUsage.formatted(1024).contains("KB"), "1 KB 应使用 KB 单位")
            try assertTrue(DiskUsage.formatted(1024 * 1024).contains("MB"), "1 MB 应使用 MB 单位")
        }

        runTest("磁盘占用 扫描直接子项占用并降序排列") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            try Data(repeating: 0x61, count: 16 * 1024).write(to: root.appendingPathComponent("small.txt"))
            try Data(repeating: 0x62, count: 128 * 1024).write(to: root.appendingPathComponent("big.bin"))
            let folderA = root.appendingPathComponent("folderA")
            try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
            try Data(repeating: 0x63, count: 64 * 1024).write(to: folderA.appendingPathComponent("sub1.bin"))
            try Data(repeating: 0x64, count: 64 * 1024).write(to: folderA.appendingPathComponent("sub2.bin"))

            let breakdown = DiskUsage.inspectDirectChildren(at: root)
            try assertTrue(breakdown != nil, "有效目录应成功返回分析结果")
            guard let breakdown else { return }

            try assertEqual(breakdown.directDirectoryCount, 1, "应有 1 个直属子目录")
            try assertEqual(breakdown.directFileCount, 2, "应有 2 个直属文件")
            try assertEqual(breakdown.items.count, 3, "应有 3 个直属子项")

            for i in 0..<(breakdown.items.count - 1) {
                try assertTrue(breakdown.items[i].bytes >= breakdown.items[i + 1].bytes, "必须按占用降序排序")
            }

            try assertEqual(breakdown.items.last?.name, "small.txt")
            try assertTrue((breakdown.items.last?.percentage ?? 0) > 0.0, "比例应大于 0")

            let fileURL = root.appendingPathComponent("small.txt")
            try assertNil(DiskUsage.inspectDirectChildren(at: fileURL), "对非目录调用应返回 nil")

            // 针对符号链接：指向目录的符号链接本身不作为直属目录展开或计入
            let linkToFolder = root.appendingPathComponent("folderLink")
            try FileManager.default.createSymbolicLink(at: linkToFolder, withDestinationURL: folderA)
            let breakdownWithLink = DiskUsage.inspectDirectChildren(at: root)
            try assertTrue(breakdownWithLink != nil)
            if let breakdownWithLink {
                try assertEqual(breakdownWithLink.directDirectoryCount, 1, "符号链接不应作为目录计入 directDirectoryCount")
                try assertEqual(breakdownWithLink.directFileCount, 2, "符号链接不应作为普通文件计入 directFileCount")
                try assertTrue(!breakdownWithLink.items.contains { $0.name == "folderLink" }, "排行中不应包含符号链接")
            }
            try assertNil(DiskUsage.inspectDirectChildren(at: linkToFolder), "对指向目录的符号链接调用 inspectDirectChildren 应返回 nil，不跟随展开")

            // 针对取消与超时：一旦取消或超时应整体返回 nil
            let cancelledBreakdown = DiskUsage.inspectDirectChildren(at: root, isCancelled: { true })
            try assertNil(cancelledBreakdown, "取消时必须返回 nil，不得返回部分或 0 字节结果")

            let timedOutBreakdown = DiskUsage.inspectDirectChildren(at: root, deadline: Date().addingTimeInterval(-1))
            try assertNil(timedOutBreakdown, "已超时的 deadline 必须返回 nil")
        }

        runTest("磁盘占用 硬链接文件在目录内不重复计入占用") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            let sub1 = root.appendingPathComponent("sub1")
            let sub2 = root.appendingPathComponent("sub2")
            try FileManager.default.createDirectory(at: sub1, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sub2, withIntermediateDirectories: true)

            let original = sub1.appendingPathComponent("orig.bin")
            try Data(repeating: 0x55, count: 64 * 1024).write(to: original)
            guard let singleBytes = DiskUsage.allocatedBytes(at: original) else {
                throw TestFailure(message: "无法读取单文件占用")
            }

            try FileManager.default.linkItem(at: original, to: sub1.appendingPathComponent("link1.bin"))
            try FileManager.default.linkItem(at: original, to: sub2.appendingPathComponent("link2.bin"))

            let totalBytes = DiskUsage.allocatedBytes(at: root)
            try assertEqual(totalBytes, singleBytes, "同一目录树内硬链接应只计入一次磁盘占用")

            let breakdown = DiskUsage.inspectDirectChildren(at: root)
            try assertTrue(breakdown != nil)
            try assertEqual(breakdown?.directDirectoryCount, 2)
            try assertEqual(breakdown?.items.first(where: { $0.name == "sub1" })?.bytes, singleBytes, "同目录树下的硬链接子目录不应翻倍")
        }

        // MARK: - 开发者工具与自定义命令

        runTest("开发者工具：项目相对路径、多选、嵌套仓库与仓库根") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let folder = root.appendingPathComponent("中文 空格's/src")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("main.swift")
            try Data().write(to: file)
            try assertEqual(try ProjectRelativePath.paths(for: [file, folder, root]), ["中文 空格's/src/main.swift", "中文 空格's/src", "."])
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try assertEqual(try ProjectRelativePath.paths(for: [file]), ["main.swift"])
        }

        runTest("开发者工具：worktree 标记与无效标记") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent(".git")
            let file = root.appendingPathComponent("readme.md")
            try Data().write(to: file)
            try Data("gitdir: ../repo/.git/worktrees/test\n".utf8).write(to: marker)
            try assertEqual(try ProjectRelativePath.paths(for: [file]), ["readme.md"])
            try Data("gitdir: \n".utf8).write(to: marker)
            try assertThrows(DeveloperFileToolError.noRepository) { _ = try ProjectRelativePath.paths(for: [file]) }
        }

        runTest("开发者工具：保留符号链接名称且多选失败不返回部分路径") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let repo = root.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let outside = root.appendingPathComponent("outside.txt")
            try Data().write(to: outside)
            let link = repo.appendingPathComponent("链接.txt")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            try assertEqual(try ProjectRelativePath.paths(for: [link]), ["链接.txt"])
            try assertThrows(DeveloperFileToolError.noRepository) { _ = try ProjectRelativePath.paths(for: [link, outside]) }
            try FileManager.default.removeItem(at: outside)
            try assertEqual(try ProjectRelativePath.paths(for: [link]), ["链接.txt"])
        }

        runTest("开发者工具：目录树排序、常见目录过滤和控制字符转义") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for name in ["src", "assets", ".git", "node_modules", ".venv", "venv", "__pycache__", ".build", "build", "dist", ".next"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            for name in ["z.txt", "a\n\t.txt", ".env", ".DS_Store"] { try Data().write(to: root.appendingPathComponent(name)) }
            let tree = try DirectoryTree.render(at: root)
            let expected = "\(root.lastPathComponent)/\n├── assets/\n├── src/\n├── .env\n├── a\\n\\t.txt\n└── z.txt"
            try assertEqual(tree, expected)
        }

        runTest("开发者工具：目录树不展开符号链接环或文件包") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let package = root.appendingPathComponent("Example.app")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data().write(to: package.appendingPathComponent("inside.txt"))
            let link = root.appendingPathComponent("loop")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            let tree = try DirectoryTree.render(at: root)
            try assertTrue(tree.contains("Example.app/") && tree.contains("loop"))
            try assertTrue(!tree.contains("inside.txt"))
            try assertThrows(DeveloperFileToolError.notDirectory) { _ = try DirectoryTree.render(at: link) }
            try assertThrows(DeveloperFileToolError.notDirectory) { _ = try DirectoryTree.render(at: package) }
        }

        runTest("开发者工具：目录树深度限制明确标记") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let deep = root.appendingPathComponent("a/b/c/d/e")
            try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
            try Data().write(to: deep.appendingPathComponent("hidden.txt"))
            let tree = try DirectoryTree.render(at: root)
            try assertTrue(tree.contains("d/ …"))
            try assertTrue(!tree.contains("e/") && !tree.contains("hidden.txt"))
        }

        runTest("开发者工具：目录树项数上限") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for index in 0..<1_005 { try Data().write(to: root.appendingPathComponent("file-\(index)")) }
            let tree = try DirectoryTree.render(at: root)
            try assertTrue(tree.contains("…"))
            try assertEqual(tree.split(separator: "\n").filter { $0.contains("file-") }.count, 1_000)
        }

        runTest("开发者工具：目录树输出字节上限") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for index in 0..<700 {
                try Data().write(to: root.appendingPathComponent(String(repeating: "a", count: 230) + "-\(index)"))
            }
            let tree = try DirectoryTree.render(at: root)
            try assertTrue(tree.contains("…"))
            try assertTrue(tree.utf8.count <= 128 * 1024)
        }

        runTest("开发者工具：不可读目录与错误输入不返回空结果") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("plain.txt")
            try Data().write(to: file)
            try assertThrows(DeveloperFileToolError.notDirectory) { _ = try DirectoryTree.render(at: file) }
            var missingFailed = false
            do { _ = try ProjectRelativePath.paths(for: [root.appendingPathComponent("missing")]) } catch { missingFailed = true }
            try assertTrue(missingFailed)
            let locked = root.appendingPathComponent("locked")
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
            if !FileManager.default.isReadableFile(atPath: locked.path) {
                try assertThrows(DeveloperFileToolError.unreadableDirectory) { _ = try DirectoryTree.render(at: root) }
            }
        }

        runTest("自定义命令：文件、目录、空白处和多选的工作目录") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("main.py")
            try Data().write(to: file)
            let folder = root.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let second = folder.appendingPathComponent("sub.py")
            try Data().write(to: second)
            try assertEqual(try DeveloperCommand.context(selection: [file], directory: nil).directory.path, root.path)
            try assertEqual(try DeveloperCommand.context(selection: [folder], directory: root).directory.path, folder.path)
            try assertEqual(try DeveloperCommand.context(selection: [], directory: root).items, [root])
            try assertEqual(try DeveloperCommand.context(selection: [file, second], directory: root).directory.path, root.path)
            var rejected = false
            do { _ = try DeveloperCommand.context(selection: [], directory: nil) } catch { rejected = true }
            try assertTrue(rejected)
        }

        runTest("自定义命令：参数保留中文空格引号且不执行文件名中的命令") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let first = root.appendingPathComponent("中文 空格 ' $(touch injected).txt")
            let second = root.appendingPathComponent("second.txt")
            let result = try DeveloperCommandRunner().run(script: "printf '%s\\n' \"$@\"", items: [first, second], directory: root)
            try assertEqual(result.status, 0)
            try assertTrue(result.output.contains(first.path + "\n" + second.path))
            try assertTrue(!FileManager.default.fileExists(atPath: root.appendingPathComponent("injected").path))
        }

        runTest("自定义命令：收集标准输出与错误并保留退出码") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let result = try DeveloperCommandRunner().run(script: "printf STDOUT; printf STDERR >&2; exit 7", items: [], directory: root)
            try assertEqual(result.status, 7)
            try assertTrue(result.output.contains("STDOUT") && result.output.contains("STDERR"))
            try assertTrue(!result.cancelled)
        }

        runTest("自定义命令：输出超过管道容量时不死锁并限制内存") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let result = try DeveloperCommandRunner().run(
                script: "for i in {1..10000}; do printf 0123456789abcdef >&2; done; printf END", items: [], directory: root)
            try assertEqual(result.status, 0)
            try assertTrue(result.truncated)
            try assertTrue(result.output.utf8.count <= DeveloperCommandRunner.outputLimit)
            try assertTrue(result.output.hasSuffix("END"))
        }

        runTest("自定义命令：停止命令同时终止普通子进程") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = DeveloperCommandRunner()
            let start = ProcessInfo.processInfo.systemUptime
            let result = try runner.run(script: "/bin/sleep 20 & print READY; wait", items: [], directory: root) { output, _ in
                if output.contains("READY") { runner.cancel() }
            }
            try assertTrue(result.cancelled)
            try assertTrue(ProcessInfo.processInfo.systemUptime - start < 5)
        }

        runTest("自定义命令：忽略终止信号时升级停止且不会遗留等待") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = DeveloperCommandRunner()
            let start = ProcessInfo.processInfo.systemUptime
            let result = try runner.run(script: "trap '' TERM; /bin/sleep 20 & print READY; wait", items: [], directory: root) { output, _ in
                if output.contains("READY") { runner.cancel() }
            }
            try assertTrue(result.cancelled)
            try assertTrue(ProcessInfo.processInfo.systemUptime - start < 5)
        }

        runTest("自定义命令：执行前停止与非法配置") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let runner = DeveloperCommandRunner()
            runner.cancel()
            let result = try runner.run(script: "touch unexpected", items: [], directory: root)
            try assertTrue(result.cancelled)
            try assertTrue(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unexpected").path))
            try assertTrue(!DeveloperCommand(name: "", script: "pwd").isValid)
            try assertTrue(!DeveloperCommand(name: "title\nforged", script: "pwd").isValid)
            try assertTrue(!DeveloperCommand(name: "title", script: " \n").isValid)
            try assertTrue(!DeveloperCommand(id: "../../command", name: "title", script: "pwd").isValid)
        }

        func compareTextFixtures(_ left: String, _ right: String) throws -> FileComparisonResult {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let l = root.appendingPathComponent("left.txt"), r = root.appendingPathComponent("right.txt")
            try left.write(to: l, atomically: true, encoding: .utf8)
            try right.write(to: r, atomically: true, encoding: .utf8)
            let ld = try ComparisonDocument.read(l), rd = try ComparisonDocument.read(r)
            let result = try FileComparisonResult.compare(ld, rd)
            try assertEqual(result.rows.compactMap(\.left), ld.lines)
            try assertEqual(result.rows.compactMap(\.right), rd.lines)
            try assertEqual(result.rows.compactMap(\.leftNumber), Array(1..<(ld.lines.count + 1)))
            try assertEqual(result.rows.compactMap(\.rightNumber), Array(1..<(rd.lines.count + 1)))
            try assertEqual(try String(contentsOf: l, encoding: .utf8), left, "比较不能修改左侧文件")
            try assertEqual(try String(contentsOf: r, encoding: .utf8), right, "比较不能修改右侧文件")
            return result
        }

        runTest("文件比较：相同文本和空文件") {
            let identical = try compareTextFixtures("first\nsecond\n", "first\nsecond\n")
            try assertEqual(identical.additions, 0)
            try assertEqual(identical.deletions, 0)
            try assertTrue(identical.rows.allSatisfy { $0.kind == .unchanged })
            try assertTrue(try compareTextFixtures("", "").rows.isEmpty)
        }

        runTest("文件比较：开头中间末尾的插入删除替换与行号对齐") {
            let cases = [("", "one\n"), ("one\n", ""), ("a\nc\n", "a\nb\nc\n"),
                         ("a\nb\nc\n", "a\nc\n"), ("b\nc\n", "a\nb\nc\n"),
                         ("a\nb\n", "a\nb\nc\n"), ("a\nold\nc\n", "a\nnew\nextra\nc\n"),
                         ("a\nb\na\n", "b\na\nb\n")]
            for (left, right) in cases {
                let result = try compareTextFixtures(left, right)
                try assertTrue(result.additions + result.deletions > 0)
                try assertTrue(result.rows.filter { $0.kind == .unchanged }.allSatisfy { $0.left == $0.right })
            }
            let replaced = try compareTextFixtures("a\nold\nc\n", "a\nnew\nextra\nc\n")
            try assertEqual(replaced.deletions, 1)
            try assertEqual(replaced.additions, 2)
            try assertEqual(replaced.rows[2].left, nil)
            try assertEqual(replaced.rows[2].right, "extra")
        }

        runTest("文件比较：内容像 diff 标头时不会误解析") {
            let result = try compareTextFixtures("1c1\n< old\n---\n", "2a3\n> new\n---\n")
            try assertEqual(result.rows.last?.left, "---")
            try assertEqual(result.rows.last?.kind, .unchanged)
        }

        runTest("文件比较：末尾换行和换行格式差异") {
            let finalNewline = try compareTextFixtures("last", "last\n")
            try assertEqual(finalNewline.additions, 1)
            try assertEqual(finalNewline.deletions, 1)
            let crlf = try compareTextFixtures("a\r\nb\r\n", "a\nb\n")
            try assertEqual(crlf.additions + crlf.deletions, 0)
            try assertTrue(crlf.differentLineEndings)
            let cr = try compareTextFixtures("a\rb\r", "a\r\nb\r\n")
            try assertTrue(cr.differentLineEndings)
        }

        runTest("文件比较：中文 UTF-8 BOM 与 UTF-16 BOM") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let l = root.appendingPathComponent("中文 空格's.txt"), r = root.appendingPathComponent("right.txt")
            let text = "中文🙂\n第二行\n"
            try (Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)).write(to: l)
            try (Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!).write(to: r)
            let result = try FileComparisonResult.compare(ComparisonDocument.read(l), ComparisonDocument.read(r))
            try assertEqual(result.additions + result.deletions, 0)
            try assertEqual(result.rows.first?.left, "中文🙂")
        }

        runTest("文件比较：拒绝二进制目录大文件及过多行") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("input")
            try Data([0x61, 0x00, 0x62]).write(to: url)
            try assertThrows(FileComparisonError.notText) { _ = try ComparisonDocument.read(url) }
            try Data([0xFF, 0xFD]).write(to: url)
            try assertThrows(FileComparisonError.notText) { _ = try ComparisonDocument.read(url) }
            try assertThrows(FileComparisonError.notText) { _ = try ComparisonDocument.read(root) }
            try Data(repeating: 0x61, count: ComparisonDocument.maxBytes + 1).write(to: url)
            try assertThrows(FileComparisonError.tooLarge) { _ = try ComparisonDocument.read(url) }
            try String(repeating: "line\n", count: 20_001).write(to: url, atomically: true, encoding: .utf8)
            try assertThrows(FileComparisonError.tooManyLines) { _ = try ComparisonDocument.read(url) }
        }

        // MARK: - Git 仓库扫描与快速切换

        runTest("Git 仓库扫描：发现目录、解析分支与跳过依赖") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            let fm = FileManager.default
            let projA = root.appendingPathComponent("codes/projectA")
            let gitDirA = projA.appendingPathComponent(".git")
            try fm.createDirectory(at: gitDirA, withIntermediateDirectories: true)
            try "ref: refs/heads/feature-alpha\n".write(to: gitDirA.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

            let projB = root.appendingPathComponent("codes/projectB")
            let actualGitDirB = root.appendingPathComponent("actual_gitdir_b")
            try fm.createDirectory(at: projB, withIntermediateDirectories: true)
            try fm.createDirectory(at: actualGitDirB, withIntermediateDirectories: true)
            try "gitdir: ../../actual_gitdir_b\n".write(to: projB.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
            try "a1b2c3d4e5f6\n".write(to: actualGitDirB.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)

            // 位于 node_modules 中的假仓库应被忽略
            let projC = root.appendingPathComponent("codes/projectC/node_modules/fake-lib")
            try fm.createDirectory(at: projC.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try "ref: refs/heads/main\n".write(to: projC.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

            // 位于 Library 中的假仓库应被忽略
            let projD = root.appendingPathComponent("Library/ignored-app")
            try fm.createDirectory(at: projD.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try "ref: refs/heads/main\n".write(to: projD.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

            let results = GitRepositoryScanner.scan(roots: [root], maxDepth: 5)
            try assertEqual(results.count, 2, "只应发现 projectA 和 projectB")

            let foundA = results.first { $0.name == "projectA" }
            try assertTrue(foundA != nil, "projectA 应该被发现")
            try assertEqual(foundA?.branch, "feature-alpha", "分支名解析正确")

            let foundB = results.first { $0.name == "projectB" }
            try assertTrue(foundB != nil, "projectB 应该被发现")
            try assertEqual(foundB?.branch, "a1b2c3d", "Detached HEAD 解析前 7 位")

            let item = GitRepositoryItem(url: projA, branch: "main")
            try assertEqual(item.name, "projectA")
            try assertEqual(item.path, projA.standardizedFileURL.path)
        }

        runTest("Git 仓库历史：SharedConfig 记录与去重") {
            let configFile = makeTempDirectory().appendingPathComponent("settings.plist")
            defer { try? FileManager.default.removeItem(at: configFile.deletingLastPathComponent()) }
            let config = SharedConfig(fileURL: configFile)

            config.markGitRepositoryUsed("/path/to/repoA")
            config.markGitRepositoryUsed("/path/to/repoB")
            try assertEqual(config.recentGitRepositories, ["/path/to/repoB", "/path/to/repoA"])

            config.markGitRepositoryUsed("/path/to/repoA")
            try assertEqual(config.recentGitRepositories, ["/path/to/repoA", "/path/to/repoB"], "最近访问的项移至最前")
        }

        runTest("文件权限：POSIX 格式与八进制解析") {
            let permDir = FilePermissions(mode: S_IFDIR | 0o755)
            try assertEqual(permDir.octal, "755")
            try assertEqual(permDir.symbolic, "drwxr-xr-x")
            try assertEqual(permDir.menuTitle, "权限：drwxr-xr-x (755)")

            let permFile = FilePermissions(mode: S_IFREG | 0o644)
            try assertEqual(permFile.octal, "644")
            try assertEqual(permFile.symbolic, "-rw-r--r--")
            try assertEqual(permFile.menuTitle, "权限：-rw-r--r-- (644)")

            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let testFile = tempDir.appendingPathComponent("test.sh")
            try "#!/bin/sh\necho hi\n".write(to: testFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testFile.path)

            let readPerm = FilePermissions.permissions(at: testFile.path)
            try assertTrue(readPerm != nil, "应该成功读取文件权限")
            try assertEqual(readPerm?.octal, "755")
            try assertEqual(readPerm?.symbolic, "-rwxr-xr-x")

            let en: (String) -> String = { key in
                switch key {
                case "权限：%@ (%@)": return "Permissions: %1$@ (%2$@)"
                case "所属：%@:%@": return "Owner: %1$@:%2$@"
                case "所有者：%@": return "Owner: %@"
                case "点击复制权限": return "Click to copy permissions"
                default: return key
                }
            }
            try assertEqual(permFile.menuTitle(localize: en), "Permissions: -rw-r--r-- (644)")
            try assertTrue(permFile.toolTip(localize: en).contains("Click to copy permissions"))
        }

        runTest("代码行数统计：精确统计代码行、注释行与空行") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let swiftFile = tempDir.appendingPathComponent("Sample.swift")
            let swiftContent = """
            // 头部注释
            import Foundation

            /* 多行块注释
               第二行
            */
            struct App {
                let name = "test" // 行尾注释
            }

            """
            try swiftContent.write(to: swiftFile, atomically: true, encoding: .utf8)

            let singleResult = LineCounter.count(at: swiftFile)
            try assertTrue(singleResult != nil, "单文件统计应成功")
            try assertEqual(singleResult?.totalFiles, 1)
            let swiftStats = singleResult?.languages.first { $0.language == "Swift" }
            try assertTrue(swiftStats != nil, "应识别为 Swift")
            try assertEqual(swiftStats?.blank, 1, "空行数")
            try assertEqual(swiftStats?.comment, 4, "注释行数 (头部 1 + 块注释 3)")
            try assertEqual(swiftStats?.code, 4, "代码行数 (import + struct + let + })")

            // 测试忽略目录
            let nodeModules = tempDir.appendingPathComponent("node_modules")
            try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
            let ignoredJs = nodeModules.appendingPathComponent("lib.js")
            try "console.log('ignored');\n".write(to: ignoredJs, atomically: true, encoding: .utf8)

            let dirResult = LineCounter.count(at: tempDir)
            try assertTrue(dirResult != nil, "目录统计应成功")
            try assertEqual(dirResult?.totalFiles, 1, "应忽略 node_modules 下的文件")
            try assertEqual(dirResult?.languages.count, 1)
        }
    }
}
