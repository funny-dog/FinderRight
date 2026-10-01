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

        print("\n-----------------------------------------")
        print("测试结果: 总数 \(totalTests)，通过 \(passedTests)，失败 \(failedTests)")
        print("-----------------------------------------")

        if failedTests > 0 {
            exit(1)
        }
    }
}
