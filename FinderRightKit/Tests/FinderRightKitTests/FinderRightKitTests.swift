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

        print("\n-----------------------------------------")
        print("测试结果: 总数 \(totalTests)，通过 \(passedTests)，失败 \(failedTests)")
        print("-----------------------------------------")

        if failedTests > 0 {
            exit(1)
        }
    }
}
