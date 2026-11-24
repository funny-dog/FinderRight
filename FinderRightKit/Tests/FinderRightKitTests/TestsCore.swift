import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// 核心存储与策略
enum CoreTests {
    static func run() {
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
        runTest("终端配置：SharedConfig 独立读写与默认值") {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-settings-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            let config = SharedConfig(fileURL: tempURL)

            // 默认值（图标风格默认彩色线条，见「图标风格默认值按安装方式区分」那条）
            try assertEqual(config.preferredTerminal, TerminalCatalog.defaultTerminalBundleIdentifier())
            try assertEqual(config.menuIconStyle, .tinted)
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

        // 5. SharedConfig 并发安全与损坏保护测试
        runTest("SharedConfig 单实例多线程读写不丢失配置") {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-thread-safety-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let config = SharedConfig(fileURL: tempURL)
            let queue = DispatchQueue(label: "com.finderright.test.config.threads", attributes: .concurrent)
            let group = DispatchGroup()
            for _ in 0..<30 {
                group.enter()
                queue.async {
                    config.preferredTerminal = "com.apple.Terminal"
                    config.developerToolsEnabled = true
                    config.copyPathFormat = .tilde
                    group.leave()
                }
                group.enter()
                queue.async {
                    config.menuIconStyle = .tile
                    config.preferredEditor = "com.microsoft.VSCode"
                    config.copyFileNameFormat = .withoutExtension
                    group.leave()
                }
            }
            try assertEqual(group.wait(timeout: .now() + 10), .success)

            let reloaded = SharedConfig(fileURL: tempURL)
            try assertEqual(reloaded.preferredTerminal, "com.apple.Terminal")
            try assertTrue(reloaded.developerToolsEnabled)
            try assertEqual(reloaded.copyPathFormat, .tilde)
            try assertEqual(reloaded.menuIconStyle, .tile)
            try assertEqual(reloaded.preferredEditor, "com.microsoft.VSCode")
            try assertEqual(reloaded.copyFileNameFormat, .withoutExtension)
        }

        runTest("SharedConfig 损坏配置不会被后续写入清空") {
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test-corrupt-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let original = Data("not a property list".utf8)
            try original.write(to: tempURL)
            let config = SharedConfig(fileURL: tempURL)

            config.preferredTerminal = "com.apple.Terminal"

            try assertEqual(try Data(contentsOf: tempURL), original, "读不出原配置时必须中止写事务")
        }

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
            try store.clear()

            try assertTrue(store.read().isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: store.inflightURL.path))
            try assertTrue(try store.recover(existingOnly: false).isEmpty, "取消后不应再恢复出任何路径")
        }

        runTest("CutQueueStore clear 文件不存在时幂等成功且删除失败时抛出错误") {
            let dir = makeTempDirectory()
            defer {
                chmod(dir.path, 0o755)
                try? FileManager.default.removeItem(at: dir)
            }
            let store = CutQueueStore(directory: dir)
            // 文件不存在时 clear 应幂等成功
            try store.clear()

            // 写入队列文件
            try store.write(["/tmp/keep_me"])
            try assertTrue(!store.read().isEmpty)

            // 将目录设为不可写（去掉写权限，使得无法从中删除文件）
            guard chmod(dir.path, 0o555) == 0 else {
                throw TestFailure(message: "无法修改测试目录权限")
            }

            var clearFailed = false
            do {
                try store.clear()
            } catch {
                clearFailed = true
            }

            // 恢复目录写权限以便检查与清理
            _ = chmod(dir.path, 0o755)

            try assertTrue(clearFailed, "目录不可写导致删除失败时 clear 必须抛出错误")
            try assertEqual(store.read(), ["/tmp/keep_me"], "清理失败时原队列文件必须保留在磁盘")
        }

        runTest("CutQueueStore 上级目录不可遍历时取消与恢复均须报错") {
            let root = makeTempDirectory()
            defer {
                chmod(root.path, 0o700)
                try? FileManager.default.removeItem(at: root)
            }
            let store = CutQueueStore(directory: root.appendingPathComponent("queue"))
            try store.write(["/tmp/keep"])
            _ = try store.take()
            guard chmod(root.path, 0o000) == 0 else {
                throw TestFailure(message: "无法修改测试目录权限")
            }
            var clearFailed = false
            do { try store.clear() } catch { clearFailed = true }
            var recoverFailed = false
            do { _ = try store.recover(existingOnly: false) } catch { recoverFailed = true }
            chmod(root.path, 0o700)

            try assertTrue(clearFailed, "不可遍历不能当作取消成功")
            try assertTrue(recoverFailed, "不可遍历不能当作没有恢复记录")
            try assertEqual(try store.recover(existingOnly: false), ["/tmp/keep"], "失败后恢复记录必须保留")
        }

        runTest("CutQueueStore 目录不存在时取消与恢复幂等成功") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = CutQueueStore(directory: root.appendingPathComponent("missing"))
            try store.clear()
            try assertTrue(try store.recover(existingOnly: false).isEmpty)
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
            try store.clear()
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

        runTest("CutQueueStore 兼容恢复旧版批次格式并忽略已完成项") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = CutQueueStore(directory: dir)
            let pending = dir.appendingPathComponent("pending.txt")
            let done = dir.appendingPathComponent("done.txt")
            try Data("a".utf8).write(to: pending)
            try Data("b".utf8).write(to: done)
            let legacyURL = dir.appendingPathComponent("cut-queue.inflight.00000000-0000-0000-0000-000000000001.json")
            let legacyJSON = """
            {"items":[{"source":"\(pending.path)","phase":"moving"},{"source":"\(done.path)","phase":"completed"}]}
            """
            try Data(legacyJSON.utf8).write(to: legacyURL)

            try assertEqual(try store.recover(), [pending.path])
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

        // 16b. App Translocation（从下载目录直接运行）时不做定向唤醒
        runTest("App Translocation 下不返回定向唤醒路径") {
            let translocated = URL(fileURLWithPath: "/private/var/folders/q9/x1/T/AppTranslocation/0FDF1F-8FB-468A-A9E3-465A2870D83B/d/FinderRight.app/Contents/PlugIns/FinderRightSync.appex")
            try assertTrue(IPCBridge.containingAppURL(forExtensionAt: translocated) == nil,
                           "只读随机挂载副本不能用作定向唤醒目标，应退回通用 open")

            let normal = URL(fileURLWithPath: "/Applications/FinderRight.app/Contents/PlugIns/FinderRightSync.appex")
            try assertEqual(IPCBridge.containingAppURL(forExtensionAt: normal)?.path, "/Applications/FinderRight.app")
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

        // 17b. 图标风格默认值：新安装为彩色线条，老用户保持单色线条
        runTest("图标风格默认值按安装方式区分") {
            let fresh = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("test-icon-style-fresh-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: fresh) }
            try assertEqual(SharedConfig(fileURL: fresh).menuIconStyle, .tinted, "全新安装的默认样式应为彩色线条")

            // 老用户：升级前已有配置文件，但从没选过图标样式 → 必须保持旧的默认值
            let legacy = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("test-icon-style-legacy-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: legacy) }
            let legacyStore: [String: Any] = ["badgeOwnershipReclaim": false]
            try PropertyListSerialization.data(fromPropertyList: legacyStore, format: .xml, options: 0)
                .write(to: legacy)
            try assertEqual(SharedConfig(fileURL: legacy).menuIconStyle, .modern, "老用户的样式不应被新默认值改变")

            // 老用户显式选过的样式必须原样保留
            let chosen = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("test-icon-style-chosen-\(UUID().uuidString).plist")
            defer { try? FileManager.default.removeItem(at: chosen) }
            let chosenStore: [String: Any] = ["menuIconStyle": "tile"]
            try PropertyListSerialization.data(fromPropertyList: chosenStore, format: .xml, options: 0)
                .write(to: chosen)
            try assertEqual(SharedConfig(fileURL: chosen).menuIconStyle, .tile, "显式选择必须保留")
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

        runTest("NewFilePresentation 只跳过桌面本身的自动定位") {
            let desktop = URL(fileURLWithPath: "/Users/tester/Desktop", isDirectory: true)
            try assertTrue(!NewFilePresentation.shouldReveal(in: desktop, desktopDirectory: desktop))
            try assertTrue(!NewFilePresentation.shouldReveal(in: desktop.appendingPathComponent("./"), desktopDirectory: desktop))
            try assertTrue(NewFilePresentation.shouldReveal(in: desktop.appendingPathComponent("子目录"), desktopDirectory: desktop))
            try assertTrue(NewFilePresentation.shouldReveal(in: URL(fileURLWithPath: "/Users/tester/Downloads/Desktop"), desktopDirectory: desktop))
            try assertTrue(NewFilePresentation.shouldReveal(in: desktop, desktopDirectory: nil), "桌面位置未知时保留原行为")
        }

        runTest("NewFilePresentation 桌面与目标目录的符号链接指向同一位置") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
            let link = root.appendingPathComponent("desktop-link", isDirectory: true)
            try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: desktop)
            try assertTrue(!NewFilePresentation.shouldReveal(in: link, desktopDirectory: desktop))
            try assertTrue(!NewFilePresentation.shouldReveal(in: desktop, desktopDirectory: link))
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
        runTest("UpdateIntegrity 解析 shasum 输出各种格式写法") {
            let hash = String(repeating: "ab", count: 32)
            try assertEqual(UpdateIntegrity.parseChecksum("\(hash)  FinderRight-v1.1.10.zip\n"), hash)
            try assertEqual(UpdateIntegrity.parseChecksum(hash.uppercased()), hash, "大写应归一为小写")
            try assertEqual(UpdateIntegrity.parseChecksum("  \(hash) \n"), hash, "纯哈希且带首尾空白")
            try assertEqual(UpdateIntegrity.parseChecksum("\t\n \(hash)   FinderRight-v1.1.10.zip \r\n"), hash, "多余空白与换行")
            try assertEqual(UpdateIntegrity.parseChecksum("\(hash) *FinderRight-v1.1.10.zip\n"), hash, "二进制模式星号前缀")
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

            // 但只读统计与 inspect 模式下，允许放行 home 和 ~/Library 统计自身与常规子项
            try assertTrue(PathAccessPolicy.isAllowed("/Users/tester", role: .inspect, home: home, temporaryDirectory: tmp), "统计 home 磁盘占用应放行")
            try assertTrue(PathAccessPolicy.isAllowed("/Users/tester/Library", role: .inspect, home: home, temporaryDirectory: tmp), "统计 ~/Library 磁盘占用应放行")
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/tester/Library/Messages", role: .inspect, home: home, temporaryDirectory: tmp), "inspect 依然拒绝直接探测受保护目录内部")
        }

        runTest("PathAccessPolicy 保留原有白名单边界") {
            let home = "/Users/tester", tmp = "/private/var/folders/xx/T"
            try assertTrue(!PathAccessPolicy.isAllowed("/etc/hosts", role: .source, home: home, temporaryDirectory: tmp))
            try assertTrue(!PathAccessPolicy.isAllowed("/Applications/Foo.app", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(!PathAccessPolicy.isAllowed("/System/Volumes/Data/Users/tester/Documents/a", role: .source, home: home, temporaryDirectory: tmp), "firmlink 路径不在白名单")
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/testerx/Documents/a", role: .source, home: home, temporaryDirectory: tmp), "前缀相同的其他用户目录")
        }

        // 23. Services 调用方启发式校验
        runTest("IPCPathPolicy 内容读取与统计 action 必须执行白名单") {
            let restricted = ["copyFileContent", "copyFileHash", "diskUsage", "prefetchDiskUsage",
                              "showDiskUsageDetail", "showLineCount", "copyProjectRelativePath", "copyDirectoryTree"]
            for action in restricted {
                try assertTrue(IPCPathPolicy.requiresWhitelist(action: action), action)
            }
            let exempt = ["openTerminal", "openWithApp", "ping", "toggleHiddenFiles",
                          BadgeReclaimIPC.action, "showCutQueueDetail"]
            for action in exempt {
                try assertTrue(!IPCPathPolicy.requiresWhitelist(action: action), action)
            }
            try assertTrue(IPCPathPolicy.requiresWhitelist(action: "unknownFutureAction"), "新 action 默认不能获得豁免")
        }

        runTest("IPCPathPolicy directory 按读取源和写入目标区分") {
            try assertEqual(IPCPathPolicy.role(action: "prefetchDiskUsage", key: "directory"), .inspect)
            try assertEqual(IPCPathPolicy.role(action: "diskUsage", key: "path"), .inspect)
            try assertEqual(IPCPathPolicy.role(action: "showDiskUsageDetail", key: "path"), .inspect)
            try assertEqual(IPCPathPolicy.role(action: "showLineCount", key: "path"), .inspect)
            try assertEqual(IPCPathPolicy.role(action: "copyDirectoryTree", key: "directory"), .source)
            try assertEqual(IPCPathPolicy.role(action: "runCustomCommand", key: "directory"), .source)
            try assertEqual(IPCPathPolicy.role(action: "createFile", key: "directory"), .destination)
            try assertEqual(IPCPathPolicy.role(action: "pasteFiles", key: "destination"), .destination)
            try assertEqual(IPCPathPolicy.role(action: "copyFileHash", key: "items"), .source)
            try assertNil(IPCPathPolicy.role(action: "copyFileHash", key: "algorithm"))
        }

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
            try store.clear()
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
    }
}
