import Foundation
import AppKit
import FinderRightKit
import Compression

// MARK: - 测试辅助断言

private var totalTests = 0
private var passedTests = 0
private var failedTests = 0

private func runTest(_ name: String, _ block: () throws -> Void) {
    totalTests += 1
    print("▶ 运行测试: \(name)...", terminator: " ")
    do {
        try block()
        passedTests += 1
        print("✓ 通过")
    } catch {
        failedTests += 1
        print("✗ 失败: \(error)")
    }
}

private struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        throw TestFailure(message: "断言失败: [\(a)] 不等于 [\(b)] \(message) (at \(file):\(line))")
    }
}

private func assertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !condition {
        throw TestFailure(message: "断言失败: 期望为 true \(message) (at \(file):\(line))")
    }
}

private func assertNil(_ value: Any?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if value != nil {
        throw TestFailure(message: "断言失败: 期望为 nil，但得到 [\(value!)] \(message) (at \(file):\(line))")
    }
}

/// 每个用例独立的临时目录（真实文件系统语义，避免共享状态互相干扰）
private func makeTempDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("finderright-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 读取 zip 内的条目名（已排序；忽略 ditto --sequesterRsrc 生成的 __MACOSX 资源分叉）
private func zipEntries(_ zip: URL) throws -> [String] {
    let listing = makeTempDirectory().appendingPathComponent("zipinfo.txt")
    FileManager.default.createFile(atPath: listing.path, contents: nil)
    let handle = try FileHandle(forWritingTo: listing)
    let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/zipinfo"),
                                       arguments: ["-1", zip.path],
                                       standardOutput: handle)
    try handle.close()
    guard result.status == 0 else { throw TestFailure(message: "zipinfo 失败: \(result.stderr)") }
    return try String(contentsOf: listing, encoding: .utf8)
        .split(separator: "\n").map(String.init)
        .filter { !$0.hasPrefix("__MACOSX") }
        .sorted()
}

/// 目录下的全部条目名（含隐藏项，已排序）
private func directoryListing(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

/// 当前进程的 audit token（测试「按 audit token 校验运行中进程的签名」用）
private func currentProcessAuditToken() -> Data? {
    var token = audit_token_t()
    var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &token) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
}

// MARK: - 主测试入口

@main
struct FinderRightKitTestsRunner {
    static func main() {
        print("=========================================")
        print("    FinderRightKit 单元测试套件运行中")
        print("=========================================\n")

        // 1. AnyJSON 编解码往返测试
        runTest("AnyJSON 编解码往返") {
            let originalPayload: [String: AnyJSON] = [
                "string": .string("hello world"),
                "int": .int(42),
                "bool": .bool(true),
                "stringArray": .stringArray(["one", "two", "three"]),
                "nullVal": .null
            ]

            let encoder = JSONEncoder()
            let data = try encoder.encode(originalPayload)

            let decoder = JSONDecoder()
            let decodedPayload = try decoder.decode([String: AnyJSON].self, from: data)

            try assertEqual(decodedPayload["string"]?.stringValue, "hello world")
            try assertEqual(decodedPayload["int"]?.intValue, 42)
            try assertEqual(decodedPayload["bool"]?.boolValue, true)
            try assertEqual(decodedPayload["stringArray"]?.stringArrayValue, ["one", "two", "three"])
            if case .null = decodedPayload["nullVal"] {
                // ok
            } else {
                throw TestFailure(message: "nullVal 解码后不为 .null")
            }
        }

        // 2. FileTemplate Codable 往返测试
        runTest("FileTemplate Codable 往返") {
            let tmpl = FileTemplate(id: "test-id-1", name: "Python Script", fileExtension: "py", content: "print('hello')\n")
            let data = try JSONEncoder().encode(tmpl)
            let decoded = try JSONDecoder().decode(FileTemplate.self, from: data)

            try assertEqual(decoded.id, "test-id-1")
            try assertEqual(decoded.name, "Python Script")
            try assertEqual(decoded.fileExtension, "py")
            try assertEqual(decoded.content, "print('hello')\n")
            try assertEqual(decoded, tmpl)
        }

        // 3. VersionComparator 版本号比较测试
        runTest("VersionComparator 版本号比较") {
            // 相同版本，带与不带 v 前缀
            try assertEqual(VersionComparator.compareVersions("v1.1.8", "1.1.8"), .orderedSame)
            try assertEqual(VersionComparator.compareVersions("1.1.8", "V1.1.8"), .orderedSame)

            // 次版本号比较（1.10 > 1.9）
            try assertEqual(VersionComparator.compareVersions("1.10", "1.9"), .orderedDescending)
            try assertEqual(VersionComparator.compareVersions("1.9", "1.10"), .orderedAscending)

            // 主版本号比较
            try assertEqual(VersionComparator.compareVersions("2.0.0", "1.9.9"), .orderedDescending)
            try assertEqual(VersionComparator.compareVersions("1.0.0", "2.0.0"), .orderedAscending)

            // 带 -beta / -rc 前缀与纯数字
            try assertEqual(VersionComparator.compareVersions("1.1.8-beta1", "1.1.8"), .orderedSame)
            try assertEqual(VersionComparator.compareVersions("1.1.9-rc", "1.1.8"), .orderedDescending)

            // 多段比较与尾部补零
            try assertEqual(VersionComparator.compareVersions("1.2.0.0", "1.2"), .orderedSame)
            try assertEqual(VersionComparator.compareVersions("1.2.1", "1.2"), .orderedDescending)
        }

        // 4. SharedConfig 独立读写与默认值测试
        runTest("SharedConfig 独立读写与默认值") {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-settings-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let config = SharedConfig(fileURL: tempURL)

            // 默认值
            try assertEqual(config.preferredTerminal, "com.apple.Terminal")
            try assertEqual(config.menuIconStyle, .modern)
            try assertTrue(config.customFileTemplates.isEmpty)
            try assertNil(config.shortcut(forActionId: "shortcut.cut"))

            // 写入并验证
            config.preferredTerminal = "com.googlecode.iterm2"
            config.menuIconStyle = .tile
            let shortcut = ActionShortcut(key: "x", modifiers: 1048576) // Cmd
            config.setShortcut(shortcut, forActionId: "shortcut.cut")

            let tmpl = FileTemplate(name: "Log", fileExtension: "log", content: "[INIT]")
            config.addFileTemplate(tmpl)

            try assertEqual(config.preferredTerminal, "com.googlecode.iterm2")
            try assertEqual(config.menuIconStyle, .tile)
            try assertEqual(config.shortcut(forActionId: "shortcut.cut")?.key, "x")
            try assertEqual(config.customFileTemplates.count, 1)
            try assertEqual(config.customFileTemplates.first?.fileExtension, "log")

            // 重新从磁盘创建实例加载，验证持久化
            let reloadedConfig = SharedConfig(fileURL: tempURL)
            try assertEqual(reloadedConfig.preferredTerminal, "com.googlecode.iterm2")
            try assertEqual(reloadedConfig.menuIconStyle, .tile)
            try assertEqual(reloadedConfig.shortcut(forActionId: "shortcut.cut")?.key, "x")
            try assertEqual(reloadedConfig.customFileTemplates.count, 1)

            // 删除模板
            reloadedConfig.removeFileTemplate(withId: tmpl.id)
            try assertTrue(reloadedConfig.customFileTemplates.isEmpty)
        }

        // 5. SharedConfig 多线程并发压测
        runTest("MenuIconStyle 旧存储值迁移") {
            try assertEqual(MenuIconStyle(storedValue: "classic"), .tile)
            try assertEqual(MenuIconStyle(storedValue: "modern"), .modern)
            try assertEqual(MenuIconStyle(storedValue: "tinted"), .tinted)
            try assertNil(MenuIconStyle(storedValue: "unknown"))
        }

        runTest("MenuTint 与功能色绑定") {
            try assertEqual(MenuTint.blue.name, "blue")
            try assertEqual(MenuTint.blue.tile.light, 0x007AFF)
            try assertTrue(!MenuTint.blue.darkGlyph)
            try assertTrue(MenuTint.yellow.darkGlyph)

            let newFile = MenuFeatureCatalog.feature(forId: MenuFeatureCatalog.newFile)
            try assertEqual(newFile?.tint, .blue)
            let terminal = MenuFeatureCatalog.feature(forId: MenuFeatureCatalog.openTerminal)
            try assertEqual(terminal?.tint, .graphite)
            let cut = MenuFeatureCatalog.feature(forId: MenuFeatureCatalog.cut)
            try assertEqual(cut?.tint, .orange)
        }

        runTest("SharedConfig 多线程并发压测") {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-concurrent-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let config = SharedConfig(fileURL: tempURL)
            let queue = DispatchQueue(label: "com.finderright.test.concurrent", attributes: .concurrent)
            let group = DispatchGroup()

            let iterations = 100
            for i in 0..<iterations {
                group.enter()
                queue.async {
                    config.preferredTerminal = "terminal-\(i)"
                    config.menuIconStyle = (i % 2 == 0) ? .modern : .tile
                    _ = config.preferredTerminal
                    _ = config.menuIconStyle
                    let s = ActionShortcut(key: "k\(i % 10)", modifiers: i)
                    config.setShortcut(s, forActionId: "action.\(i % 5)")
                    _ = config.shortcut(forActionId: "action.\(i % 5)")
                    group.leave()
                }
            }

            let waitResult = group.wait(timeout: .now() + 10)
            try assertEqual(waitResult, .success, "并发访问超时，可能发生了死锁！")
        }

        // 6. CutQueueStore 读写、去重与清空
        runTest("CutQueueStore 读写与去重合并") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)

            try assertTrue(store.read().isEmpty, "空目录应读出空队列")

            try store.write(["/tmp/a", "/tmp/b"])
            try assertEqual(store.read(), ["/tmp/a", "/tmp/b"])

            // 去重合并：重复项忽略，新项追加在尾部
            let merged = try store.appendUnique(["/tmp/b", "/tmp/c"])
            try assertEqual(merged, ["/tmp/a", "/tmp/b", "/tmp/c"])
            try assertEqual(store.read(), ["/tmp/a", "/tmp/b", "/tmp/c"])

            // 写入空数组等价于清空（不留空数组文件）
            try store.write([])
            try assertTrue(store.read().isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: store.queueURL.path))
        }

        // 7. CutQueueStore 取走队列 + 崩溃恢复
        runTest("CutQueueStore 取走队列与崩溃恢复") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)

            // 造两个真实存在的源文件，用于验证 existingOnly 过滤
            let alive = dir.appendingPathComponent("alive.txt")
            FileManager.default.createFile(atPath: alive.path, contents: Data("x".utf8))
            let gone = dir.appendingPathComponent("gone.txt")

            try store.write([alive.path, gone.path])
            let batch = try store.take()!
            try assertEqual(batch.paths, [alive.path, gone.path], "take 应返回并取走队列")
            try assertTrue(store.read().isEmpty, "take 后队列应为空")
            try assertTrue(FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("cut-queue.inflight.") }, "take 应留下本批恢复记录")
            try assertNil(try store.take(), "队列已被取走，第二次 take 应返回 nil")

            // 模拟主 App 在移动过程中被杀：in-flight 残留 → 启动时恢复
            let restored = try store.recover(existingOnly: true)
            try assertEqual(restored, [alive.path], "只应恢复仍存在的源文件")
            try assertEqual(store.read(), [alive.path])
            try assertTrue(!FileManager.default.fileExists(atPath: store.inflightURL.path), "恢复后应删除 in-flight 标记")

            // finish() 在没有 in-flight 标记时也必须幂等
            try store.finish(batch.id)
            try assertEqual(store.read(), [alive.path])

            // recover 在无 in-flight 残留时不应改动队列
            try assertEqual(try store.recover(), [alive.path])
        }

        // 8. CutQueueStore：取消剪切必须能作废 in-flight 标记
        runTest("CutQueueStore 取消剪切作废 in-flight") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)

            try store.write(["/tmp/x"])
            _ = try store.take()
            store.clear()

            try assertTrue(store.read().isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: store.inflightURL.path))
            try assertTrue(try store.recover(existingOnly: false).isEmpty, "取消后不应再恢复出任何路径")
        }

        runTest("CutQueueStore 两批未完成时都能崩溃恢复") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            try store.write(["/tmp/a"])
            _ = try store.take()
            try store.write(["/tmp/b"])
            _ = try store.take()
            try assertEqual(Set(try store.recover(existingOnly: false)), Set(["/tmp/a", "/tmp/b"]))
        }

        runTest("CutQueueStore 空队列写入不作废在途恢复记录") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            try store.write(["/tmp/a"])
            _ = try store.take()
            try store.write([])
            try assertEqual(try store.recover(existingOnly: false), ["/tmp/a"])
        }

        runTest("CutQueueStore 恢复写回失败时保留恢复记录") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            let data = try JSONEncoder().encode(["/tmp/a"])
            try data.write(to: store.inflightURL)
            // 用非空目录挡住原子写入，不依赖运行账户的权限。
            try FileManager.default.createDirectory(at: store.queueURL, withIntermediateDirectories: false)
            try Data().write(to: store.queueURL.appendingPathComponent("blocker"))
            var failed = false
            do { _ = try store.recover(existingOnly: false) } catch { failed = true }
            try assertTrue(failed, "写回失败须传播错误")
            try assertTrue(FileManager.default.fileExists(atPath: store.inflightURL.path), "写回失败不能删除唯一的恢复记录")
            try FileManager.default.removeItem(at: store.queueURL)
            try assertEqual(try store.recover(existingOnly: false), ["/tmp/a"])

        }

        runTest("CutQueueStore 前一批完成不删除后一批恢复记录") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            try store.write(["/tmp/a"])
            let first = try store.take()!
            try store.write(["/tmp/b"])
            _ = try store.take()
            try store.finish(first.id)
            try assertEqual(try store.recover(existingOnly: false), ["/tmp/b"])
        }

        runTest("CutQueueStore 部分失败与新剪切项合并且不影响其他批次") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            try store.write(["/tmp/a", "/tmp/failed"])
            let first = try store.take()!
            try store.write(["/tmp/b"])
            _ = try store.take()
            try store.write(["/tmp/new", "/tmp/failed"])
            try store.finish(first.id, retrying: ["/tmp/failed"])
            try assertEqual(store.read(), ["/tmp/new", "/tmp/failed"])
            try assertEqual(try store.recover(existingOnly: false), ["/tmp/new", "/tmp/failed", "/tmp/b"])
        }

        runTest("CutQueueStore 取消后旧批次完成不干扰新批次") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            try store.write(["/tmp/old"])
            let old = try store.take()!
            try store.write(["/tmp/also-old"])
            _ = try store.take()
            store.clear()
            try assertTrue(try store.recover(existingOnly: false).isEmpty)
            try store.write(["/tmp/new"])
            _ = try store.take()
            try store.finish(old.id, retrying: ["/tmp/old"])
            try assertTrue(store.read().isEmpty, "旧任务失败不能撤销取消剪切")
            try assertEqual(try store.recover(existingOnly: false), ["/tmp/new"])
        }

        runTest("CutQueueStore 新旧恢复记录合并去重并过滤已移动项") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            let alive = dir.appendingPathComponent("alive.txt")
            let pending = dir.appendingPathComponent("pending.txt")
            try Data().write(to: alive)
            try Data().write(to: pending)
            try JSONEncoder().encode([alive.path, "/nonexistent/finderright-moved"]).write(to: store.inflightURL)
            try store.write([alive.path])
            _ = try store.take()
            try store.write([pending.path])
            try assertEqual(try store.recover(), [pending.path, alive.path])
            try assertTrue(!FileManager.default.fileExists(atPath: store.inflightURL.path))
            try assertTrue(!FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("cut-queue.inflight.") })
        }

        runTest("CutQueueStore 失败项写回受阻时仍能在重启后恢复") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            let moved = dir.appendingPathComponent("moved.txt")
            let failed = dir.appendingPathComponent("failed.txt")
            try Data().write(to: failed)
            try store.write([moved.path, failed.path])
            let batch = try store.take()!
            try FileManager.default.createDirectory(at: store.queueURL, withIntermediateDirectories: false)
            try Data().write(to: store.queueURL.appendingPathComponent("blocker"))
            var writeFailed = false
            do { try store.finish(batch.id, retrying: [failed.path]) } catch { writeFailed = true }
            try assertTrue(writeFailed)
            try FileManager.default.removeItem(at: store.queueURL)
            try assertEqual(try store.recover(), [failed.path])
        }

        runTest("CutQueueStore 领取失败保留待剪切队列") {
            let dir = makeTempDirectory()
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
                try? FileManager.default.removeItem(at: dir)
            }
            let store = CutQueueStore(directory: dir)
            try store.write(["/tmp/a"])
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
            var failed = false
            do { _ = try store.take() } catch { failed = true }
            try assertTrue(failed, "无法保存恢复记录时须拒绝移动")
            try assertEqual(store.read(), ["/tmp/a"])
        }

        runTest("CutQueueStore 损坏记录不阻塞其他批次恢复") {
            for name in ["cut-queue.inflight.json", "cut-queue.inflight.00000000-0000-0000-0000-000000000001.json"] {
                let dir = makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = CutQueueStore(directory: dir)
                try store.write(["/tmp/healthy"])
                _ = try store.take()
                let broken = dir.appendingPathComponent(name)
                try Data("broken".utf8).write(to: broken)
                try assertEqual(try store.recover(existingOnly: false), ["/tmp/healthy"])
                try assertTrue(FileManager.default.fileExists(atPath: broken.path), "坏记录保留供排查")
                try assertEqual(try store.recover(existingOnly: false), ["/tmp/healthy"], "下次恢复仍不受坏记录阻塞")
            }
        }

        // 9. pluginkit 选举输出解析
        runTest("FinderSyncElection 解析 pluginkit 输出") {
            // 真实 `pluginkit -m -p com.apple.FinderSync` 输出样本（2026-10-02 本机）+ 边界行
            let output = """
            -    com.google.GeminiMacOS.FinderSync(1.119.02.0)
            +    com.google.drivefs.finderhelper.findersync(131.0)
            +    com.alienator88.Pearcleaner.FinderOpen(5.4.3)
            +    com.aone.keka.KekaFinderIntegration(1.6.4)
            +    com.finderright.app.sync(1.1.10)
                 com.example.noelection(2.0)
            !    com.example.debug(1.0)
            +    com.aone.keka.KekaFinderIntegration(1.6.3)
            +    com.tencent.inputmethod.wetype.FinderSync(2.2.3)

            garbage line without id
            """
            let entries = FinderSyncElection.parse(output)
            try assertEqual(entries.count, 9, "空行与无法识别的行应被忽略")
            try assertEqual(entries[0], FinderSyncElection.Entry(state: "-", bundleId: "com.google.GeminiMacOS.FinderSync", version: "1.119.02.0"))
            try assertEqual(entries[4].state, "+")
            try assertEqual(entries[5], FinderSyncElection.Entry(state: " ", bundleId: "com.example.noelection", version: "2.0"))
            try assertEqual(entries[6].state, "!")

            // 只取启用（+）的、去重、保持出现顺序、排除自身
            let ids = FinderSyncElection.enabledBundleIds(in: output, excluding: ["com.finderright.app.sync"])
            try assertEqual(ids, [
                "com.google.drivefs.finderhelper.findersync",
                "com.alienator88.Pearcleaner.FinderOpen",
                "com.aone.keka.KekaFinderIntegration",
                "com.tencent.inputmethod.wetype.FinderSync"
            ])
            try assertTrue(FinderSyncElection.enabledBundleIds(in: "", excluding: []).isEmpty, "空输出应得到空列表")
        }

        // 10. 抢回恢复标记存储
        runTest("BadgeReclaimRestoreStore 写入、读取与清除") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = BadgeReclaimRestoreStore(directory: dir)

            try assertTrue(store.load().isEmpty, "无标记时应读出空列表")
            try store.save(["com.aone.keka.KekaFinderIntegration", "com.alienator88.Pearcleaner.FinderOpen"])
            try assertEqual(store.load(), ["com.aone.keka.KekaFinderIntegration", "com.alienator88.Pearcleaner.FinderOpen"])

            store.clear()
            try assertTrue(store.load().isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: store.fileURL.path), "clear 应删除标记文件")
            store.clear() // 幂等

            // 损坏内容视为无标记，不得崩溃
            try Data("not json".utf8).write(to: store.fileURL)
            try assertTrue(store.load().isEmpty, "损坏的标记应视为空")
        }

        // 11. 抢回限流
        runTest("BadgeReclaimRateLimiter 限流规则") {
            var limiter = BadgeReclaimRateLimiter(minInterval: 20, maxPerWindow: 3, window: 3600)
            let t0 = Date(timeIntervalSince1970: 1_000_000)

            try assertEqual(limiter.evaluate(requester: "100:0", now: t0), .accept)
            // 同一请求方（扩展进程 + 注册轮次）只受理一次（即使已过最小间隔）
            if case .accept = limiter.evaluate(requester: "100:0", now: t0.addingTimeInterval(60)) {
                throw TestFailure(message: "同一 requester 不应被二次受理")
            }
            // 同一进程重新注册后进入新一轮，可再受理一次
            try assertEqual(limiter.evaluate(requester: "100:1", now: t0.addingTimeInterval(80)), .accept)
            // 不同请求方但未满最小间隔
            if case .accept = limiter.evaluate(requester: "101:0", now: t0.addingTimeInterval(85)) {
                throw TestFailure(message: "最小间隔内不应受理")
            }
            // 被拒绝不占用名额：101 过了间隔后仍可受理
            try assertEqual(limiter.evaluate(requester: "101:0", now: t0.addingTimeInterval(105)), .accept)
            // 滚动窗口内已满 3 次
            if case .accept = limiter.evaluate(requester: "102:0", now: t0.addingTimeInterval(200)) {
                throw TestFailure(message: "窗口内超过上限不应受理")
            }
            // 窗口滚过第一次之后恢复
            try assertEqual(limiter.evaluate(requester: "102:0", now: t0.addingTimeInterval(3601)), .accept)
        }

        // 12. 归属探测状态机：记录与查询
        runTest("BadgeOwnershipProbe 记录角标请求与归属查询") {
            var probe = BadgeOwnershipProbe()
            try assertTrue(!probe.isOwned(directory: "/Users/u/Desktop"))

            probe.recordBadgeRequest(itemPath: "/Users/u/Desktop/a.txt")
            try assertTrue(probe.isOwned(directory: "/Users/u/Desktop"))
            try assertTrue(probe.isOwned(directory: "/Users/u/Desktop/"), "目录尾部斜杠应规范化")
            try assertTrue(!probe.isOwned(directory: "/Users/u"), "只确认父目录本身，不外推")

            // NFD / NFC 混用（Finder 回调与 FileManager 可能给出不同的 Unicode 规范形式）
            probe.recordBadgeRequest(itemPath: "/Volumes/E/caf\u{0065}\u{0301}/a.txt")
            try assertTrue(probe.isOwned(directory: "/Volumes/E/caf\u{00E9}"), "NFD 记录应能被 NFC 查询命中")
        }

        // 13. 归属探测状态机：探测与申请配额
        runTest("BadgeOwnershipProbe 探测与抢回申请配额") {
            var probe = BadgeOwnershipProbe()
            let desktop = "/Users/u/Desktop"

            // 每个目录只探测一次
            try assertTrue(probe.beginProbe(directory: desktop), "首次观察应探测")
            try assertTrue(!probe.beginProbe(directory: desktop), "重复观察不应再次探测")

            // 被拒绝（非「无可见项」）消耗一次尝试；满 2 次后不再申请
            try assertTrue(probe.canRequestReclaim(directory: desktop))
            probe.noteReclaimAttempt()
            probe.noteReclaimResponse(directory: desktop, outcome: .rejected)
            try assertTrue(probe.canRequestReclaim(directory: desktop), "一次被拒后仍有剪切兜底机会")
            probe.noteReclaimAttempt()
            probe.noteReclaimResponse(directory: desktop, outcome: .rejected)
            try assertTrue(!probe.canRequestReclaim(directory: desktop), "尝试满 2 次后不应再申请")

            // 已确认归属的目录不需要申请
            var owned = BadgeOwnershipProbe()
            owned.recordBadgeRequest(itemPath: desktop + "/a.txt")
            try assertTrue(!owned.beginProbe(directory: desktop), "已确认的目录无需探测")
            try assertTrue(!owned.canRequestReclaim(directory: desktop))
        }

        // 14. 归属探测状态机：受理与「无可见项」
        runTest("BadgeOwnershipProbe 受理后停止、无可见项退还配额") {
            var probe = BadgeOwnershipProbe()
            let empty = "/Users/u/EmptyDir"
            let desktop = "/Users/u/Desktop"

            // 无可见项：退还尝试次数，且该目录不再申请
            probe.noteReclaimAttempt()
            probe.noteReclaimResponse(directory: empty, outcome: .rejectedNoVisibleItems)
            try assertEqual(probe.attempts, 0, "无可见项不应消耗尝试次数")
            try assertTrue(!probe.canRequestReclaim(directory: empty), "无可见项的目录不应再申请")
            try assertTrue(probe.canRequestReclaim(directory: desktop))

            // 受理后：本进程任何目录都不再申请
            probe.noteReclaimAttempt()
            probe.noteReclaimResponse(directory: desktop, outcome: .accepted)
            try assertTrue(probe.reclaimAccepted)
            try assertTrue(!probe.canRequestReclaim(directory: desktop))
            try assertTrue(!probe.canRequestReclaim(directory: "/Volumes/E"))

            // 主 App 响应映射
            try assertEqual(BadgeReclaimOutcome(success: true, message: nil), .accepted)
            try assertEqual(BadgeReclaimOutcome(success: false, message: BadgeReclaimRejection.noVisibleItems.message(detail: "/x")), .rejectedNoVisibleItems)
            try assertEqual(BadgeReclaimOutcome(success: false, message: BadgeReclaimRejection.rateLimited.message(detail: "20s")), .rejected)
            try assertEqual(BadgeReclaimOutcome(success: false, message: "IPC 超时 (10s)"), .rejected)
        }

        // 15. 归属探测状态机：同一时刻只允许一个在途请求
        runTest("BadgeOwnershipProbe 在途请求期间不再申请") {
            var probe = BadgeOwnershipProbe()
            let home = "/Users/u"
            let desktop = "/Users/u/Desktop"

            probe.noteReclaimAttempt()
            try assertTrue(probe.reclaimInFlight)
            try assertTrue(!probe.canRequestReclaim(directory: desktop), "在途期间不应并发申请（避免同一进程的请求互相挤占配额）")

            probe.noteReclaimResponse(directory: home, outcome: .rejectedNoVisibleItems)
            try assertTrue(!probe.reclaimInFlight, "收到响应后应结束在途")
            try assertTrue(probe.canRequestReclaim(directory: desktop), "上一个请求结束后其他目录可继续申请")
        }

        // 15b. 归属探测状态机：重新注册后开启新一轮
        runTest("BadgeOwnershipProbe 重新注册后清空归属并重置配额") {
            var probe = BadgeOwnershipProbe()
            let desktop = "/Users/u/Desktop"
            probe.recordBadgeRequest(itemPath: desktop + "/a.txt")
            _ = probe.beginProbe(directory: "/Users/u")
            probe.noteReclaimAttempt()
            probe.noteReclaimResponse(directory: "/Users/u", outcome: .accepted)
            try assertEqual(probe.epoch, 0)

            probe.beginNewRegistrationEpoch()
            try assertEqual(probe.epoch, 1)
            try assertTrue(!probe.isOwned(directory: desktop), "重新注册可能已丢失归属，旧的确认必须作废")
            try assertTrue(!probe.reclaimAccepted)
            try assertEqual(probe.attempts, 0)
            try assertTrue(probe.beginProbe(directory: "/Users/u"), "新一轮应允许重新探测")
            try assertTrue(probe.canRequestReclaim(directory: desktop))
        }

        // 16. 主 App 启动时判断扩展注册是否为当前 bundle（决定是否需要 pluginkit -a）
        runTest("FinderSyncElection 判断扩展注册是否为当前版本与路径") {
            let path = "/Applications/FinderRight.app/Contents/PlugIns/FinderRightSync.appex"
            // 真实 `pluginkit -m -v -i com.finderright.app.sync` 输出（字段以 Tab 分隔）
            let verbose = "+    com.finderright.app.sync(1.1.10)\t72146EC7-7CFE-4D41-B265-995B6C256615\t2026-10-01 19:43:32 +0000\t\(path)\n (1 plug-in)"
            try assertTrue(FinderSyncElection.isRegistrationCurrent(verboseOutput: verbose, appexPath: path, version: "1.1.10"))
            try assertTrue(!FinderSyncElection.isRegistrationCurrent(verboseOutput: verbose, appexPath: path, version: "1.1.11"), "刚升级（版本不一致）需要重新注册")
            try assertTrue(!FinderSyncElection.isRegistrationCurrent(verboseOutput: verbose, appexPath: "/Users/u/Downloads/FinderRight.app/Contents/PlugIns/FinderRightSync.appex", version: "1.1.10"), "路径变化需要重新注册")
            try assertTrue(!FinderSyncElection.isRegistrationCurrent(verboseOutput: "", appexPath: path, version: "1.1.10"), "未注册需要注册")

            // 回归：不带 -v 的输出没有路径字段，曾导致每次启动都误判为「路径变化」而重复 pluginkit -a
            let nonVerbose = "+    com.finderright.app.sync(1.1.10)"
            try assertTrue(!FinderSyncElection.isRegistrationCurrent(verboseOutput: nonVerbose, appexPath: path, version: "1.1.10"),
                           "非 -v 输出无法确认路径，调用方必须使用 -m -v")
        }

        // 17. 设置：角标冲突自动处理默认开启
        runTest("SharedConfig badgeOwnershipReclaim 默认开启且可持久化") {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-badge-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let config = SharedConfig(fileURL: tempURL)
            try assertTrue(config.badgeOwnershipReclaim, "默认应开启")
            config.badgeOwnershipReclaim = false
            try assertTrue(!SharedConfig(fileURL: tempURL).badgeOwnershipReclaim, "关闭应持久化")
        }

        // 18. 新建文件名校验：baseName / ext 会直接拼进路径，必须拦住路径穿越
        runTest("SafeFileName 放行正常文件名") {
            try assertTrue(SafeFileName.isValid(baseName: "untitled", ext: "txt"))
            try assertTrue(SafeFileName.isValid(baseName: "未命名", ext: "md"))
            try assertTrue(SafeFileName.isValid(baseName: "untitled", ext: ""), "无后缀应允许")
            try assertTrue(SafeFileName.isValid(baseName: "untitled", ext: "tar.gz"), "多段后缀应允许")
        }

        runTest("SafeFileName 拒绝路径穿越与非法字符") {
            try assertTrue(!SafeFileName.isValid(baseName: "../../../../tmp/escaped", ext: "txt"), "baseName 含 ../")
            try assertTrue(!SafeFileName.isValid(baseName: "untitled", ext: "conf/../../x"), "ext 含 /")
            try assertTrue(!SafeFileName.isValid(baseName: "..", ext: ""), "整体为 ..")
            try assertTrue(!SafeFileName.isValid(baseName: ".", ext: ""), "整体为 .")
            try assertTrue(!SafeFileName.isValid(baseName: "", ext: "txt"), "空 baseName")
            try assertTrue(!SafeFileName.isValid(baseName: "a\u{0}b", ext: "txt"), "NUL")
            try assertTrue(!SafeFileName.isValid(baseName: "untitled", ext: "t\nxt"), "控制字符")
            try assertTrue(!SafeFileName.isValid(baseName: String(repeating: "a", count: 300), ext: "txt"), "超过 255 字节")
        }

        // 19. 子进程执行：stderr 超过管道缓冲（约 64KB）时不得死锁
        runTest("ProcessRunner 大量 stderr 输出不死锁") {
            var result: ProcessRunner.Result?
            var runError: Error?
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do {
                    result = try ProcessRunner.run(
                        executableURL: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2"])
                } catch {
                    runError = error
                }
                done.signal()
            }
            guard done.wait(timeout: .now() + 10) == .success else {
                throw TestFailure(message: "10s 内未返回：stderr 写满管道导致死锁")
            }
            if let runError { throw runError }
            try assertEqual(result?.status, 0)
            let count = result?.stderr.count ?? 0
            try assertTrue(count > 0 && count <= ProcessRunner.defaultStderrTailLimit,
                           "stderr 只保留尾部，实际 \(count) 字符")
        }

        runTest("ProcessRunner 透传退出码与 stderr 内容") {
            let result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo boom >&2; exit 3"])
            try assertEqual(result.status, 3)
            try assertEqual(result.stderr, "boom")
        }

        // 20. 恢复标记合并：上次遗留未恢复的扩展不能被新一轮抢回覆盖掉
        runTest("BadgeReclaimRestoreStore merge 保留上次遗留的待恢复项") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = BadgeReclaimRestoreStore(directory: dir)

            try assertEqual(try store.merge(["a.ext", "a.ext"]), ["a.ext"], "空标记时合并结果应去重")
            try store.save(["a.ext", "b.ext"])
            let merged = try store.merge(["a.ext", "c.ext"])
            try assertEqual(merged, ["a.ext", "b.ext", "c.ext"], "b.ext 是上次未恢复的，必须保留")
            try assertEqual(store.load(), ["a.ext", "b.ext", "c.ext"], "合并结果应落盘")
        }

        // 21. 更新包校验和文件解析：只接受 64 位十六进制 SHA-256
        runTest("UpdateIntegrity 解析 shasum 输出") {
            let hash = String(repeating: "ab", count: 32)
            try assertEqual(UpdateIntegrity.parseChecksum("\(hash)  FinderRight-v1.1.10.zip\n"), hash)
            try assertEqual(UpdateIntegrity.parseChecksum(hash.uppercased()), hash, "大写应归一为小写")
        }

        runTest("UpdateIntegrity 拒绝非 SHA-256 内容") {
            try assertNil(UpdateIntegrity.parseChecksum(""), "空内容")
            try assertNil(UpdateIntegrity.parseChecksum("<!DOCTYPE html><html>Not Found</html>"), "HTML 错误页")
            try assertNil(UpdateIntegrity.parseChecksum(String(repeating: "a", count: 63)), "长度不足")
            try assertNil(UpdateIntegrity.parseChecksum(String(repeating: "g", count: 64)), "非十六进制")
        }

        runTest("UpdateIntegrity 解析 API 资源 digest") {
            let hash = String(repeating: "cd", count: 32)
            try assertEqual(UpdateIntegrity.parseAssetDigest("sha256:\(hash)"), hash)
            try assertEqual(UpdateIntegrity.parseAssetDigest("SHA256:\(hash.uppercased())"), hash, "前缀与哈希大小写都应容忍")
            try assertNil(UpdateIntegrity.parseAssetDigest(nil), "旧发布没有 digest 字段")
            try assertNil(UpdateIntegrity.parseAssetDigest(hash), "缺少算法前缀")
            try assertNil(UpdateIntegrity.parseAssetDigest("sha512:\(hash)"), "非 sha256 算法")
            try assertNil(UpdateIntegrity.parseAssetDigest("sha256:\(hash.dropLast())"), "长度不足")
        }

        // 22. 路径访问策略：在白名单之上拦截 FDA 专属数据
        runTest("PathAccessPolicy 放行常规用户目录") {
            let home = "/Users/tester", tmp = "/private/var/folders/xx/T"
            try assertTrue(PathAccessPolicy.isAllowed("/Users/tester/Documents/report.txt", role: .source, home: home, temporaryDirectory: tmp))
            try assertTrue(PathAccessPolicy.isAllowed("/Users/tester/Desktop", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(PathAccessPolicy.isAllowed("/Users/tester", role: .destination, home: home, temporaryDirectory: tmp), "home 作为新建 / 粘贴目标应放行")
            try assertTrue(PathAccessPolicy.isAllowed("/Users/tester/Library", role: .destination, home: home, temporaryDirectory: tmp), "~/Library 作为目标应放行")
            try assertTrue(PathAccessPolicy.isAllowed("/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a.txt", role: .source, home: home, temporaryDirectory: tmp), "iCloud Drive 是 Services 的正常场景")
            try assertTrue(PathAccessPolicy.isAllowed("/Volumes/E/data.bin", role: .source, home: home, temporaryDirectory: tmp))
            try assertTrue(PathAccessPolicy.isAllowed("/private/tmp/x", role: .source, home: home, temporaryDirectory: tmp))
            try assertTrue(PathAccessPolicy.isAllowed("/private/var/folders/xx/T/job/a.txt", role: .source, home: home, temporaryDirectory: tmp))
        }

        runTest("PathAccessPolicy 拦截 FDA 专属数据") {
            let home = "/Users/tester", tmp = "/private/var/folders/xx/T"
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/Library/Messages/chat.db", role: .source, home: home, temporaryDirectory: tmp))
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/Library/Messages", role: .destination, home: home, temporaryDirectory: tmp), "也不得写入受保护目录")
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/LIBRARY/messages/chat.db", role: .source, home: home, temporaryDirectory: tmp), "大小写变体")
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/Documents/../Library/Mail", role: .source, home: home, temporaryDirectory: tmp), "含 .. 的路径")
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/Library/Application Support/com.apple.TCC/TCC.db", role: .source, home: home, temporaryDirectory: tmp))
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/Pictures/Photos Library.photoslibrary/database", role: .source, home: home, temporaryDirectory: tmp), "照片图库")
            try assertTrue(!PathAccessPolicy.isAllowed("/Volumes/.timemachine/ABC/2026-10-01.backup/Users/tester", role: .source, home: home, temporaryDirectory: tmp), "APFS 时间机器快照")
            try assertTrue(!PathAccessPolicy.isAllowed("/Volumes/TM/Backups.backupdb/mac/Latest", role: .source, home: home, temporaryDirectory: tmp), "HFS+ 时间机器备份")
        }

        runTest("PathAccessPolicy 源路径不得是受保护目录的祖先") {
            let home = "/Users/tester", tmp = "/private/var/folders/xx/T"
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/Library", role: .source, home: home, temporaryDirectory: tmp), "压缩 ~/Library 会带走 Messages")
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester", role: .source, home: home, temporaryDirectory: tmp), "压缩整个 home")
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/Library/Application Support", role: .source, home: home, temporaryDirectory: tmp))
        }

        runTest("PathAccessPolicy 保留原有白名单边界") {
            let home = "/Users/tester", tmp = "/private/var/folders/xx/T"
            try assertTrue(!PathAccessPolicy.isAllowed("/etc/hosts", role: .source, home: home, temporaryDirectory: tmp))
            try assertTrue(!PathAccessPolicy.isAllowed("/Applications/Foo.app", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(!PathAccessPolicy.isAllowed("/System/Volumes/Data/Users/tester/Documents/a", role: .source, home: home, temporaryDirectory: tmp), "firmlink 路径不在白名单")
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/testerx/Documents/a", role: .source, home: home, temporaryDirectory: tmp), "前缀相同的其他用户目录")
        }

        // 23. Services 调用方启发式校验
        runTest("ServiceInvocationPolicy 只信任访达在前台") {
            try assertTrue(ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: "com.apple.finder"))
            try assertTrue(!ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: nil), "无前台应用")
            try assertTrue(!ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: "com.example.evil"), "其他应用")
            try assertTrue(!ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: "com.apple.Finder"), "bundle id 区分大小写，必须精确匹配")
        }

        runTest("Services 激活自身只允许粘贴确认，不直接信任调用方") {
            try assertTrue(ServiceInvocationPolicy.requiresServiceConfirmation(frontmostBundleId: "com.finderright.app", providerBundleId: "com.finderright.app"))
            try assertTrue(!ServiceInvocationPolicy.acceptsDestructiveService(frontmostBundleId: "com.finderright.app"))
            try assertTrue(!ServiceInvocationPolicy.requiresServiceConfirmation(frontmostBundleId: "com.apple.mail", providerBundleId: "com.finderright.app"))
            try assertTrue(!ServiceInvocationPolicy.requiresServiceConfirmation(frontmostBundleId: "com.apple.finder", providerBundleId: "com.finderright.app"))
            try assertTrue(!ServiceInvocationPolicy.requiresServiceConfirmation(frontmostBundleId: nil, providerBundleId: nil))
            try assertTrue(!ServiceInvocationPolicy.requiresServiceConfirmation(frontmostBundleId: "", providerBundleId: ""))
        }

        runTest("交互式文件服务只允许访达或自身前台进入确认框") {
            let provider = "com.finderright.app"
            try assertTrue(ServiceInvocationPolicy.acceptsInteractiveService(frontmostBundleId: "com.apple.finder", providerBundleId: provider))
            try assertTrue(ServiceInvocationPolicy.acceptsInteractiveService(frontmostBundleId: provider, providerBundleId: provider))
            try assertTrue(!ServiceInvocationPolicy.acceptsInteractiveService(frontmostBundleId: "com.apple.mail", providerBundleId: provider))
            try assertTrue(!ServiceInvocationPolicy.acceptsInteractiveService(frontmostBundleId: nil, providerBundleId: nil))
            try assertTrue(!ServiceInvocationPolicy.acceptsInteractiveService(frontmostBundleId: "", providerBundleId: ""))
        }

        runTest("内置文本模板保持原菜单顺序与安全扩展名") {
            let templates = BuiltInFileTemplates.text
            try assertEqual(templates.map(\.fileExtension), ["txt", "md", "html", "py", "sh", "json", "xml", "csv", "swift", "js"])
            try assertEqual(Set(templates.map(\.id)).count, templates.count)
            try assertTrue(templates.allSatisfy { !$0.name.isEmpty && SafeFileName.isValid(baseName: "untitled", ext: $0.fileExtension) })
            try assertTrue(templates.first { $0.fileExtension == "py" }!.content.hasPrefix("#!/usr/bin/env python3\n"))
            try assertEqual(templates.first { $0.fileExtension == "md" }!.content, "# Untitled\n\n")
        }

        runTest("Services 粘贴目标：单个文件夹即其本身，选中文件时取所在目录") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("file.txt")
            try Data("test".utf8).write(to: file)
            let link = root.appendingPathComponent("folder-link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            try assertEqual(ServiceInvocationPolicy.pasteDestination(for: [root]), root, "空白处传来的当前目录")
            try assertEqual(ServiceInvocationPolicy.pasteDestination(for: [link]), link, "目录符号链接仍由业务层校验真实路径")
            try assertNil(ServiceInvocationPolicy.pasteDestination(for: []))
            try assertNil(ServiceInvocationPolicy.pasteDestination(for: [root, link]), "分属不同目录时不能猜测目标")
            try assertEqual(ServiceInvocationPolicy.pasteDestination(for: [file])?.standardizedFileURL.path,
                            root.standardizedFileURL.path, "选中文件 → 粘贴到它所在的目录")
            try assertEqual(ServiceInvocationPolicy.pasteDestination(for: [file, link])?.standardizedFileURL.path,
                            root.standardizedFileURL.path, "同一目录下多选 → 该目录")
            try assertNil(ServiceInvocationPolicy.pasteDestination(for: [root.appendingPathComponent("missing")]))
            try assertNil(ServiceInvocationPolicy.pasteDestination(for: [URL(string: "https://example.com/folder")!]))
        }

        // 24. 角标探测门控：只有含剪切项的目录才值得探测 / 抢回
        runTest("BadgeOwnershipProbe 判断目录内是否有剪切项") {
            try assertTrue(BadgeOwnershipProbe.directory("/Users/t/Desktop", containsAnyOf: ["/Users/t/Desktop/a.txt"]))
            try assertTrue(BadgeOwnershipProbe.directory("/Users/t/Desktop/", containsAnyOf: ["/Users/t/Desktop/a.txt"]), "目录带尾斜杠")
            try assertTrue(!BadgeOwnershipProbe.directory("/Users/t/Desktop", containsAnyOf: ["/Users/t/Desktop/sub/a.txt"]), "只看直接子项")
            try assertTrue(!BadgeOwnershipProbe.directory("/Users/t", containsAnyOf: ["/Users/t/Desktop/a.txt"]), "祖先目录不算")
            try assertTrue(!BadgeOwnershipProbe.directory("/Users/t/Desktop", containsAnyOf: []), "空队列")
        }

        // 25. 剪切队列缓存：文件未变化时不重复读盘，变化后必须读到新内容
        runTest("CutQueueCache 反映队列文件的增删改") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            let cache = CutQueueCache(store: store)

            try assertTrue(cache.normalizedPaths().isEmpty, "无队列文件时为空")
            try store.write(["/tmp/a/one.txt"])
            try assertEqual(cache.normalizedPaths(), ["/tmp/a/one.txt"])
            try assertEqual(cache.normalizedPaths(), ["/tmp/a/one.txt"], "未变化时结果稳定")
            try store.write(["/tmp/a/one.txt", "/tmp/a/two/"])
            try assertEqual(cache.normalizedPaths(), ["/tmp/a/one.txt", "/tmp/a/two"], "改写后读到新内容，并去掉尾斜杠")
            store.clear()
            try assertTrue(cache.normalizedPaths().isEmpty, "清空后为空")
        }

        runTest("CutQueueCache 路径统一为 NFC") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            try store.write(["/tmp/cafe\u{0301}.txt"])   // NFD：e + 组合重音符
            let path = CutQueueCache(store: store).normalizedPaths().first ?? ""
            try assertEqual(path.unicodeScalars.count, "/tmp/caf\u{00E9}.txt".unicodeScalars.count, "应为预组合（NFC）形式")
        }

        // 26. 由扩展路径推出宿主 App，用于定向 IPC
        runTest("IPCBridge 由扩展路径推出宿主 App") {
            let appex = URL(fileURLWithPath: "/Applications/FinderRight.app/Contents/PlugIns/FinderRightSync.appex", isDirectory: true)
            try assertEqual(IPCBridge.containingAppURL(forExtensionAt: appex)?.path, "/Applications/FinderRight.app")
            try assertNil(IPCBridge.containingAppURL(forExtensionAt: URL(fileURLWithPath: "/tmp/FinderRightSync.appex", isDirectory: true)), "不在 PlugIns 下")
            try assertNil(IPCBridge.containingAppURL(forExtensionAt: URL(fileURLWithPath: "/Applications/FinderRight.app", isDirectory: true)), "本身不是 appex")
        }

        // 27. 压缩临时目录登记：正常移除、崩溃残留清扫、防篡改
        runTest("ScratchDirectoryRegistry 创建、移除与崩溃残留清扫") {
            let regDir = makeTempDirectory(), work = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: regDir)
                try? FileManager.default.removeItem(at: work)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: regDir)

            let a = try registry.makeScratchDirectory(in: work)
            try assertTrue(a.lastPathComponent.hasPrefix(ScratchDirectoryRegistry.namePrefix))
            try assertTrue(FileManager.default.fileExists(atPath: a.path))
            registry.remove(a)
            try assertTrue(!FileManager.default.fileExists(atPath: a.path), "remove 应删除目录")

            // 模拟崩溃：创建后没来得及 remove
            let b = try registry.makeScratchDirectory(in: work)
            try Data("x".utf8).write(to: b.appendingPathComponent("leftover.bin"))
            try assertEqual(ScratchDirectoryRegistry(registryDirectory: regDir).sweep(), 1)
            try assertTrue(!FileManager.default.fileExists(atPath: b.path), "sweep 应清理崩溃残留")
            try assertEqual(registry.sweep(), 0, "清扫后登记应已清空")
        }

        runTest("ScratchDirectoryRegistry 不删除被篡改登记指向的目录") {
            let regDir = makeTempDirectory(), work = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: regDir)
                try? FileManager.default.removeItem(at: work)
            }
            let victim = work.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            let important = victim.appendingPathComponent("important.txt")
            try Data("keep".utf8).write(to: important)
            // 带前缀但实为指向受害目录的符号链接
            let link = work.appendingPathComponent(ScratchDirectoryRegistry.namePrefix + "evil")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

            let tampered = try JSONSerialization.data(withJSONObject: [victim.path, link.path])
            try tampered.write(to: regDir.appendingPathComponent(ScratchDirectoryRegistry.fileName))
            _ = ScratchDirectoryRegistry(registryDirectory: regDir).sweep()

            try assertTrue(FileManager.default.fileExists(atPath: important.path), "被篡改的登记不得导致删除用户数据")
        }

        // 28. 压缩：退出码判定成功、失败不留残留、同名不覆盖
        runTest("ZipCompressor 单文件压缩") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: reg)
            let foo = work.appendingPathComponent("foo.txt")
            try Data("hi".utf8).write(to: foo)

            let zip = try ZipCompressor.compress(items: [foo], into: work, baseName: "foo", registry: registry)
            try assertEqual(zip.lastPathComponent, "foo.zip")
            try assertEqual(try zipEntries(zip), ["foo.txt"])
            try assertEqual(try directoryListing(work), ["foo.txt", "foo.zip"], "不得残留临时目录")
        }

        runTest("ZipCompressor 文件夹压缩保留顶层目录名") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let folder = work.appendingPathComponent("Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))

            let zip = try ZipCompressor.compress(items: [folder], into: work, baseName: "Folder",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: reg))
            try assertEqual(try zipEntries(zip), ["Folder/", "Folder/a.txt"])
        }

        runTest("ZipCompressor 多选压缩条目位于根部") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let a = work.appendingPathComponent("a.txt"), b = work.appendingPathComponent("b.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: b)

            let zip = try ZipCompressor.compress(items: [a, b], into: work, baseName: "Archive",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: reg))
            try assertEqual(zip.lastPathComponent, "Archive.zip")
            try assertEqual(try zipEntries(zip), ["a.txt", "b.txt"])
            try assertEqual(try directoryListing(work), ["Archive.zip", "a.txt", "b.txt"], "不得残留暂存目录")
        }

        runTest("ZipCompressor 同名不覆盖：已有文件与先后两次任务") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: reg)
            let existing = work.appendingPathComponent("foo.zip")
            try Data("sentinel".utf8).write(to: existing)
            let txt = work.appendingPathComponent("foo.txt"), md = work.appendingPathComponent("foo.md")
            try Data("t".utf8).write(to: txt)
            try Data("m".utf8).write(to: md)

            let first = try ZipCompressor.compress(items: [txt], into: work, baseName: "foo", registry: registry)
            let second = try ZipCompressor.compress(items: [md], into: work, baseName: "foo", registry: registry)
            try assertEqual(first.lastPathComponent, "foo 1.zip")
            try assertEqual(second.lastPathComponent, "foo 2.zip")
            try assertEqual(try String(contentsOf: existing, encoding: .utf8), "sentinel", "已有文件不得被覆盖")
            try assertEqual(try zipEntries(first), ["foo.txt"], "前一次任务的产物不得被后一次覆盖")
            try assertEqual(try zipEntries(second), ["foo.md"])
        }

        runTest("ZipCompressor 失败时不留残缺 zip 与临时目录") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            let box = work.appendingPathComponent("Box", isDirectory: true)
            let lockedInBox = box.appendingPathComponent("locked.txt")
            let lockedLoose = work.appendingPathComponent("locked2.txt")
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedInBox.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedLoose.path)
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: reg)
            try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
            try Data("ok".utf8).write(to: box.appendingPathComponent("ok.txt"))
            try Data("x".utf8).write(to: lockedInBox)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedInBox.path)

            // 单个文件夹内含不可读文件：压缩工具退出码非 0
            do {
                _ = try ZipCompressor.compress(items: [box], into: work, baseName: "Box", registry: registry)
                throw TestFailure(message: "含不可读文件时应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .toolFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
            try assertEqual(try directoryListing(work), ["Box"], "失败后不得留下 zip 或临时目录")

            // 多选中有不可读文件：同样整体失败，不产出少文件的 zip
            let plain = work.appendingPathComponent("plain.txt")
            try Data("p".utf8).write(to: plain)
            try Data("y".utf8).write(to: lockedLoose)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedLoose.path)
            do {
                _ = try ZipCompressor.compress(items: [plain, lockedLoose], into: work, baseName: "Archive", registry: registry)
                throw TestFailure(message: "多选含不可读文件时应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .toolFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
            try assertEqual(try directoryListing(work), ["Box", "locked2.txt", "plain.txt"], "失败后不得留下 zip 或临时目录")
        }

        runTest("ZipCompressor 干净 zip：中文名带 UTF-8 标志、排除 Mac 垃圾、保留正常隐藏文件") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let fm = FileManager.default
            let folder = work.appendingPathComponent("项目", isDirectory: true)
            try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try fm.createDirectory(at: folder.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("__MACOSX/._报告.txt"))
            try Data("r".utf8).write(to: folder.appendingPathComponent("报告.txt"))
            try Data("K=V".utf8).write(to: folder.appendingPathComponent(".env"))
            try Data().write(to: folder.appendingPathComponent(".DS_Store"))
            // 真正的 AppleDouble（魔数 0x00051607）应排除；同样以 ._ 开头的普通文件应保留
            try Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]).write(to: folder.appendingPathComponent("._报告.txt"))
            try Data("plain".utf8).write(to: folder.appendingPathComponent("._legit"))
            let csv = folder.appendingPathComponent("sub/数据.csv")
            try Data("1,2".utf8).write(to: csv)
            _ = setxattr(csv.path, "com.apple.metadata:kMDItemWhereFroms", "t", 1, 0, 0)

            let zip = try ZipCompressor.compress(items: [folder], into: work, baseName: "项目",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: reg))
            guard let entries = ZipProbe.centralDirectoryEntries(of: zip) else {
                throw TestFailure(message: "无法解析产物的中央目录")
            }
            let names = entries.map { String(decoding: $0.nameBytes, as: UTF8.self) }.sorted()
            try assertEqual(names, ["项目/", "项目/._legit", "项目/.env", "项目/sub/", "项目/sub/数据.csv", "项目/报告.txt"].sorted())
            for entry in entries where entry.nameBytes.contains(where: { $0 >= 0x80 }) {
                try assertTrue(entry.flags & 0x0800 != 0, "非 ASCII 文件名必须带 UTF-8 标志: \(String(decoding: entry.nameBytes, as: UTF8.self))")
            }
            try assertEqual(try directoryListing(work), ["项目", "项目.zip"], "不得残留临时目录")
        }

        runTest("ZipCompressor 多选可来自不同目录，同名则报错") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: reg)
            let d1 = work.appendingPathComponent("d1", isDirectory: true)
            let d2 = work.appendingPathComponent("d2", isDirectory: true)
            try FileManager.default.createDirectory(at: d2.appendingPathComponent("乙"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: d1, withIntermediateDirectories: true)
            let a = d1.appendingPathComponent("甲.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: d2.appendingPathComponent("乙/x.txt"))

            let zip = try ZipCompressor.compress(items: [a, d2.appendingPathComponent("乙")], into: d1,
                                                 baseName: "Archive", registry: registry)
            // zipinfo 在 C locale 下把 UTF-8 文件名显示成 ???，这里直接读中央目录
            let names = (ZipProbe.centralDirectoryEntries(of: zip) ?? []).map { String(decoding: $0.nameBytes, as: UTF8.self) }
            try assertEqual(names.sorted(), ["乙/", "乙/x.txt", "甲.txt"].sorted())

            let dup = d2.appendingPathComponent("甲.txt")
            try Data("c".utf8).write(to: dup)
            do {
                _ = try ZipCompressor.compress(items: [a, dup], into: d1, baseName: "Archive", registry: registry)
                throw TestFailure(message: "多选同名应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .stagingFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
        }

        runTest("ZipCompressor 子目录读不了时报错，不产出缺内容的 zip") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            let locked = work.appendingPathComponent("Box/locked", isDirectory: true)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: locked.appendingPathComponent("a.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            do {
                _ = try ZipCompressor.compress(items: [work.appendingPathComponent("Box")], into: work, baseName: "Box",
                                               registry: ScratchDirectoryRegistry(registryDirectory: reg))
                throw TestFailure(message: "子目录不可读时应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .stagingFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
            try assertEqual(try directoryListing(work), ["Box"], "失败后不得留下 zip 或临时目录")
        }

        runTest("ZipCompressor 选中 .app 等包时退回 ditto，保留 Mac 元数据") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let app = work.appendingPathComponent("Foo.app", isDirectory: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist = app.appendingPathComponent("Contents/Info.plist")
            try Data("<plist/>".utf8).write(to: plist)
            _ = setxattr(plist.path, "com.apple.metadata:kMDItemWhereFroms", "t", 1, 0, 0)

            let zip = try ZipCompressor.compress(items: [app], into: work, baseName: "Foo",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: reg))
            let names = (ZipProbe.centralDirectoryEntries(of: zip) ?? []).map { String(decoding: $0.nameBytes, as: UTF8.self) }
            try assertTrue(names.contains("Foo.app/Contents/Info.plist"))
            try assertTrue(names.contains { $0.hasPrefix("__MACOSX/") }, "ditto 应以 __MACOSX 保存扩展属性")
        }

        // 用系统 bsdtar 现场生成测试 zip，仓库里不放二进制样本
        func makeZip(_ name: String, in dir: URL, entries: [String], options: [String]) throws -> URL {
            let output = dir.appendingPathComponent(name)
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                               arguments: ["--format", "zip"] + options + ["-cf", output.path] + entries,
                                               currentDirectoryURL: dir)
            guard result.status == 0 else { throw TestFailure(message: "生成测试 zip 失败: \(result.stderr)") }
            return output
        }

        runTest("ZipProbe 识别加密条目与未声明编码的非 UTF-8 文件名") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("资料"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("资料/报告.txt"))

            let plain = try makeZip("plain.zip", in: work, entries: ["资料"], options: ["--options", "zip:hdrcharset=UTF-8"])
            try assertEqual(ZipProbe.inspect(plain), ZipProbe(hasEncryptedEntries: false, hasNonUTF8LegacyNames: false))

            let aes = try makeZip("aes.zip", in: work, entries: ["资料"],
                                  options: ["--options", "zip:encryption=aes256,zip:hdrcharset=UTF-8", "--passphrase", "pw"])
            try assertEqual(ZipProbe.inspect(aes)?.hasEncryptedEntries, true, "AES-256")

            let crypto = try makeZip("zc.zip", in: work, entries: ["资料"],
                                     options: ["--options", "zip:encryption=zipcrypt", "--passphrase", "pw"])
            try assertEqual(ZipProbe.inspect(crypto)?.hasEncryptedEntries, true, "ZipCrypto")

            // Windows 中文系统生成的 GBK 文件名、不设 UTF-8 标志
            let gbk = try makeZip("gbk.zip", in: work, entries: ["资料"], options: ["--options", "zip:hdrcharset=CP936"])
            try assertEqual(ZipProbe.inspect(gbk), ZipProbe(hasEncryptedEntries: false, hasNonUTF8LegacyNames: true))

            // 访达 / ditto 生成的包：不设标志，但文件名本身就是 UTF-8
            let dittoZip = work.appendingPathComponent("ditto.zip")
            let ditto = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                                              arguments: ["-c", "-k", "--keepParent", work.appendingPathComponent("资料").path, dittoZip.path])
            try assertEqual(ditto.status, 0, ditto.stderr)
            try assertEqual(ZipProbe.inspect(dittoZip), ZipProbe(hasEncryptedEntries: false, hasNonUTF8LegacyNames: false))
        }

        runTest("ZipProbe 无法解析时返回 nil") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try Data("hello".utf8).write(to: work.appendingPathComponent("a.txt"))
            let zip = try makeZip("a.zip", in: work, entries: ["a.txt"], options: [])

            let empty = work.appendingPathComponent("empty.zip")
            try Data().write(to: empty)
            try assertNil(ZipProbe.inspect(empty), "空文件")

            let garbage = work.appendingPathComponent("garbage.zip")
            try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: garbage)
            try assertNil(ZipProbe.inspect(garbage), "随机字节")

            let data = try Data(contentsOf: zip)
            let truncated = work.appendingPathComponent("truncated.zip")
            try data.prefix(data.count / 2).write(to: truncated)
            try assertNil(ZipProbe.inspect(truncated), "截断")

            try assertNil(ZipProbe.inspect(work.appendingPathComponent("missing.zip")), "文件不存在")
        }

        runTest("EncryptedZipExtractor 正确密码解出、错误密码识别并清空输出目录") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("资料"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("资料/报告.txt"))
            let out = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            for encryption in ["aes256", "zipcrypt"] {
                let zip = try makeZip("\(encryption).zip", in: work, entries: ["资料"],
                                      options: ["--options", "zip:encryption=\(encryption),zip:hdrcharset=UTF-8", "--passphrase", "right"])
                try assertEqual(try EncryptedZipExtractor.extract(zip, into: out, password: "wrong", legacyNames: false),
                                .wrongPassword, encryption)
                try assertEqual(try directoryListing(out), [], "错误密码后不得留下空壳文件: \(encryption)")

                try assertEqual(try EncryptedZipExtractor.extract(zip, into: out, password: "right", legacyNames: false),
                                .extracted, encryption)
                try assertEqual(try String(contentsOf: out.appendingPathComponent("资料/报告.txt"), encoding: .utf8), "hello")
                try FileManager.default.removeItem(at: out.appendingPathComponent("资料"))
            }
        }

        runTest("EncryptedZipExtractor 加密且 GBK 文件名的包按 CP936 还原中文名") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("资料"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("资料/报告.txt"))
            let zip = try makeZip("gbk.zip", in: work, entries: ["资料"],
                                  options: ["--options", "zip:encryption=zipcrypt,zip:hdrcharset=CP936", "--passphrase", "pw"])
            try assertEqual(ZipProbe.inspect(zip), ZipProbe(hasEncryptedEntries: true, hasNonUTF8LegacyNames: true))

            let out = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try assertEqual(try EncryptedZipExtractor.extract(zip, into: out, password: "pw", legacyNames: true), .extracted)
            try assertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("资料/报告.txt").path))
        }

        runTest("EncryptedZipExtractor 非密码问题如实报失败") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let bogus = work.appendingPathComponent("bogus.zip")
            try Data("not a zip at all".utf8).write(to: bogus)
            let out = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let outcome = try EncryptedZipExtractor.extract(bogus, into: out, password: "pw", legacyNames: false)
            guard case .failed = outcome else { throw TestFailure(message: "应为 failed，实际 \(outcome)") }
            try assertTrue(!EncryptedZipExtractor.indicatesWrongPassword("tar: Error opening archive: Unrecognized archive format"))
            try assertTrue(EncryptedZipExtractor.indicatesWrongPassword("a.txt: Incorrect passphrase: Unknown error: -1"))
            try assertTrue(EncryptedZipExtractor.indicatesWrongPassword("a.txt: ZIP bad CRC: 0x1234 should be 0x5678"))
        }

        runTest("ProcessRunner 子进程 stdin 接 /dev/null，不会等待输入") {
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [])
            try assertEqual(result.status, 0)
        }

        // 29. .xz 进程内解压（替代外部 xz / python3）
        // 由 Python lzma 以标准 xz 格式生成，内容为 "hello finderright\n"
        let xzFixtureBase64 = "/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQARaGVsbG8gZmluZGVycmlnaHQKAAAAdqeazgeF0CQAASoSSwhUvB+2830BAAAAAARZWg=="

        runTest("XZDecompressor 解压标准 .xz 文件") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let src = work.appendingPathComponent("hello.txt.xz")
            try Data(base64Encoded: xzFixtureBase64)!.write(to: src)
            let out = work.appendingPathComponent("hello.txt")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try XZDecompressor.decompress(from: src, to: handle)
            try handle.close()
            try assertEqual(try String(contentsOf: out, encoding: .utf8), "hello finderright\n")
        }

        runTest("XZDecompressor 多块输入往返一致") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let raw = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) })
            var encoded = Data()
            let encoder = try OutputFilter(.compress, using: .lzma) { if let d = $0 { encoded.append(d) } }
            try encoder.write(raw)
            try encoder.finalize()
            let src = work.appendingPathComponent("big.bin.xz")
            try encoded.write(to: src)
            let out = work.appendingPathComponent("big.bin")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try XZDecompressor.decompress(from: src, to: handle, chunkSize: 4096)
            try handle.close()
            try assertTrue(try Data(contentsOf: out) == raw, "小块读取下内容必须完全一致")
        }

        runTest("XZDecompressor 拒绝损坏、非 xz 与空输入") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let cases: [(String, Data)] = [
                ("截断", Data(base64Encoded: xzFixtureBase64)!.prefix(30)),
                ("非 xz", Data("plain text, not xz".utf8)),
                ("空文件", Data()),
            ]
            for (label, content) in cases {
                let src = work.appendingPathComponent("bad.xz")
                try content.write(to: src)
                let out = work.appendingPathComponent("bad.out")
                FileManager.default.createFile(atPath: out.path, contents: nil)
                let handle = try FileHandle(forWritingTo: out)
                defer { try? handle.close() }
                do {
                    try XZDecompressor.decompress(from: src, to: handle)
                    throw TestFailure(message: "\(label)：应当抛错")
                } catch is TestFailure {
                    throw TestFailure(message: "\(label)：应当抛错")
                } catch {
                    // 预期：Compression 框架报 invalidData
                }
            }
        }

        // 30. 后台任务跟踪：退出前可等待完成
        runTest("BackgroundJobs 跟踪在途任务并可等待完成") {
            let jobs = BackgroundJobs()
            let queue = DispatchQueue(label: "test.jobs")
            try assertTrue(jobs.isIdle, "初始空闲")
            jobs.run(on: queue) { Thread.sleep(forTimeInterval: 0.3) }
            try assertTrue(!jobs.isIdle, "任务进行中不空闲")
            try assertTrue(jobs.waitUntilIdle(timeout: 5), "应在超时前完成")
            try assertTrue(jobs.isIdle, "完成后空闲")
        }

        runTest("BackgroundJobs 等待超时返回 false") {
            let jobs = BackgroundJobs()
            let queue = DispatchQueue(label: "test.jobs.timeout")
            jobs.run(on: queue) { Thread.sleep(forTimeInterval: 1) }
            try assertTrue(!jobs.waitUntilIdle(timeout: 0.1), "任务未完成时应超时")
            try assertTrue(jobs.waitUntilIdle(timeout: 5), "最终应完成")
        }

        // 31. 代码签名校验（以系统自带、Apple 签名的 /bin/ls 和测试进程自身为样本）
        runTest("CodeSignatureCheck 读取签名规则与证书指纹") {
            let ls = URL(fileURLWithPath: "/bin/ls")
            let requirement = CodeSignatureCheck.designatedRequirement(ofCodeAt: ls) ?? ""
            try assertTrue(requirement.contains("com.apple.ls"), "签名规则应包含标识: \(requirement)")
            let leaf = CodeSignatureCheck.leafCertificateSHA1(ofCodeAt: ls) ?? ""
            try assertEqual(leaf.count, 40, "SHA-1 指纹应为 40 位十六进制")
            try assertTrue(CodeSignatureCheck.codeAt(ls, satisfies: "certificate leaf = H\"\(leaf)\""), "应满足自己的叶子证书规则")
            try assertTrue(CodeSignatureCheck.codeAt(ls, satisfies: requirement), "应满足自己的签名规则")
        }

        runTest("CodeSignatureCheck 拒绝标识不符、规则无效与内容被改动的代码") {
            let ls = URL(fileURLWithPath: "/bin/ls")
            try assertTrue(!CodeSignatureCheck.codeAt(ls, satisfies: "identifier \"com.finderright.app\""), "标识不符")
            try assertTrue(!CodeSignatureCheck.codeAt(ls, satisfies: "不是合法的规则"), "规则文本无效")
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let modified = work.appendingPathComponent("ls-modified")
            var bytes = try Data(contentsOf: ls)
            bytes[bytes.count / 2] ^= 0xFF
            try bytes.write(to: modified)
            try assertTrue(!CodeSignatureCheck.codeAt(modified, satisfies: "identifier \"com.apple.ls\" and anchor apple"), "内容被改动后签名应失效")
        }

        runTest("CodeSignatureCheck 识别 ad-hoc 签名") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let copy = work.appendingPathComponent("ls-adhoc")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
            let sign = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                                             arguments: ["-s", "-", "--force", copy.path])
            try assertEqual(sign.status, 0, "ad-hoc 签名失败: \(sign.stderr)")
            try assertNil(CodeSignatureCheck.leafCertificateSHA1(ofCodeAt: copy), "ad-hoc 签名没有证书")
            try assertTrue(CodeSignatureCheck.designatedRequirement(ofCodeAt: copy)?.hasPrefix("cdhash") == true, "ad-hoc 签名规则应为 cdhash")
        }

        runTest("CodeSignatureCheck 按 audit token 校验运行中的进程") {
            guard let token = currentProcessAuditToken(), let me = Bundle.main.executableURL else {
                throw TestFailure(message: "无法取得当前进程的 audit token 或可执行文件路径")
            }
            try assertTrue(CodeSignatureCheck.process(auditToken: token, satisfiesDesignatedRequirementOf: me), "当前进程应满足自身可执行文件的签名规则")
            try assertTrue(!CodeSignatureCheck.process(auditToken: token, satisfiesDesignatedRequirementOf: URL(fileURLWithPath: "/bin/ls")), "不应满足其他程序的签名规则")
            try assertTrue(!CodeSignatureCheck.process(auditToken: Data(count: 32), satisfiesDesignatedRequirementOf: me), "无效的 audit token 应被拒绝")
        }

        // 32. 更新包签名规则：同一证书 + 标识不变
        runTest("UpdateIntegrity 生成新版本签名规则") {
            let rules = UpdateIntegrity.signingRequirements(leafCertificateSHA1: "ABCDEF")
            try assertEqual(rules.app, "identifier \"com.finderright.app\" and certificate leaf = H\"ABCDEF\"")
            try assertEqual(rules.appex, "identifier \"com.finderright.app.sync\" and certificate leaf = H\"ABCDEF\"")
        }

        runTest("UpdateIntegrity 签名规则同时约束证书与标识") {
            let ls = URL(fileURLWithPath: "/bin/ls")
            let leaf = CodeSignatureCheck.leafCertificateSHA1(ofCodeAt: ls) ?? ""
            // /bin/ls 与规则证书相同但标识不同，必须被拒绝：只比证书会放行同一证书签出的其他程序
            try assertTrue(!CodeSignatureCheck.codeAt(ls, satisfies: UpdateIntegrity.signingRequirements(leafCertificateSHA1: leaf).app))
            // 同样写法、换成 /bin/ls 自己的标识则应通过：确认规则模板本身语法有效
            try assertTrue(CodeSignatureCheck.codeAt(ls, satisfies: "identifier \"com.apple.ls\" and certificate leaf = H\"\(leaf)\""))
        }

        // 33. IPC execute URL：携带请求文件摘要
        runTest("IPCBridge execute URL 携带请求摘要并可往返解析") {
            let id = UUID().uuidString
            let data = Data("{\"id\":\"x\"}".utf8)
            guard let url = IPCBridge.executeURL(id: id, requestData: data) else {
                throw TestFailure(message: "URL 构造失败")
            }
            try assertTrue(url.absoluteString.hasPrefix("finderright://execute?id="), url.absoluteString)
            let parsed = IPCBridge.parseExecuteURL(url)
            try assertEqual(parsed?.id, id)
            try assertEqual(parsed?.digest, IPCBridge.requestDigest(data))
            try assertEqual(IPCBridge.requestDigest(Data("abc".utf8)),
                            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 标准测试向量")
        }

        runTest("IPCBridge 拒绝不合规的 execute URL") {
            let id = UUID().uuidString, digest = String(repeating: "a", count: 64)
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "finderright://execute?id=\(id)")!), "旧格式（无摘要）")
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "finderright://execute?id=not-a-uuid&digest=\(digest)")!), "id 不是 UUID")
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "finderright://execute?id=\(id)&digest=xyz")!), "摘要格式错误")
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "finderright://settings?id=\(id)&digest=\(digest)")!), "host 不是 execute")
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "https://execute?id=\(id)&digest=\(digest)")!), "scheme 不符")
        }

        // 34. 下沉到 Kit 的小工具
        runTest("ArchiveKind 识别可解压文件") {
            for name in ["a.zip", "A.ZIP", "a.tar.gz", "a.tgz", "a.tar.bz2", "a.xz", "a.7z", "a.rar", "a.tar"] {
                try assertTrue(ArchiveKind.isArchive(fileName: name), name)
            }
            for name in ["a.txt", "zip", "a.zipx", "a.gzip"] {
                try assertTrue(!ArchiveKind.isArchive(fileName: name), name)
            }
        }

        runTest("BundleIdentifier 校验字符集与长度") {
            try assertTrue(BundleIdentifier.isValid("com.mitchellh.ghostty"))
            try assertTrue(BundleIdentifier.isValid("dev.warp.Warp-Stable"))
            try assertTrue(!BundleIdentifier.isValid(""), "空")
            try assertTrue(!BundleIdentifier.isValid("com.example app"), "含空格")
            try assertTrue(!BundleIdentifier.isValid("com.example/../x"), "含斜杠")
            try assertTrue(!BundleIdentifier.isValid(String(repeating: "a", count: 129)), "超长")
        }

        runTest("UniqueName 依次编号避开已有文件") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try assertEqual(UniqueName.fileURL(baseName: "untitled", ext: "txt", in: dir).lastPathComponent, "untitled.txt")
            try Data().write(to: dir.appendingPathComponent("untitled.txt"))
            try assertEqual(UniqueName.fileURL(baseName: "untitled", ext: "txt", in: dir).lastPathComponent, "untitled 1.txt")
            try Data().write(to: dir.appendingPathComponent("untitled 1.txt"))
            try assertEqual(UniqueName.fileURL(baseName: "untitled", ext: "txt", in: dir).lastPathComponent, "untitled 2.txt")
            try assertEqual(UniqueName.fileURL(baseName: "README", ext: "", in: dir).lastPathComponent, "README", "无后缀")
            try Data().write(to: dir.appendingPathComponent("README"))
            try assertEqual(UniqueName.fileURL(baseName: "README", ext: "", in: dir).lastPathComponent, "README 1", "无后缀时同样编号")
        }

        // MARK: - ExtractedOutput（解压产物落位）

        /// 在 work 下建一个模拟的解压输出目录，按 names 创建内容（以 / 结尾为目录）
        func makeExtractedRoot(in work: URL, _ names: [String]) throws -> URL {
            let root = work.appendingPathComponent(".scratch/out", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in names {
                let url = root.appendingPathComponent(name)
                if name.hasSuffix("/") {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try Data("x".utf8).write(to: url.appendingPathComponent("inner.txt"))
                } else {
                    try Data("x".utf8).write(to: url)
                }
            }
            return root
        }

        runTest("ExtractedOutput 顶层唯一文件夹直接放出，忽略 __MACOSX 与 .DS_Store") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let root = try makeExtractedRoot(in: work, ["foo/", "__MACOSX/", ".DS_Store"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "foo")
            try assertEqual(placed.lastPathComponent, "foo")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("inner.txt").path), "不应出现 foo/foo 嵌套")
        }

        runTest("ExtractedOutput 唯一文件夹重名时编号为 -2") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("foo"), withIntermediateDirectories: false)
            let root = try makeExtractedRoot(in: work, ["foo/"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "foo")
            try assertEqual(placed.lastPathComponent, "foo-2")
        }

        runTest("ExtractedOutput 唯一文件重名时保留扩展名") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try Data().write(to: work.appendingPathComponent("report.pdf"))
            let root = try makeExtractedRoot(in: work, ["report.pdf"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "report")
            try assertEqual(placed.lastPathComponent, "report-2.pdf")
        }

        runTest("ExtractedOutput 多项时整体放入同名文件夹") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("bundle"), withIntermediateDirectories: false)
            let root = try makeExtractedRoot(in: work, ["a.txt", "b/"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "bundle")
            try assertEqual(placed.lastPathComponent, "bundle-2", "已有同名文件夹时编号")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("a.txt").path))
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("b/inner.txt").path))
        }

        runTest("ExtractedOutput 唯一项为隐藏文件或空包时仍放入文件夹") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let hidden = try makeExtractedRoot(in: work, [".env"])
            let placedHidden = try ExtractedOutput.place(extractedRoot: hidden, into: work, folderName: "cfg")
            try assertEqual(placedHidden.lastPathComponent, "cfg")
            try assertTrue(FileManager.default.fileExists(atPath: placedHidden.appendingPathComponent(".env").path))

            let empty = try makeExtractedRoot(in: work, [])
            let placedEmpty = try ExtractedOutput.place(extractedRoot: empty, into: work, folderName: "empty")
            try assertEqual(placedEmpty.lastPathComponent, "empty")
        }

        runTest("ExtractedOutput 真实 ditto 往返：foo.zip 解出 foo 而非 foo/foo") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let folder = work.appendingPathComponent("foo", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
            let zip = try ZipCompressor.compress(items: [folder], into: work, baseName: "foo",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: work))
            try FileManager.default.removeItem(at: folder)

            let root = work.appendingPathComponent(".scratch/out", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                                               arguments: ["-x", "-k", zip.path, root.path])
            try assertEqual(result.status, 0, result.stderr)
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "foo")
            try assertEqual(placed.lastPathComponent, "foo")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("a.txt").path))
        }

        runTest("ExtractedOutput 候选名编号规则") {
            try assertEqual(ExtractedOutput.candidateName("foo", keepExtension: false, attempt: 0), "foo")
            try assertEqual(ExtractedOutput.candidateName("foo", keepExtension: false, attempt: 1), "foo-2")
            try assertEqual(ExtractedOutput.candidateName("v1.2", keepExtension: false, attempt: 2), "v1.2-3", "普通文件夹不拆扩展名")
            try assertEqual(ExtractedOutput.candidateName("Foo.app", keepExtension: true, attempt: 1), "Foo-2.app")
            try assertEqual(ExtractedOutput.candidateName("README", keepExtension: true, attempt: 1), "README-2")
        }

        // MARK: - RecentOperations（最近操作记录）

        runTest("RecentOperations 新记录在前、超出容量丢弃最旧、统计未查看的失败") {
            let ops = RecentOperations(capacity: 3)
            ops.record(OperationRecord(kind: .compress, subject: "a"))
            ops.record(OperationRecord(kind: .decompress, subject: "b", failure: "坏包"))
            ops.record(OperationRecord(kind: .paste, subject: "c"))
            ops.record(OperationRecord(kind: .compress, subject: "d", failure: "磁盘满"))
            try assertEqual(ops.records.map(\.subject), ["d", "c", "b"])
            try assertEqual(ops.unseenFailureCount, 2)
            ops.markFailuresSeen()
            try assertEqual(ops.unseenFailureCount, 0)
            try assertEqual(ops.records.count, 3, "标记已查看不删除记录")
            ops.clear()
            try assertTrue(ops.records.isEmpty)
        }

        runTest("RecentOperations 已取消不算成功，也不计入未查看的失败") {
            let ops = RecentOperations(capacity: 3)
            let cancelled = OperationRecord(kind: .decompress, subject: "secret.zip", cancelled: true)
            try assertTrue(!cancelled.succeeded, "已取消不算成功")
            ops.record(cancelled)
            try assertEqual(ops.unseenFailureCount, 0)
            try assertEqual(ops.records.first?.cancelled, true)
        }

        runTest("RecentOperations 关闭时不记录，关闭即清空已有记录") {
            try assertTrue(!RecentOperations.shared.isEnabled, "共享实例默认关闭")
            let ops = RecentOperations(capacity: 3, isEnabled: false)
            ops.record(OperationRecord(kind: .compress, subject: "a", failure: "坏包"))
            try assertTrue(ops.records.isEmpty)
            try assertEqual(ops.unseenFailureCount, 0)
            ops.isEnabled = true
            ops.record(OperationRecord(kind: .compress, subject: "b", failure: "坏包"))
            try assertEqual(ops.records.map(\.subject), ["b"])
            ops.isEnabled = false
            try assertTrue(ops.records.isEmpty, "关闭时丢弃已有记录")
            try assertEqual(ops.unseenFailureCount, 0, "关闭时撤掉失败提示")
        }

        runTest("OperationRecord.summary 压缩长错误输出") {
            try assertTrue(OperationRecord.summary(of: "  \n \n") == nil, "全空返回 nil")
            try assertEqual(OperationRecord.summary(of: "\n  tar: bad header  \n"), "tar: bad header")
            try assertEqual(OperationRecord.summary(of: "1\n2\n3\n4\n5"), "1\n2\n3\n…", "超过行数时标出省略")
            let long = String(repeating: "x", count: 400)
            try assertEqual(OperationRecord.summary(of: long)?.count, 301, "截断到上限并加省略号")
        }

        runTest("OperationRecord.truncatedSubject 按显示宽度从中间截断") {
            try assertEqual(OperationRecord.truncatedSubject("report.pdf"), "report.pdf", "未超宽原样返回")
            try assertEqual(OperationRecord.truncatedSubject("3 个项目"), "3 个项目")
            let latin = OperationRecord.truncatedSubject("quarterly-business-review-final-version-3.pptx", maxWidth: 20)
            try assertEqual(latin, "quarterly-bu…-3.pptx", "开头多、结尾少，保留扩展名")
            let cjk = OperationRecord.truncatedSubject("2026年第三季度项目汇报材料-最终版-v3.pptx", maxWidth: 32)
            try assertTrue(cjk.hasPrefix("2026年第三季度") && cjk.hasSuffix("-v3.pptx"), "全角字符按 2 计宽：\(cjk)")
            try assertTrue(cjk.contains("…"))
            let widthOf: (String) -> Int = { $0.reduce(0) { $0 + (($1.unicodeScalars.first!.value >= 0x2E80) ? 2 : 1) } }
            try assertTrue(widthOf(cjk) <= 32, "截断后不超过上限：\(widthOf(cjk))")
        }

        runTest("OfficeTemplate 只接受白名单内的模板 id") {
            try assertEqual(OfficeTemplate.allCases.map(\.fileExtension), ["docx", "xlsx", "pptx"])
            try assertTrue(OfficeTemplate.allCases.allSatisfy { $0.titleKey.hasSuffix("(.\($0.fileExtension))") }, "显示名须与扩展名一致")
            try assertEqual(OfficeTemplate(rawValue: "docx"), .docx)
            try assertTrue(OfficeTemplate(rawValue: "doc") == nil, "旧二进制格式不在白名单")
            try assertTrue(OfficeTemplate(rawValue: "DOCX") == nil, "大小写必须精确匹配")
            try assertTrue(OfficeTemplate(rawValue: "../docx") == nil, "路径片段不会被当作模板 id")
        }

        // MARK: - 复制路径格式

        runTest("PathFormatter 各格式输出") {
            let home = "/Users/me"
            let file = URL(fileURLWithPath: "/Users/me/Documents/a b.txt")
            let dir = URL(fileURLWithPath: "/Users/me/项目", isDirectory: true)
            try assertEqual(PathFormatter.string(for: [file], format: .absolute, home: home), "/Users/me/Documents/a b.txt")
            try assertEqual(PathFormatter.string(for: [file], format: .tilde, home: home), "~/Documents/a b.txt")
            try assertEqual(PathFormatter.string(for: [file], format: .name, home: home), "a b.txt")
            try assertEqual(PathFormatter.string(for: [file], format: .shellEscaped, home: home), "'/Users/me/Documents/a b.txt'")
            try assertEqual(PathFormatter.string(for: [file], format: .fileURL, home: home), "file:///Users/me/Documents/a%20b.txt")
            try assertEqual(PathFormatter.string(for: [dir], format: .fileURL, home: home),
                            "file:///Users/me/%E9%A1%B9%E7%9B%AE/", "目录 URL 以 / 结尾，中文按 UTF-8 编码")
        }

        runTest("PathFormatter ~ 只替换主目录前缀") {
            let home = "/Users/me"
            try assertEqual(PathFormatter.string(for: [URL(fileURLWithPath: "/Users/me")], format: .tilde, home: home), "~")
            try assertEqual(PathFormatter.string(for: [URL(fileURLWithPath: "/Users/meow/x")], format: .tilde, home: home),
                            "/Users/meow/x", "同前缀的其他用户目录不能被替换")
            try assertEqual(PathFormatter.string(for: [URL(fileURLWithPath: "/Volumes/E/x")], format: .tilde, home: home), "/Volumes/E/x")
            try assertEqual(PathFormatter.string(for: [URL(fileURLWithPath: "/Users/me/x")], format: .tilde, home: "/Users/me/"), "~/x",
                            "主目录带结尾斜杠也能识别")
        }

        runTest("PathFormatter 多选的连接方式") {
            let urls = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b c")]
            try assertEqual(PathFormatter.string(for: urls, format: .absolute, home: "/Users/me"), "/tmp/a\n/tmp/b c", "默认每行一项")
            try assertEqual(PathFormatter.string(for: urls, format: .shellEscaped, home: "/Users/me"), "/tmp/a '/tmp/b c'",
                            "终端格式以空格连接，安全路径不加引号")
        }

        runTest("PathFormatter.shellQuoted 处理单引号与特殊字符") {
            try assertEqual(PathFormatter.shellQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
            try assertEqual(PathFormatter.shellQuoted("/tmp/$HOME"), "'/tmp/$HOME'", "$ 必须被引起来，防止展开")
            try assertEqual(PathFormatter.shellQuoted("/tmp/中文"), "'/tmp/中文'", "非 ASCII 一律加引号")
            try assertEqual(PathFormatter.shellQuoted(""), "''")
        }

        runTest("复制文件名保留完整名称，多选每行一项") {
            let urls = [
                URL(fileURLWithPath: "/tmp/中文 报告.tar.gz"),
                URL(fileURLWithPath: "/tmp/.gitignore"),
                URL(fileURLWithPath: "/tmp/无扩展名"),
                URL(fileURLWithPath: "/tmp/项目 文件夹", isDirectory: true),
            ]
            try assertEqual(PathFormatter.string(for: urls, format: .name, home: "/Users/me"),
                            "中文 报告.tar.gz\n.gitignore\n无扩展名\n项目 文件夹")
            try assertEqual(PathFormatter.string(for: [], format: .name, home: "/Users/me"), "")
        }

        runTest("SharedConfig.copyPathFormat 默认绝对路径并可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertEqual(config.copyPathFormat, .absolute)
            config.copyPathFormat = .tilde
            try assertEqual(SharedConfig(fileURL: url).copyPathFormat, .tilde, "重新读取后保持")
        }

        // MARK: - 菜单顺序

        runTest("normalizedOrder 未保存时等于默认顺序") {
            try assertEqual(MenuFeatureCatalog.normalizedOrder([], defaults: ["a", "b", "c"]), ["a", "b", "c"])
            try assertEqual(MenuFeatureCatalog.ordered(by: []).map(\.id), MenuFeatureCatalog.all.map(\.id))
        }

        runTest("normalizedOrder 保留用户顺序，丢弃未知与重复 id") {
            try assertEqual(MenuFeatureCatalog.normalizedOrder(["c", "x", "a", "c", "b"], defaults: ["a", "b", "c"]), ["c", "a", "b"])
        }

        runTest("normalizedOrder 新增功能插在默认顺序中的前一项之后") {
            // 用户把 c 调到最前；新版本在 a 与 b 之间新增 n、在开头新增 z
            try assertEqual(MenuFeatureCatalog.normalizedOrder(["c", "a", "b"], defaults: ["z", "a", "n", "b", "c"]),
                            ["z", "c", "a", "n", "b"])
        }

        runTest("复制文件名默认开启，升级保留菜单顺序并支持关闭") {
            let oldSaved = [MenuFeatureCatalog.toggleHidden] + MenuFeatureCatalog.all.map(\.id).filter {
                $0 != MenuFeatureCatalog.copyFileName && $0 != MenuFeatureCatalog.toggleHidden
            }
            let ids = MenuFeatureCatalog.ordered(by: oldSaved).map(\.id)
            let copyPath = ids.firstIndex(of: MenuFeatureCatalog.copyPath)!
            try assertEqual(ids[copyPath + 1], MenuFeatureCatalog.copyFileName)
            try assertEqual(ids.filter { $0 != MenuFeatureCatalog.copyFileName }, oldSaved)

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.isActionEnabled(MenuFeatureCatalog.copyFileName))
            config.setActionEnabled(MenuFeatureCatalog.copyFileName, enabled: false)
            try assertTrue(!SharedConfig(fileURL: url).isActionEnabled(MenuFeatureCatalog.copyFileName))
        }

        runTest("SharedConfig 压缩 / 解压默认关闭，显式开启后保持开启") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(!config.isActionEnabled(MenuFeatureCatalog.compress))
            try assertTrue(!config.isActionEnabled(MenuFeatureCatalog.decompress))
            try assertTrue(config.isActionEnabled(MenuFeatureCatalog.newFile))
            config.setActionEnabled(MenuFeatureCatalog.compress, enabled: true)
            let reloaded = SharedConfig(fileURL: url)
            try assertTrue(reloaded.isActionEnabled(MenuFeatureCatalog.compress))
            try assertTrue(!reloaded.isActionEnabled(MenuFeatureCatalog.decompress))
        }

        runTest("SharedConfig.menuOrder 默认为空，清空时恢复默认") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.menuOrder.isEmpty)
            config.menuOrder = ["feature.cut", "feature.copyPath"]
            try assertEqual(SharedConfig(fileURL: url).menuOrder, ["feature.cut", "feature.copyPath"])
            config.menuOrder = []
            try assertTrue(SharedConfig(fileURL: url).menuOrder.isEmpty)
        }

        runTest("打开路径接受绝对路径、主目录与目录符号链接") {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let directory = home.appendingPathComponent("中文 目录", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let spaced = home.appendingPathComponent("目录尾部空格 ", isDirectory: true)
            try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
            let link = home.appendingPathComponent("目录链接")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
            func dir(_ input: String) throws -> String {
                guard case .directory(let url) = try DirectoryPath.resolve(input, home: home.path) else {
                    throw TestFailure(message: "应识别为目录：\(input)")
                }
                return url.path
            }
            try assertEqual(try dir(directory.path), directory.path)
            try assertEqual(try dir(spaced.path), spaced.path, "不修剪真实目录名中的空格")
            try assertEqual(try dir("~/中文 目录"), directory.path)
            try assertEqual(try dir("~"), home.path)
            try assertEqual(try dir(link.path), link.path)
            try assertEqual(try dir("/"), "/", "允许前往主目录以外的目录")
        }

        runTest("打开路径把文件识别为文件，并清理复制来的引号、空白、file URL 与转义") {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let folder = home.appendingPathComponent("项目 A", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("报告 (终版).txt")
            try Data().write(to: file)
            let encoded = URL(fileURLWithPath: file.path).absoluteString
            let inputs = [
                file.path,
                "  \(file.path)\n",
                "'\(file.path)'",
                "\"\(file.path)\"",
                "“\(file.path)”",
                encoded,
                " \(encoded) ",
                file.path.replacingOccurrences(of: " ", with: "\\ ")
                    .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)"),
                "~/项目 A/报告 (终版).txt",
                "\"~/项目 A/报告 (终版).txt\"",
            ]
            for input in inputs {
                guard case .file(let url) = try DirectoryPath.resolve(input, home: home.path) else {
                    throw TestFailure(message: "应识别为文件：\(input)")
                }
                try assertEqual(url.path, file.path, "输入：\(input)")
            }
            guard case .directory(let url) = try DirectoryPath.resolve("'\(folder.path)/'\n", home: home.path) else {
                throw TestFailure(message: "带引号的目录应识别为目录")
            }
            try assertEqual(url.standardizedFileURL.path, folder.path)
        }

        runTest("打开路径拒绝相对路径、空输入与不存在的路径") {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let cases: [(String, DirectoryPath.ValidationError)] = [
                ("", .invalidPath), ("   ", .invalidPath), ("''", .invalidPath),
                ("Documents", .invalidPath), ("~other/Documents", .invalidPath),
                ("https://example.com/a", .invalidPath),
                (home.path + "\0ignored", .invalidPath),
                (home.appendingPathComponent("missing").path, .unavailable),
                ("'\(home.appendingPathComponent("missing").path)'", .unavailable),
            ]
            for (input, expected) in cases {
                do {
                    _ = try DirectoryPath.resolve(input, home: home.path)
                    throw TestFailure(message: "应拒绝输入：\(input)")
                } catch let error as DirectoryPath.ValidationError {
                    try assertEqual(error, expected, "输入：\(input)")
                }
            }
        }

        runTest("常用目录只接受目录，普通文件报不是目录") {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let file = home.appendingPathComponent("报告.txt")
            try Data().write(to: file)
            try assertEqual(try DirectoryPath.url(for: home.path, home: home.path).path, home.path)
            do {
                _ = try DirectoryPath.url(for: file.path, home: home.path)
                throw TestFailure(message: "应拒绝普通文件")
            } catch let error as DirectoryPath.ValidationError {
                try assertEqual(error, .notDirectory)
            }
        }

        runTest("前往目录升级后默认显示并保留原菜单顺序") {
            let oldSaved = MenuFeatureCatalog.all.map(\.id).filter { $0 != MenuFeatureCatalog.goToDirectory }.reversed()
            let ids = MenuFeatureCatalog.ordered(by: Array(oldSaved)).map(\.id)
            let predId = MenuFeatureCatalog.all[MenuFeatureCatalog.all.firstIndex(where: { $0.id == MenuFeatureCatalog.goToDirectory })! - 1].id
            let predIndex = ids.firstIndex(of: predId)!
            try assertEqual(ids[predIndex + 1], MenuFeatureCatalog.goToDirectory)
            try assertEqual(ids.filter { $0 != MenuFeatureCatalog.goToDirectory }, Array(oldSaved))

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.isActionEnabled(MenuFeatureCatalog.goToDirectory))
            config.setActionEnabled(MenuFeatureCatalog.goToDirectory, enabled: false)
            try assertTrue(!SharedConfig(fileURL: url).isActionEnabled(MenuFeatureCatalog.goToDirectory))
        }

        // MARK: - 常用目录：移动到 / 复制到

        runTest("升级前保存的顺序：新增的移动到/复制到出现在粘贴之后") {
            let oldSaved = ["feature.toggleHidden", "feature.newFile", "feature.copyPath", "feature.openTerminal",
                            "feature.openEditor", "feature.cut", "feature.paste", "feature.compress", "feature.decompress"]
            let ids = MenuFeatureCatalog.ordered(by: oldSaved).map(\.id)
            try assertEqual(ids.first, "feature.toggleHidden", "用户的自定义顺序保持不变")
            let paste = ids.firstIndex(of: "feature.paste")!
            try assertEqual(Array(ids[paste...paste + 2]), ["feature.paste", "feature.moveTo", "feature.copyTo"])
        }

        runTest("FavoriteDirectories 显示名：重名时附上级路径") {
            let names = FavoriteDirectories.displayNames(
                for: ["/Users/me/Downloads", "/Volumes/E/Downloads", "/Users/me/项目"], home: "/Users/me")
            try assertEqual(names, ["Downloads — ~", "Downloads — /Volumes/E", "项目"])
            try assertEqual(FavoriteDirectories.displayNames(for: ["/"], home: "/Users/me"), ["/"], "根目录显示为 /")
        }

        runTest("常用目录输入框：兼容复制路径的各种格式") {
            let home = "/Users/me"
            let a = URL(fileURLWithPath: "/Users/me/a b"), b = URL(fileURLWithPath: "/Users/me/it's")
            for format in CopyPathFormat.allCases where format != .name {
                let copied = PathFormatter.string(for: [a, b], format: format, home: home)
                let parsed = FavoriteDirectories.candidatePaths(fromInput: copied)
                let expected = format == .tilde ? ["~/a b", "~/it's"] : [a.path, b.path]
                try assertEqual(parsed, expected, "格式 \(format.rawValue) 应能还原")
            }
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "file:///Users/me/%E9%A1%B9%E7%9B%AE/"), ["/Users/me/项目"])
        }

        runTest("常用目录输入框：反斜杠、双引号、空行与不配对引号") {
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "/Users/me/a\\ b"), ["/Users/me/a b"], "终端拖入的反斜杠转义")
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "\"/Users/me/a b\""), ["/Users/me/a b"])
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "  /Users/me/x\r\n\n ~/y \n"), ["/Users/me/x", "~/y "], "去行首空白与空行，保留行尾空格")
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "/Users/me/Bob's"), ["/Users/me/Bob's"], "引号不配对按普通路径处理")
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "/Users/me/a b"), ["/Users/me/a b"], "无引号的空格属于路径本身")
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "   \n"), [])
        }

        runTest("FileTransferCheck 拦截放进自身、移动到原目录") {
            try assertEqual(FileTransferCheck.check(source: "/u/a.txt", destinationDirectory: "/u/dst", mode: .move), .ok)
            try assertEqual(FileTransferCheck.check(source: "/u/a.txt", destinationDirectory: "/u", mode: .move), .alreadyInDestination)
            try assertEqual(FileTransferCheck.check(source: "/u/a.txt", destinationDirectory: "/u/", mode: .move), .alreadyInDestination, "目标带结尾斜杠")
            try assertEqual(FileTransferCheck.check(source: "/u/a.txt", destinationDirectory: "/u", mode: .copy), .ok, "复制到原目录允许（生成副本）")
            try assertEqual(FileTransferCheck.check(source: "/u/dir", destinationDirectory: "/u/dir", mode: .copy), .destinationInsideSource)
            try assertEqual(FileTransferCheck.check(source: "/u/dir", destinationDirectory: "/u/dir/sub", mode: .move), .destinationInsideSource)
            try assertEqual(FileTransferCheck.check(source: "/u/dir", destinationDirectory: "/u/dir2", mode: .move), .ok, "同前缀的兄弟目录不算内部")
        }

        runTest("常用目录白名单：系统 /Applications 拒绝，主目录下的 ~/Applications 放行") {
            let home = "/Users/me", tmp = "/private/var/folders/xx/T"
            try assertTrue(!PathAccessPolicy.isAllowed("/Applications", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/Shared", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(PathAccessPolicy.isAllowed("/Users/me/Applications", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(PathAccessPolicy.isAllowed("/Volumes/E/erhu", role: .destination, home: home, temporaryDirectory: tmp))
        }

        runTest("SharedConfig.favoriteDirectories 默认为空并可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.favoriteDirectories.isEmpty)
            config.favoriteDirectories = ["/Users/me/Downloads", "/Volumes/E"]
            try assertEqual(SharedConfig(fileURL: url).favoriteDirectories, ["/Users/me/Downloads", "/Volumes/E"])
        }

        runTest("EditorCatalog 清单无重复且以文本编辑兜底") {
            let ids = EditorCatalog.all.map(\.id)
            try assertEqual(Set(ids).count, ids.count, "bundle id 不应重复")
            try assertEqual(ids.last, EditorCatalog.textEditBundleId)
        }

        runTest("EditorCatalog 合并：清单在前、手动项在后、去重、隐藏") {
            let installedIds: Set<String> = ["com.microsoft.VSCode", "dev.zed.Zed", "com.example.Foo", "com.apple.TextEdit"]
            let custom = [KnownEditor(id: "com.example.Foo", name: "Foo"),
                          KnownEditor(id: "dev.zed.Zed", name: "重复的 Zed"),
                          KnownEditor(id: "com.example.Gone", name: "已卸载")]
            let all = EditorCatalog.installed(custom: custom, isInstalled: installedIds.contains)
            try assertEqual(all.map(\.id), ["dev.zed.Zed", "com.microsoft.VSCode", "com.apple.TextEdit", "com.example.Foo"])
            try assertEqual(all.first?.name, "Zed", "与清单重复的手动项以清单为准")

            let menu = EditorCatalog.menuEditors(custom: custom, hidden: ["dev.zed.Zed", "com.apple.TextEdit"],
                                                 isInstalled: installedIds.contains)
            try assertEqual(menu.map(\.id), ["com.microsoft.VSCode", "com.example.Foo"])
        }

        runTest("EditorCatalog 默认编辑器解析顺序") {
            let installedIds: Set<String> = ["com.microsoft.VSCode", "dev.zed.Zed"]
            func resolve(_ preferred: String?, hidden: Set<String> = [], installed: Set<String> = installedIds) -> String {
                EditorCatalog.resolvedDefault(preferred: preferred, custom: [], hidden: hidden, isInstalled: installed.contains)
            }
            try assertEqual(resolve("com.microsoft.VSCode"), "com.microsoft.VSCode", "选定且已安装")
            try assertEqual(resolve("com.microsoft.VSCode", hidden: ["com.microsoft.VSCode"]), "com.microsoft.VSCode", "选定的默认项即使在菜单中隐藏也生效")
            try assertEqual(resolve(nil), "dev.zed.Zed", "未选定时取菜单第一个")
            try assertEqual(resolve("com.example.Gone"), "dev.zed.Zed", "选定项已卸载时回退")
            try assertEqual(resolve(nil, hidden: ["dev.zed.Zed"]), "com.microsoft.VSCode", "跳过隐藏项")
            try assertEqual(resolve(nil, hidden: installedIds), "dev.zed.Zed", "全部隐藏时仍取任一已安装项")
            try assertEqual(resolve(nil, installed: []), EditorCatalog.textEditBundleId, "全都没装时兜底文本编辑")
        }

        runTest("EditorDiscovery 只认显式声明代码文件的 Editor") {
            let codeUTIs: Set<String> = ["public.swift-source"]
            func doc(_ role: String?, exts: [String] = [], types: [String] = []) -> [String: Any] {
                var d: [String: Any] = ["CFBundleTypeExtensions": exts, "LSItemContentTypes": types]
                if let role { d["CFBundleTypeRole"] = role }
                return d
            }
            func check(_ docs: [[String: Any]]) -> Bool {
                EditorDiscovery.declaresCodeEditing(infoDictionary: ["CFBundleDocumentTypes": docs], codeTypeIdentifiers: codeUTIs)
            }
            try assertTrue(check([doc("Editor", exts: ["PY"])]), "扩展名大小写不敏感")
            try assertTrue(check([doc(nil, types: ["public.swift-source"])]), "缺省角色视为 Editor")
            try assertTrue(!check([doc("Viewer", exts: ["js"])]), "浏览器类 Viewer 不算")
            try assertTrue(!check([doc("Editor", types: ["public.plain-text", "public.folder"])]), "只声明通用文本类型的不算")
            try assertTrue(!EditorDiscovery.declaresCodeEditing(infoDictionary: [:], codeTypeIdentifiers: codeUTIs), "不声明文档类型")
        }

        runTest("EditorDiscovery 只推荐常规安装位置") {
            let home = "/Users/me"
            try assertTrue(EditorDiscovery.isStandardInstallLocation("/Applications/Zed.app", home: home))
            try assertTrue(EditorDiscovery.isStandardInstallLocation("/Applications/Utilities/X.app", home: home))
            try assertTrue(EditorDiscovery.isStandardInstallLocation("/Users/me/Applications/JetBrains Toolbox/PyCharm.app", home: home))
            try assertTrue(!EditorDiscovery.isStandardInstallLocation("/Applications/Doubao.app/Contents/Helpers/Browser.app", home: home), "内嵌 Helper")
            try assertTrue(!EditorDiscovery.isStandardInstallLocation("/Volumes/MarkEdit/MarkEdit.app", home: home), "挂载的 DMG")
            try assertTrue(!EditorDiscovery.isStandardInstallLocation("/Users/me/.cache/x/Chromium.app", home: home))
        }

        runTest("SharedConfig 编辑器偏好：默认未选定、手动项与隐藏项可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertNil(config.preferredEditor)
            try assertTrue(config.customEditors.isEmpty)
            try assertTrue(config.hiddenEditors.isEmpty)

            config.preferredEditor = "dev.zed.Zed"
            config.customEditors = [KnownEditor(id: "com.example.Foo", name: "Foo")]
            config.hiddenEditors = ["com.apple.dt.Xcode"]
            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.preferredEditor, "dev.zed.Zed")
            try assertEqual(reloaded.customEditors, [KnownEditor(id: "com.example.Foo", name: "Foo")])
            try assertEqual(reloaded.hiddenEditors, ["com.apple.dt.Xcode"])

            reloaded.preferredEditor = ""
            try assertNil(SharedConfig(fileURL: url).preferredEditor, "空串视为未选定")
        }

        runTest("SharedConfig 主题色偏好：默认午夜薄荷且可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")

            let config = SharedConfig(fileURL: url)
            try assertEqual(config.appTheme, .midnight, "默认主题应为午夜薄荷")
            try assertNil(config.appThemeValue, "未显式设置时存储应为 nil")

            config.appTheme = .sunset
            try assertEqual(config.appThemeValue, .sunset)

            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.appTheme, .sunset, "重载后应保持落日橙主题")
        }

        runTest("FRThemeID 调色板与外观动态解析") {
            let midnight = FRThemeID.midnight.palette
            let lightAppearance = NSAppearance(named: .aqua)
            let darkAppearance = NSAppearance(named: .darkAqua)

            let lightAccent = midnight.accent.resolved(for: lightAppearance)
            let darkAccent = midnight.accent.resolved(for: darkAppearance)
            try assertTrue(lightAccent != darkAccent, "浅色与深色下的 accent 应有区分")

            let lightOnAccent = midnight.onAccent.resolved(for: lightAppearance)
            let darkOnAccent = midnight.onAccent.resolved(for: darkAppearance)
            try assertTrue(lightOnAccent != darkOnAccent, "浅色与深色下的 onAccent 应有区分")

            // 所有预置主题均应具备有效的标题与色块
            for theme in FRThemeID.allCases {
                try assertTrue(!theme.titleKey.isEmpty)
                try assertTrue(theme.palette.accent.light.alphaComponent > 0)
                try assertTrue(theme.palette.onAccent.light.alphaComponent > 0)
            }
        }

        runTest("FileContentReader 资格预检与多格式文本读取") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            let textFile = dir.appendingPathComponent("sample.txt")
            let utf8Content = "Hello, 访达右键! 🎉\nSecond Line"
            try utf8Content.data(using: .utf8)!.write(to: textFile)

            let utf16File = dir.appendingPathComponent("utf16.txt")
            try "UTF16 Content".data(using: .utf16)!.write(to: utf16File)

            let emptyFile = dir.appendingPathComponent("empty.txt")
            try Data().write(to: emptyFile)

            let binaryFile = dir.appendingPathComponent("binary.bin")
            var binData = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]) // "Hello"
            binData.append(0x00) // NUL 字节
            binData.append(contentsOf: [0x57, 0x6f, 0x72, 0x6c, 0x64])
            try binData.write(to: binaryFile)

            let subDir = dir.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

            let nonExistentFile = dir.appendingPathComponent("missing.txt")

            // 1. 资格预检 isEligible
            let limit: Int64 = 1024 * 1024 // 1 MB
            try assertTrue(FileContentReader.isEligible(url: textFile, maxBytes: limit), "常规文本文件应满足资格")
            try assertTrue(FileContentReader.isEligible(url: emptyFile, maxBytes: limit), "空文件应满足资格")
            try assertTrue(!FileContentReader.isEligible(url: subDir, maxBytes: limit), "目录不应满足资格")
            try assertTrue(!FileContentReader.isEligible(url: nonExistentFile, maxBytes: limit), "不存在的文件不应满足资格")
            try assertTrue(!FileContentReader.isEligible(url: textFile, maxBytes: 5), "超过大小上限时不应满足资格")

            // 2. 文本读取 readText
            // UTF-8
            let readUtf8 = FileContentReader.readText(from: textFile, maxBytes: limit)
            try assertEqual(readUtf8, .success(utf8Content))

            // UTF-16
            let readUtf16 = FileContentReader.readText(from: utf16File, maxBytes: limit)
            try assertEqual(readUtf16, .success("UTF16 Content"))

            // 空文件
            let readEmpty = FileContentReader.readText(from: emptyFile, maxBytes: limit)
            try assertEqual(readEmpty, .success(""))

            // 超大文件
            let readTooLarge = FileContentReader.readText(from: textFile, maxBytes: 5)
            if case .fileTooLarge(let size, let max) = readTooLarge {
                try assertTrue(size > max)
                try assertEqual(max, 5)
            } else {
                throw TestFailure(message: "超过上限应返回 .fileTooLarge")
            }

            // 二进制含 0x00
            let readBin = FileContentReader.readText(from: binaryFile, maxBytes: limit)
            try assertEqual(readBin, .binaryFile, "含 0x00 的文件应被识别为二进制")

            // 目录
            let readDir = FileContentReader.readText(from: subDir, maxBytes: limit)
            try assertEqual(readDir, .notRegularFile, "目录应返回 .notRegularFile")
        }

        runTest("SharedConfig copyFileContentMaxSizeKB 配置与持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")

            let config = SharedConfig(fileURL: url)
            try assertEqual(config.copyFileContentMaxSizeKB, 1024, "默认大小上限应为 1024 KB (1MB)")
            try assertEqual(config.copyFileContentMaxBytes, 1024 * 1024)

            // 调整为 5 MB
            config.copyFileContentMaxSizeKB = 5120
            try assertEqual(config.copyFileContentMaxBytes, 5120 * 1024)

            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.copyFileContentMaxSizeKB, 5120, "重载后应保持 5120 KB 设置")
            try assertEqual(reloaded.copyFileContentMaxBytes, 5120 * 1024)
        }

        runTest("MenuFeatureCatalog 包含 copyFileContent 特性") {
            let allIds = MenuFeatureCatalog.all.map(\.id)
            try assertTrue(allIds.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(!MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.copyFileContent), "复制文件内容默认应开启")

            // 验证顺序在 copyFileName 之后
            if let nameIdx = allIds.firstIndex(of: MenuFeatureCatalog.copyFileName),
               let contentIdx = allIds.firstIndex(of: MenuFeatureCatalog.copyFileContent) {
                try assertTrue(contentIdx > nameIdx, "copyFileContent 顺序应在 copyFileName 之后")
            } else {
                throw TestFailure(message: "功能列表中未找到 copyFileName 或 copyFileContent")
            }
        }

        // MARK: - 服务快捷键同步

        let cmdBit = 1 << 20, optBit = 1 << 19, ctlBit = 1 << 18, sftBit = 1 << 17

        runTest("ServiceShortcuts key_equivalent 修饰符前缀与小写字符") {
            try assertEqual(ServiceShortcuts.keyEquivalent(for: ActionShortcut(key: "P", modifiers: cmdBit | optBit | ctlBit)), "@~^p")
            try assertEqual(ServiceShortcuts.keyEquivalent(for: ActionShortcut(key: "x", modifiers: ctlBit | cmdBit | sftBit)), "@^$x")
            try assertEqual(ServiceShortcuts.keyEquivalent(for: ActionShortcut(key: "k", modifiers: ctlBit | optBit)), "~^k")
        }

        runTest("ServiceShortcuts 映射与 Info.plist 的 NSServices 一致") {
            // Tests/FinderRightKitTests/xxx.swift → 仓库根目录
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let plistURL = root.appendingPathComponent("FinderRight/Info.plist")
            let data = try Data(contentsOf: plistURL)
            // Info.plist 含 $(VAR) 占位符，仍是合法 plist
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let services = (plist?["NSServices"] as? [[String: Any]]) ?? []
            let pairs = Set(services.compactMap { svc -> String? in
                guard let title = (svc["NSMenuItem"] as? [String: String])?["default"],
                      let message = svc["NSMessage"] as? String else { return nil }
                return "\(title)|\(message)"
            })
            try assertTrue(!pairs.isEmpty, "应能读到 NSServices")
            for b in ServiceShortcuts.bindings {
                try assertTrue(pairs.contains("\(b.menuTitle)|\(b.message)"), "Info.plist 缺少 \(b.menuTitle) / \(b.message)")
            }
            try assertTrue(!ServiceShortcuts.hasService(actionId: "shortcut.toggleHidden"), "切换隐藏文件没有对应服务")
        }

        runTest("ServiceShortcuts 合并只改本 App 条目的 key_equivalent") {
            let bid = "com.finderright.app"
            let cut = ServiceShortcuts.bindings.first { $0.actionId == "shortcut.cut" }!
            let paste = ServiceShortcuts.bindings.first { $0.actionId == "shortcut.paste" }!
            let cutKey = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: cut)
            let pasteKey = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: paste)
            try assertEqual(cutKey, "com.finderright.app - FinderRight: Cut - cutFiles")

            let existing: [String: Any] = [
                "other.app - Other - doIt": ["key_equivalent": "@~o"],
                cutKey: ["enabled_context_menu": false, "key_equivalent": "@~x"],
                pasteKey: ["key_equivalent": "@~v"],
            ]
            let copyPath = ServiceShortcuts.bindings.first { $0.actionId == "shortcut.copyPath" }!
            let copyPathKey = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: copyPath)
            let merged = ServiceShortcuts.mergedStatus(existing, bundleId: bid, shortcuts: [
                "shortcut.copyPath": ActionShortcut(key: "c", modifiers: cmdBit | ctlBit),
                "shortcut.cut": ActionShortcut(key: "x", modifiers: cmdBit | ctlBit),
            ])
            try assertEqual((merged[copyPathKey] as? [String: Any])?["key_equivalent"] as? String, "@^c")
            let cutEntry = merged[cutKey] as? [String: Any]
            try assertNil(cutEntry?["key_equivalent"], "剪切由按键拦截处理，不写服务快捷键")
            try assertEqual(cutEntry?["enabled_context_menu"] as? Bool, false, "保留用户的启用状态")
            try assertNil(merged[pasteKey], "清除快捷键后空条目应删除")
            try assertEqual((merged["other.app - Other - doIt"] as? [String: String])?["key_equivalent"], "@~o", "不碰其他 App")

            let reserved = ServiceShortcuts.mergedStatus([:], bundleId: bid, shortcuts: [
                "shortcut.paste": ActionShortcut(key: "v", modifiers: cmdBit),
            ])
            try assertNil(reserved[pasteKey], "与访达 ⌘V 冲突的旧快捷键不写入服务")
        }

        runTest("ServiceShortcuts 写入偏好域并可读回，无变化时不重复写") {
            // 固定域名 + 用后删文件，避免在 ~/Library/Preferences 堆积测试残留
            let domain = "com.finderright.tests.pbs"
            let clear = {
                CFPreferencesSetAppValue("NSServicesStatus" as CFString, nil, domain as CFString)
                CFPreferencesSetAppValue("ServicesShortcutsPresent" as CFString, nil, domain as CFString)
                CFPreferencesAppSynchronize(domain as CFString)
            }
            clear()
            defer {
                clear()
                let file = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/\(domain).plist")
                try? FileManager.default.removeItem(at: file)
            }
            let bid = "com.finderright.app"
            let shortcuts = ["shortcut.copyPath": ActionShortcut(key: "c", modifiers: cmdBit | ctlBit | optBit)]
            try assertTrue(ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, domain: domain), "首次写入应有变化")
            try assertEqual(ServiceShortcuts.storedKeyEquivalents(bundleId: bid, domain: domain), ["shortcut.copyPath": "@~^c"])
            try assertTrue(!ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, domain: domain), "相同内容不应重复写")
            try assertTrue(ServiceShortcuts.sync(shortcuts: [:], bundleId: bid, domain: domain))
            try assertEqual(ServiceShortcuts.storedKeyEquivalents(bundleId: bid, domain: domain), [:])
        }

        runTest("FinderReservedShortcuts 拦截访达原生 ⌘X / ⌘V，放行带 ⌃ 的组合") {
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "x", modifiers: cmdBit))?.name, "剪切")
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: cmdBit))?.name, "粘贴")
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "c", modifiers: cmdBit | optBit))?.name, "拷贝路径名")
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "3", modifiers: cmdBit | sftBit))?.isSystem, true)
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "3", modifiers: cmdBit | sftBit))?.kind, .system)
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "x", modifiers: cmdBit | ctlBit)))
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: cmdBit | ctlBit)))
            // 多余的位（如 capsLock / 设备相关位）不影响判断
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: cmdBit | (1 << 16)))?.name, "粘贴")
        }

        runTest("FinderReservedShortcuts 解析文本编辑按键绑定，拦截 ⌃V（pageDown:）") {
            try assertEqual(FinderReservedShortcuts.parseBindingKey("^v"), .init(modifiers: ctlBit, key: "v"))
            try assertEqual(FinderReservedShortcuts.parseBindingKey("^A"), .init(modifiers: ctlBit | sftBit, key: "a"), "大写隐含 ⇧")
            try assertEqual(FinderReservedShortcuts.parseBindingKey("@~^\u{F701}"), .init(modifiers: cmdBit | optBit | ctlBit, key: "\u{F701}"))
            try assertNil(FinderReservedShortcuts.parseBindingKey("$\u{F700}"), "只含 ⇧ 的组合不可能被录制")
            try assertNil(FinderReservedShortcuts.parseBindingKey("a"))
            try assertEqual(FinderReservedShortcuts.parseBindingKey("^"), nil, "单独的 ^ 字符不是组合键")

            let bindings = FinderReservedShortcuts.parseBindings(["^v": "pageDown:", "^k": ["deleteToEndOfParagraph:", "x"], "^x": ["a": "b"]])
            let hit = FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: ctlBit), textBindings: bindings)
            try assertEqual(hit, .init(name: "pageDown:", kind: .textEditing))
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "k", modifiers: ctlBit), textBindings: bindings)?.name, "deleteToEndOfParagraph:")
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "x", modifiers: ctlBit), textBindings: bindings), "多键序列子字典忽略")

            // 真实系统绑定表：⌃V 必须被拦截，⌃X、⌃⌘V 放行
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: ctlBit))?.kind, .textEditing)
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "x", modifiers: ctlBit)))
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: ctlBit | cmdBit)))
        }

        runTest("ServiceInvocationPolicy 被派发激活时按激活前的前台应用判定调用方") {
            let me = "com.finderright.app", finder = "com.apple.finder"
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: me, providerBundleId: me,
                            providerHasKeyWindow: false, previousFrontmostBundleId: finder), finder, "快捷键触发：系统先激活本 App")
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: me, providerBundleId: me,
                            providerHasKeyWindow: true, previousFrontmostBundleId: finder), me, "用户正在本 App 窗口里操作")
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: me, providerBundleId: me,
                            providerHasKeyWindow: false, previousFrontmostBundleId: nil), me)
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: finder, providerBundleId: me,
                            providerHasKeyWindow: false, previousFrontmostBundleId: "com.apple.mail"), finder, "访达在前时不改写")
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: me, providerBundleId: me,
                            providerHasKeyWindow: false, previousFrontmostBundleId: "com.example.evil"), "com.example.evil", "激活前是其他 App 仍会被拒")
        }

        runTest("FinderKeyTakeover 按键码与修饰键识别，修饰键须完全一致") {
            let cmd: UInt64 = 1 << 20, shift: UInt64 = 1 << 17, opt: UInt64 = 1 << 19, ctl: UInt64 = 1 << 18
            let capsLock: UInt64 = 1 << 16, numericPad: UInt64 = 1 << 21
            typealias T = FinderKeyTakeover
            // ANSI 布局：X=7 C=8 V=9
            let cmdX = T.KeyChord(keyCode: 7, modifiers: 1 << 20), cmdV = T.KeyChord(keyCode: 9, modifiers: 1 << 20)
            let cmdC = T.KeyChord(keyCode: 8, modifiers: 1 << 20)
            let chords = ["shortcut.cut": cmdX, "shortcut.paste": cmdV]
            try assertEqual(T.command(keyCode: 7, modifierFlags: cmd, chords: chords, copy: cmdC), .cut)
            try assertEqual(T.command(keyCode: 9, modifierFlags: cmd | capsLock | numericPad, chords: chords, copy: cmdC), .paste, "无关标志位不影响")
            try assertEqual(T.command(keyCode: 8, modifierFlags: cmd, chords: chords, copy: cmdC), .copy)
            try assertNil(T.command(keyCode: 9, modifierFlags: cmd | opt, chords: chords, copy: cmdC), "⌥⌘V 是访达自己的移动")
            try assertNil(T.command(keyCode: 9, modifierFlags: cmd | shift, chords: chords, copy: cmdC))
            try assertNil(T.command(keyCode: 0, modifierFlags: cmd, chords: chords, copy: cmdC))

            let ctlV = T.KeyChord(keyCode: 9, modifiers: 1 << 18)
            let ctlChords = ["shortcut.cut": cmdX, "shortcut.paste": ctlV]
            try assertEqual(T.command(keyCode: 9, modifierFlags: ctl, chords: ctlChords, copy: cmdC), .paste, "改成 ⌃V")
            try assertNil(T.command(keyCode: 9, modifierFlags: cmd, chords: ctlChords, copy: cmdC), "改键后 ⌘V 交还访达")
            try assertNil(T.command(keyCode: 7, modifierFlags: cmd, chords: ["shortcut.paste": cmdV], copy: cmdC), "清空即停用")

            // 其他行：⌥⌘C 是访达自己的「拷贝路径」，拦截后可以给复制路径用
            let optCmdC = T.KeyChord(keyCode: 8, modifiers: (1 << 20) | (1 << 19))
            let allChords = ["shortcut.cut": cmdX, "shortcut.copyPath": optCmdC, "shortcut.toggleHidden": T.KeyChord(keyCode: 47, modifiers: (1 << 20) | (1 << 17))]
            try assertEqual(T.command(keyCode: 8, modifierFlags: cmd | opt, chords: allChords, copy: cmdC), .action("shortcut.copyPath"))
            try assertEqual(T.command(keyCode: 47, modifierFlags: cmd | shift, chords: allChords, copy: cmdC), .action("shortcut.toggleHidden"))
            try assertEqual(T.command(keyCode: 8, modifierFlags: cmd, chords: allChords, copy: cmdC), .copy, "⌘C 仍识别为拷贝")
            try assertEqual(T.KeyChord(keyCode: 7, modifiers: (1 << 20) | (1 << 16)), cmdX, "构造时去掉无关位")

            try assertEqual(T.functionKeyCode(for: "\u{F708}"), 96, "F5")
            try assertEqual(T.functionKeyCode(for: "\u{F700}"), 126, "↑")
            try assertNil(T.functionKeyCode(for: "v"))
        }

        runTest("FinderKeyTakeover 默认 ⌘X / ⌘V 只补空位、不覆盖用户设置，录制只拦系统全局快捷键") {
            typealias T = FinderKeyTakeover
            let cmd = 1 << 20, ctl = 1 << 18, shift = 1 << 17
            let cmdX = ActionShortcut(key: "x", modifiers: cmd), cmdV = ActionShortcut(key: "v", modifiers: cmd)
            let opt = 1 << 19
            let optCmdC = ActionShortcut(key: "c", modifiers: cmd | opt)
            let sftCmdDot = ActionShortcut(key: ".", modifiers: cmd | shift)
            let all = ["shortcut.cut": cmdX, "shortcut.paste": cmdV, "shortcut.copyPath": optCmdC,
                       "shortcut.toggleHidden": sftCmdDot]
            try assertEqual(T.defaultShortcuts, all, "默认值与访达原生一致")
            try assertNil(T.defaultShortcuts["shortcut.goToDirectory"], "前往目录不占用访达的 ⇧⌘G")
            try assertEqual(T.defaultsToApply(current: [:], alreadyApplied: []), all, "全新安装")
            try assertEqual(T.defaultsToApply(current: [
                "shortcut.cut": ActionShortcut(key: "c", modifiers: ctl),
                "shortcut.paste": ActionShortcut(key: "v", modifiers: ctl),
                "shortcut.copyPath": ActionShortcut(key: "p", modifiers: cmd | ctl),
            ], alreadyApplied: []).keys.sorted(), ["shortcut.toggleHidden"], "用户设置过的行一律保留")
            try assertEqual(T.defaultsToApply(current: ["shortcut.paste": ActionShortcut(key: "v", modifiers: cmd | ctl)],
                                              alreadyApplied: ["shortcut.copyPath", "shortcut.toggleHidden"]),
                            ["shortcut.cut": cmdX], "只补没设置的那一行")
            try assertEqual(T.defaultsToApply(current: ["shortcut.openTerminal": ActionShortcut(key: "V", modifiers: cmd)],
                                              alreadyApplied: ["shortcut.copyPath", "shortcut.toggleHidden"]),
                            ["shortcut.cut": cmdX], "⌘V 已被其他动作占用则不填")
            // 1.6.4 升级：剪切 / 粘贴补过（用户之后清空了剪切），新增的三项默认只补空位
            let legacy = T.legacyAppliedActionIds(cutPasteApplied: true)
            try assertEqual(T.defaultsToApply(current: ["shortcut.paste": cmdV, "shortcut.copyPath": ActionShortcut(key: "p", modifiers: cmd | ctl)],
                                              alreadyApplied: legacy),
                            ["shortcut.toggleHidden": sftCmdDot], "清空的剪切不补回，用户的复制路径不覆盖")
            try assertEqual(T.defaultsToApply(current: [:], alreadyApplied: Set(all.keys)), [:], "补过的行清空后不再补回")
            try assertTrue(T.legacyAppliedActionIds(cutPasteApplied: false).isEmpty)
            try assertTrue(T.handlesAction("shortcut.cut") && T.handlesAction("shortcut.paste"))
            try assertTrue(!T.handlesAction("shortcut.copyPath"))
            try assertTrue(!ServiceShortcuts.syncsShortcut(actionId: "shortcut.cut"))
            try assertTrue(ServiceShortcuts.syncsShortcut(actionId: "shortcut.copyPath"))

            let ctlV = ActionShortcut(key: "v", modifiers: ctl)
            let bindings = FinderReservedShortcuts.parseBindings(["^v": "pageDown:"])
            let screenshot = ActionShortcut(key: "3", modifiers: cmd | shift)
            for available in [true, false] {
                try assertNil(T.recordingConflict(for: ctlV, actionId: "shortcut.paste", interceptorAvailable: available, textBindings: bindings), "粘贴行可用 ⌃V")
                try assertNil(T.recordingConflict(for: cmdV, actionId: "shortcut.paste", interceptorAvailable: available, textBindings: bindings), "粘贴行可用 ⌘V")
                try assertEqual(T.recordingConflict(for: screenshot, actionId: "shortcut.cut", interceptorAvailable: available, textBindings: bindings)?.kind, .system, "系统全局快捷键轮不到拦截")
                try assertEqual(T.recordingConflict(for: screenshot, actionId: "shortcut.copyPath", interceptorAvailable: available, textBindings: bindings)?.kind, .system)
            }
            // 已授权：其他行也由拦截处理，访达菜单 / 文本编辑组合都能用
            try assertNil(T.recordingConflict(for: ctlV, actionId: "shortcut.copyPath", interceptorAvailable: true, textBindings: bindings))
            try assertNil(T.recordingConflict(for: cmdV, actionId: "shortcut.copyPath", interceptorAvailable: true, textBindings: bindings))
            try assertNil(T.recordingConflict(for: ActionShortcut(key: ".", modifiers: cmd | shift), actionId: "shortcut.toggleHidden", interceptorAvailable: true, textBindings: bindings))
            // 未授权：其他行回退为服务快捷键，照样拦
            try assertEqual(T.recordingConflict(for: ctlV, actionId: "shortcut.copyPath", interceptorAvailable: false, textBindings: bindings)?.kind, .textEditing)
            try assertEqual(T.recordingConflict(for: cmdV, actionId: "shortcut.copyPath", interceptorAvailable: false, textBindings: bindings)?.kind, .finderMenu)
        }

        runTest("FinderKeyTakeover 焦点在文字输入里一律放行") {
            try assertTrue(FinderKeyTakeover.isTextInput(role: "AXTextField", subrole: nil), "重命名")
            try assertTrue(FinderKeyTakeover.isTextInput(role: "AXTextField", subrole: "AXSearchField"), "搜索框")
            try assertTrue(FinderKeyTakeover.isTextInput(role: "AXTextArea", subrole: nil))
            try assertTrue(!FinderKeyTakeover.isTextInput(role: "AXList", subrole: "AXCollectionList"), "图标视图")
            try assertTrue(!FinderKeyTakeover.isTextInput(role: "AXOutline", subrole: nil), "列表视图")
            try assertTrue(!FinderKeyTakeover.isTextInput(role: nil, subrole: nil))

            typealias T = FinderKeyTakeover
            try assertEqual(T.decide(.cut, focusIsText: false, pasteboardIsCutMirror: false), .cut)
            try assertEqual(T.decide(.cut, focusIsText: true, pasteboardIsCutMirror: true), .passThrough, "重命名时剪切文字")
            try assertEqual(T.decide(.paste, focusIsText: true, pasteboardIsCutMirror: true), .passThrough, "重命名时粘贴文字，不能移走文件")
            try assertEqual(T.decide(.paste, focusIsText: false, pasteboardIsCutMirror: true), .paste)
            try assertEqual(T.decide(.paste, focusIsText: false, pasteboardIsCutMirror: false), .passThrough, "剪贴板已换成别的内容：普通粘贴")
            try assertEqual(T.decide(.copy, focusIsText: false, pasteboardIsCutMirror: true), .copyThenCancelCut)
            try assertEqual(T.decide(nil, focusIsText: false, pasteboardIsCutMirror: true), .passThrough)
            try assertEqual(T.decide(.action("shortcut.copyPath"), focusIsText: false, pasteboardIsCutMirror: false), .runAction("shortcut.copyPath"))
            try assertEqual(T.decide(.action("shortcut.copyPath"), focusIsText: true, pasteboardIsCutMirror: false), .passThrough, "重命名时按键交给文字")

            let zh = ["FinderRight: Copy Path": "FinderRight：复制路径"]
            try assertEqual(T.serviceMenuTitles(menuTitle: "FinderRight: Copy Path", translations: [zh, [:]]),
                            ["FinderRight: Copy Path", "FinderRight：复制路径"], "英文原文 + 各语言译名")
        }

        runTest("CutPasteboardMirror 按 changeCount 判断剪贴板是否仍是剪切内容") {
            var mirror = CutPasteboardMirror()
            try assertTrue(!mirror.matches(currentChangeCount: 0), "未记录时不匹配")
            mirror.record(changeCount: 42)
            try assertTrue(mirror.matches(currentChangeCount: 42))
            try assertTrue(!mirror.matches(currentChangeCount: 43), "之后又复制了别的")
            mirror.reset()
            try assertTrue(!mirror.matches(currentChangeCount: 42))
        }

        print("\n-----------------------------------------")
        print("测试结果: 总数 \(totalTests)，通过 \(passedTests)，失败 \(failedTests)")
        print("-----------------------------------------")

        if failedTests > 0 {
            exit(1)
        }
    }
}
