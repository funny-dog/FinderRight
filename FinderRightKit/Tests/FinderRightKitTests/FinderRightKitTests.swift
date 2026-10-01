import Foundation
import FinderRightKit

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

        print("\n-----------------------------------------")
        print("测试结果: 总数 \(totalTests)，通过 \(passedTests)，失败 \(failedTests)")
        print("-----------------------------------------")

        if failedTests > 0 {
            exit(1)
        }
    }
}
