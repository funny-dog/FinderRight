import Foundation
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
            config.menuIconStyle = .classic
            let shortcut = ActionShortcut(key: "x", modifiers: 1048576) // Cmd
            config.setShortcut(shortcut, forActionId: "shortcut.cut")

            let tmpl = FileTemplate(name: "Log", fileExtension: "log", content: "[INIT]")
            config.addFileTemplate(tmpl)

            try assertEqual(config.preferredTerminal, "com.googlecode.iterm2")
            try assertEqual(config.menuIconStyle, .classic)
            try assertEqual(config.shortcut(forActionId: "shortcut.cut")?.key, "x")
            try assertEqual(config.customFileTemplates.count, 1)
            try assertEqual(config.customFileTemplates.first?.fileExtension, "log")

            // 重新从磁盘创建实例加载，验证持久化
            let reloadedConfig = SharedConfig(fileURL: tempURL)
            try assertEqual(reloadedConfig.preferredTerminal, "com.googlecode.iterm2")
            try assertEqual(reloadedConfig.menuIconStyle, .classic)
            try assertEqual(reloadedConfig.shortcut(forActionId: "shortcut.cut")?.key, "x")
            try assertEqual(reloadedConfig.customFileTemplates.count, 1)

            // 删除模板
            reloadedConfig.removeFileTemplate(withId: tmpl.id)
            try assertTrue(reloadedConfig.customFileTemplates.isEmpty)
        }

        // 5. SharedConfig 多线程并发压测
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
                    config.menuIconStyle = (i % 2 == 0) ? .modern : .classic
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
            let merged = store.appendUnique(["/tmp/b", "/tmp/c"])
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
            try assertEqual(store.take(), [alive.path, gone.path], "take 应返回并取走队列")
            try assertTrue(store.read().isEmpty, "take 后队列应为空")
            try assertTrue(FileManager.default.fileExists(atPath: store.inflightURL.path), "take 应留下 in-flight 标记")
            try assertNil(store.take(), "队列已被取走，第二次 take 应返回 nil")

            // 模拟主 App 在移动过程中被杀：in-flight 残留 → 启动时恢复
            let restored = store.recover(existingOnly: true)
            try assertEqual(restored, [alive.path], "只应恢复仍存在的源文件")
            try assertEqual(store.read(), [alive.path])
            try assertTrue(!FileManager.default.fileExists(atPath: store.inflightURL.path), "恢复后应删除 in-flight 标记")

            // finish() 在没有 in-flight 标记时也必须幂等
            store.finish()
            try assertEqual(store.read(), [alive.path])

            // recover 在无 in-flight 残留时不应改动队列
            try assertEqual(store.recover(), [alive.path])
        }

        // 8. CutQueueStore：取消剪切必须能作废 in-flight 标记
        runTest("CutQueueStore 取消剪切作废 in-flight") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)

            try store.write(["/tmp/x"])
            _ = store.take()
            store.clear()

            try assertTrue(store.read().isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: store.inflightURL.path))
            try assertTrue(store.recover().isEmpty, "取消后不应再恢复出任何路径")
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

            // 单个文件夹内含不可读文件：ditto 退出码非 0
            do {
                _ = try ZipCompressor.compress(items: [box], into: work, baseName: "Box", registry: registry)
                throw TestFailure(message: "含不可读文件时应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .dittoFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
            try assertEqual(try directoryListing(work), ["Box"], "失败后不得留下 zip 或临时目录")

            // 多选中有不可读文件：暂存阶段即失败
            let plain = work.appendingPathComponent("plain.txt")
            try Data("p".utf8).write(to: plain)
            try Data("y".utf8).write(to: lockedLoose)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedLoose.path)
            do {
                _ = try ZipCompressor.compress(items: [plain, lockedLoose], into: work, baseName: "Archive", registry: registry)
                throw TestFailure(message: "暂存失败时应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .stagingFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
            try assertEqual(try directoryListing(work), ["Box", "locked2.txt", "plain.txt"], "失败后不得留下 zip 或暂存目录")
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

        runTest("OperationRecord.summary 压缩长错误输出") {
            try assertTrue(OperationRecord.summary(of: "  \n \n") == nil, "全空返回 nil")
            try assertEqual(OperationRecord.summary(of: "\n  tar: bad header  \n"), "tar: bad header")
            try assertEqual(OperationRecord.summary(of: "1\n2\n3\n4\n5"), "1\n2\n3\n…", "超过行数时标出省略")
            let long = String(repeating: "x", count: 400)
            try assertEqual(OperationRecord.summary(of: long)?.count, 301, "截断到上限并加省略号")
        }

        runTest("OfficeTemplate 只接受白名单内的模板 id") {
            try assertEqual(OfficeTemplate.allCases.map(\.fileExtension), ["docx", "xlsx", "pptx"])
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

        print("\n-----------------------------------------")
        print("测试结果: 总数 \(totalTests)，通过 \(passedTests)，失败 \(failedTests)")
        print("-----------------------------------------")

        if failedTests > 0 {
            exit(1)
        }
    }
}
