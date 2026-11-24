import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// 日志脱敏与回归
enum RegressionTests {
    static func run() {
        // MARK: - 日志脱敏与私有存储权限

        runTest("日志脱敏：/Users/<名> 前缀压成 ~") {
            let text = "moved 2 items to /Users/alice/Desktop/项目 from /Users/bob/x.txt"
            try assertEqual(LogRedaction.redactPaths(text), "moved 2 items to ~/Desktop/项目 from ~/x.txt")
        }

        runTest("日志脱敏：外置卷路径含空格也整段隐藏") {
            let text = "watching /Volumes/My Disk/私人 项目\nnext /Volumes/USB/x"
            try assertEqual(LogRedaction.redactPaths(text), "watching <外部卷路径>\nnext <外部卷路径>")
        }

        runTest("日志脱敏：无路径文本原样返回") {
            try assertEqual(LogRedaction.redactPaths("pasteFiles succeeded: moved 3 items"), "pasteFiles succeeded: moved 3 items")
            try assertEqual(LogRedaction.redactPaths(""), "")
            try assertEqual(LogRedaction.redactPaths("/Users/  alone"), "/Users/  alone")
        }

        runTest("私有目录：新建目录为 0700") {
            let base = makeTempDirectory()
            let target = base.appendingPathComponent("FinderRight/ipc", isDirectory: true)
            try PrivateStorage.ensurePrivateDirectory(target)
            let perms = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
            try assertEqual(perms, 0o700)
        }

        runTest("私有目录：已存在的宽松目录被收紧，共享中间层不变") {
            let base = makeTempDirectory()
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.path)
            let target = base.appendingPathComponent("FinderRight", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            try PrivateStorage.ensurePrivateDirectory(target)
            let targetPerms = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
            let basePerms = try FileManager.default.attributesOfItem(atPath: base.path)[.posixPermissions] as? Int
            try assertEqual(targetPerms, 0o700, "目标目录应收紧")
            try assertEqual(basePerms, 0o755, "共享中间层不应被改动")
        }

        runTest("私有文件：0644 收紧为 0600，不存在的文件不创建") {
            let base = makeTempDirectory()
            let file = base.appendingPathComponent("settings.plist")
            try Data("x".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            PrivateStorage.restrictFile(file)
            let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            try assertEqual(perms, 0o600)
            let missing = base.appendingPathComponent("missing.plist")
            PrivateStorage.restrictFile(missing)
            try assertTrue(!FileManager.default.fileExists(atPath: missing.path), "不存在的文件不应被创建")
        }

        // MARK: - 回归测试（注释识别、目录重命名、安全清空与 Git 状态汇总）

        runTest("LineCounter 支持 SQL 块注释、字符串假注释过滤与 Python 多行字符串区分") {
            let dir = makeTempDirectory()
            let sqlFile = dir.appendingPathComponent("query.sql")
            try """
            /* multi
               comment */
            -- line comment
            SELECT '/* not comment */' FROM tbl; -- inline
            """.write(to: sqlFile, atomically: true, encoding: .utf8)
            let sql = LineCounter.count(at: sqlFile)
            try assertEqual(sql?.totalCode, 1)
            try assertEqual(sql?.totalComment, 3)

            let swiftFile = dir.appendingPathComponent("sample.swift")
            try """
            let a = "/* not comment */"
            let b = "// also code"
            let c = "tail" // trailing
            /* block */ let d = 1
            """.write(to: swiftFile, atomically: true, encoding: .utf8)
            let swift = LineCounter.count(at: swiftFile)
            try assertEqual(swift?.totalCode, 4)
            try assertEqual(swift?.totalComment, 0)

            let pyFile = dir.appendingPathComponent("demo.py")
            try """
            \"\"\"
            module docstring
            \"\"\"
            msg = \"\"\"
            hello world
            \"\"\"
            """.write(to: pyFile, atomically: true, encoding: .utf8)
            let py = LineCounter.count(at: pyFile)
            try assertEqual(py?.totalComment, 3)
            try assertEqual(py?.totalCode, 3)
        }

        runTest("UniqueName splitName 保留带点普通目录完整名称并正常拆分文件与包") {
            let dir = makeTempDirectory()
            let fm = FileManager.default
            let dottedFolder = dir.appendingPathComponent("release-v1.0", isDirectory: true)
            try fm.createDirectory(at: dottedFolder, withIntermediateDirectories: true)
            let folderSplit = UniqueName.splitName(for: dottedFolder)
            try assertEqual(folderSplit.baseName, "release-v1.0")
            try assertEqual(folderSplit.ext, "")

            let appPackage = dir.appendingPathComponent("Demo.app", isDirectory: true)
            try fm.createDirectory(at: appPackage.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let appSplit = UniqueName.splitName(for: appPackage)
            try assertEqual(appSplit.baseName, "Demo")
            try assertEqual(appSplit.ext, "app")

            let regular = dir.appendingPathComponent("notes.md")
            try Data("x".utf8).write(to: regular)
            let fileSplit = UniqueName.splitName(for: regular)
            try assertEqual(fileSplit.baseName, "notes")
            try assertEqual(fileSplit.ext, "md")
        }

        runTest("CutQueueStore clearPending 在粘贴在途时拒绝清空，无在途时正常清空") {
            let dir = makeTempDirectory()
            let store = CutQueueStore(directory: dir)
            try store.write(["/tmp/a", "/tmp/b"])
            let batch = try store.take()
            try assertTrue(batch != nil)

            var rejected = false
            do {
                try store.clearPending()
            } catch CutQueueStore.RemovalError.pasteInProgress {
                rejected = true
            }
            try assertTrue(rejected, "在途期间 clearPending 应抛出 pasteInProgress")
            try store.finish(batch!.id)

            try store.write(["/tmp/c", "/tmp/d"])
            try store.clearPending()
            try assertTrue(store.read().isEmpty)
        }

        runTest("GitRepositoryScanner readStatusSummary 与详细快照条目数一致") {
            let dir = makeTempDirectory()
            func runGit(_ args: [String]) throws {
                let res = try ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                    arguments: ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
                                "-c", "user.name=Test", "-c", "user.email=test@example.invalid"] + args,
                    currentDirectoryURL: dir)
                try assertEqual(res.status, 0, res.stderr)
            }
            try runGit(["init", "-b", "main"])
            try "1".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try runGit(["add", "a.txt"])
            try runGit(["commit", "-m", "init"])
            try assertEqual(GitRepositoryScanner.readStatusSummary(at: dir)?.isClean, true)

            try runGit(["mv", "a.txt", "b.txt"])
            let nested = dir.appendingPathComponent("sub/dir", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try "u1".write(to: nested.appendingPathComponent("u1.txt"), atomically: true, encoding: .utf8)
            try "u2".write(to: nested.appendingPathComponent("u2.txt"), atomically: true, encoding: .utf8)

            let snapshot = try GitStatusSnapshot.read(at: dir)
            let summary = GitRepositoryScanner.readStatusSummary(at: dir)
            try assertEqual(summary?.isClean, false)
            try assertEqual(snapshot.entries.count, 3)
            try assertTrue(summary?.description.contains("3") == true, "应反映嵌套未跟踪文件与重命名总数 3：\(summary?.description ?? "nil")")
        }

        runTest("剪贴板历史：容量上限、去重置顶、单项移除与配置持久化") {
            try assertEqual(ClipboardHistoryLimitPreset.defaultLimit, 5)
            try assertEqual(ClipboardHistoryLimitPreset.normalize(5), 5)
            try assertEqual(ClipboardHistoryLimitPreset.normalize(10), 10)
            try assertEqual(ClipboardHistoryLimitPreset.normalize(15), 15)
            try assertEqual(ClipboardHistoryLimitPreset.normalize(20), 20)
            try assertEqual(ClipboardHistoryLimitPreset.normalize(0), 5)
            try assertEqual(ClipboardHistoryLimitPreset.normalize(12), 5)

            var store = ClipboardHistoryStore()
            try assertEqual(store.limit, 5)

            store.record(.text(""))
            store.record(.files([]))
            store.record(.image(Data(), pixelWidth: 10, pixelHeight: 10))
            try assertTrue(store.items.isEmpty, "空内容不应被记录")

            for idx in 1...6 {
                store.record(.text("item-\(idx)"))
            }
            try assertEqual(store.items.count, 5)
            try assertEqual(store.items.map(\.previewText), ["item-6", "item-5", "item-4", "item-3", "item-2"])

            store.record(.text("item-3"))
            try assertEqual(store.items.count, 5)
            try assertEqual(store.items.map(\.previewText), ["item-3", "item-6", "item-5", "item-4", "item-2"])

            let fileA = URL(fileURLWithPath: "/tmp/a.txt")
            let imageData = Data([0x89, 0x50, 0x4E, 0x47])
            store.setLimit(10)
            store.record(.files([fileA]))
            store.record(.image(imageData, pixelWidth: 120, pixelHeight: 80))
            try assertEqual(store.items.count, 7)
            try assertEqual(store.items[0].previewText, "120 × 80")
            try assertEqual(store.items[1].previewText, "a.txt")

            store.record(.files([fileA]))
            try assertEqual(store.items.count, 7)
            try assertEqual(store.items[0].previewText, "a.txt")

            let removedId = store.items[1].id
            store.remove(id: removedId)
            try assertEqual(store.items.count, 6)
            try assertTrue(!store.items.contains { $0.id == removedId })

            store.setLimit(5)
            try assertEqual(store.items.count, 5)
            store.clear()
            try assertTrue(store.items.isEmpty)

            let dir = makeTempDirectory()
            let configURL = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: configURL)
            try assertEqual(config.clipboardEnabled, true)
            try assertEqual(config.clipboardHistoryLimit, 5)
            try assertEqual(config.clipboardRecordSensitive, false)
            try assertEqual(config.clipboardWindowPinned, false)
            try assertEqual(config.clipboardShowDetails, false)
            try assertEqual(config.screenshotEnabled, false)

            config.clipboardEnabled = false
            config.clipboardHistoryLimit = 15
            config.clipboardRecordSensitive = true
            config.clipboardWindowPinned = true
            config.clipboardShowDetails = true
            config.screenshotEnabled = true

            let reloaded = SharedConfig(fileURL: configURL)
            try assertEqual(reloaded.clipboardEnabled, false)
            try assertEqual(reloaded.clipboardHistoryLimit, 15)
            try assertEqual(reloaded.clipboardRecordSensitive, true)
            try assertEqual(reloaded.clipboardWindowPinned, true)
            try assertEqual(reloaded.clipboardShowDetails, true)
            try assertEqual(reloaded.screenshotEnabled, true)

            reloaded.clipboardHistoryLimit = 99
            try assertEqual(SharedConfig(fileURL: configURL).clipboardHistoryLimit, 5)

            // 敏感 / 临时剪贴板标记与系统密码来源应用过滤
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], allowSensitive: false))
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["org.nspasteboard.TransientType"], allowSensitive: false))
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["org.nspasteboard.AutoGeneratedType"], allowSensitive: false))
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["de.petermaurer.TransientPasteboardType"], allowSensitive: false))
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["com.agilebits.onepassword"], allowSensitive: false))
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleIdentifiers: ["com.apple.Passwords"], allowSensitive: false))
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleIdentifiers: ["com.apple.Passwords.MenuBarExtra"], allowSensitive: false))
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleIdentifiers: ["com.apple.keychainaccess"], allowSensitive: false))
            try assertTrue(!ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleIdentifiers: ["com.apple.finder"], allowSensitive: false))
            try assertTrue(!ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleIdentifiers: ["com.apple.Passwords"], allowSensitive: true))
            try assertTrue(!ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], allowSensitive: true))

            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            pasteboard.setString("s3cr3t-pass", forType: .string)
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            let types = (pasteboard.types ?? []).map(\.rawValue)
            try assertTrue(ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: types, allowSensitive: false), "带 ConcealedType 标记时默认应跳过")
            try assertTrue(!ClipboardHistoryStore.shouldIgnorePasteboard(typeIdentifiers: types, allowSensitive: true), "开启记录敏感内容后应允许保存")

            // 菜单栏密码弹窗（LSUIElement）识别与短暂窗口跟踪
            try assertTrue(ClipboardHistoryStore.isSensitiveMenuBarPopover(
                ownerBundleIdentifier: "com.apple.Passwords.MenuBarExtra",
                bounds: CGRect(x: 841, y: 45, width: 320, height: 384),
                layer: 101
            ))
            try assertTrue(!ClipboardHistoryStore.isSensitiveMenuBarPopover(
                ownerBundleIdentifier: "com.apple.Passwords.MenuBarExtra",
                bounds: CGRect(x: 800, y: 0, width: 28, height: 24),
                layer: 25
            ), "状态栏图标本身不应误判为弹窗")
            try assertTrue(!ClipboardHistoryStore.isSensitiveMenuBarPopover(
                ownerBundleIdentifier: "com.apple.finder",
                bounds: CGRect(x: 0, y: 0, width: 600, height: 400),
                layer: 101
            ))
            try assertEqual(
                ClipboardHistoryStore.quartzPoint(fromCocoaPoint: CGPoint(x: 900, y: 800), primaryScreenHeight: 900),
                CGPoint(x: 900, y: 100)
            )

            var tracker = ClipboardHistoryStore.SensitiveMenuBarTracker()
            let t0 = Date(timeIntervalSince1970: 1_700_000_000)
            tracker.arm(changeCount: 10, now: t0, graceInterval: 1.5)
            try assertTrue(tracker.consumeIfActive(newChangeCount: 11, now: t0.addingTimeInterval(0.4)), "窗口期内首次变更应命中跳过")
            try assertTrue(!tracker.consumeIfActive(newChangeCount: 12, now: t0.addingTimeInterval(0.6)), "消费一次后不应继续拦截后续普通复制")
            tracker.arm(changeCount: 12, now: t0, graceInterval: 1.5)
            tracker.clear()
            try assertTrue(!tracker.consumeIfActive(newChangeCount: 13, now: t0.addingTimeInterval(0.2)), "点击弹窗外部清理后不应误拦")
            tracker.arm(changeCount: 13, now: t0, graceInterval: 1.5)
            try assertTrue(!tracker.consumeIfActive(newChangeCount: 14, now: t0.addingTimeInterval(2.0)), "超过宽限时间后不应再拦截")
        }

        runTest("截图方式配置持久化与坐标换算") {
            let dir = makeTempDirectory()
            let configURL = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: configURL)
            try assertEqual(config.screenshotMode, .system)

            config.screenshotMode = .snapshot
            let reloaded = SharedConfig(fileURL: configURL)
            try assertEqual(reloaded.screenshotMode, .snapshot)

            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let utc = TimeZone(secondsFromGMT: 0)!
            try assertEqual(
                ScreenshotSnapshotGeometry.defaultBaseName(at: date, timeZone: utc, prefix: "截图"),
                "截图 2023-11-14 22.13.20"
            )

            let viewSize = CGSize(width: 1440, height: 900)
            let crop = ScreenshotSnapshotGeometry.pixelCropRect(
                selectionInView: CGRect(x: 100, y: 200, width: 300, height: 150),
                viewSize: viewSize,
                imageWidth: 2880,
                imageHeight: 1800
            )
            // AppKit 左下角 (100, 200, 300, 150) 翻转到像素左上角：
            // x = 200, y = (900 - 350) * 2 = 1100, w = 600, h = 300
            try assertEqual(crop, CGRect(x: 200, y: 1100, width: 600, height: 300))

            // 越界矩形应被裁剪到图像范围内
            let edgeCrop = ScreenshotSnapshotGeometry.pixelCropRect(
                selectionInView: CGRect(x: -10, y: 800, width: 100, height: 200),
                viewSize: viewSize,
                imageWidth: 2880,
                imageHeight: 1800
            )
            try assertEqual(edgeCrop, CGRect(x: 0, y: 0, width: 180, height: 200))

            // 极小选区应返回 nil
            try assertNil(
                ScreenshotSnapshotGeometry.pixelCropRect(
                    selectionInView: CGRect(x: 10, y: 10, width: 0.4, height: 0.4),
                    viewSize: viewSize,
                    imageWidth: 2880,
                    imageHeight: 1800
                )
            )
        }

        runTest("快照截图：画笔轨迹合成坐标与颜色映射") {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let width = 40
            let height = 20
            let baseContext = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            baseContext.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            baseContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let cropped = baseContext.makeImage()!

            // 模拟 viewSize=(100, 100), fullImage=(200, 200) -> 2x Retina
            // selectionRect = (30, 40, 20, 10) -> pixelCropRect: x=60, y=(100-50)*2=100, w=40, h=20
            let cropRect = CGRect(x: 60, y: 100, width: 40, height: 20)
            // 在选区中心 (40, 45) 画红色线段到 (45, 45)
            let stroke = ScreenshotBrushStroke(
                points: [CGPoint(x: 40, y: 45), CGPoint(x: 45, y: 45)],
                color: ScreenshotRGBA(red: 1, green: 0, blue: 0),
                lineWidth: 2
            )
            let rendered = ScreenshotSnapshotGeometry.renderCroppedImage(
                cropped,
                strokes: [stroke],
                viewSize: CGSize(width: 100, height: 100),
                imageWidth: 200,
                imageHeight: 200,
                cropRect: cropRect
            )

            // 将渲染结果读出像素：在 cropped 坐标系中，(40, 45) 对应 x = 40*2 - 60 = 20,
            // 自顶向下 y = (100 - 45)*2 - 100 = 10（即中心）
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let readCtx = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            readCtx.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))

            let centerOffset = (10 * width + 20) * 4
            try assertTrue(pixels[centerOffset] > 220, "中心像素应为红色 R=\(pixels[centerOffset])")
            try assertTrue(pixels[centerOffset + 1] < 30, "中心像素 G 应接近 0")
            try assertTrue(pixels[centerOffset + 2] < 30, "中心像素 B 应接近 0")

            let cornerOffset = 0
            try assertEqual(pixels[cornerOffset], 0)
            try assertEqual(pixels[cornerOffset + 1], 0)
            try assertEqual(pixels[cornerOffset + 2], 0)
        }

        runTest("剪贴板历史：持久化、权限免备份、淘汰清理与清空") {
            let root = makeTempDirectory()
            let dir = root.appendingPathComponent("clipboard-history", isDirectory: true)
            let persistence = ClipboardHistoryPersistence(directoryURL: dir)

            let imageA = Data([0x89, 0x50, 0x4E, 0x47, 0x01])
            let imageB = Data([0x89, 0x50, 0x4E, 0x47, 0x02])
            let t1 = Date(timeIntervalSince1970: 1_700_000_001)
            let t2 = Date(timeIntervalSince1970: 1_700_000_002)
            let t3 = Date(timeIntervalSince1970: 1_700_000_003)

            var store = ClipboardHistoryStore(limit: 10)
            let id1 = UUID()
            let id2 = UUID()
            let id3 = UUID()
            for idx in 1...3 {
                store.record(.text("extra-\(idx)"), now: Date(timeIntervalSince1970: 1_699_999_990 + Double(idx)))
            }
            store.record(.text("hello clipboard"), id: id1, now: t1)
            store.record(.image(imageA, pixelWidth: 320, pixelHeight: 240), id: id2, now: t2)
            store.record(.files([URL(fileURLWithPath: "/tmp/demo.txt")]), id: id3, now: t3)

            persistence.save(store.items)

            let fm = FileManager.default
            let dirAttrs = try fm.attributesOfItem(atPath: dir.path)
            try assertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700, "历史目录权限应为 0700")
            let resourceValues = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
            try assertEqual(resourceValues.isExcludedFromBackup, true, "历史目录应排除系统备份")

            let indexAttrs = try fm.attributesOfItem(atPath: persistence.indexFileURL.path)
            try assertEqual((indexAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "索引文件权限应为 0600")
            let imageAFile = dir.appendingPathComponent("\(id2.uuidString).png")
            let imgAttrs = try fm.attributesOfItem(atPath: imageAFile.path)
            try assertEqual((imgAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "图片文件权限应为 0600")

            let restored = persistence.load(limit: 10)
            try assertEqual(restored.count, 6)
            try assertEqual(restored, store.items)
            let limited = persistence.load(limit: 5)
            try assertEqual(limited, Array(store.items.prefix(5)))

            // 替换/淘汰图片后应清理孤立图片文件
            let id4 = UUID()
            let updatedItems = [
                ClipboardItem(id: id4, kind: .image(imageB, pixelWidth: 64, pixelHeight: 64), copiedAt: Date(timeIntervalSince1970: 1_700_000_004)),
                store.items[0],
            ]
            persistence.save(updatedItems)
            try assertTrue(!fm.fileExists(atPath: imageAFile.path), "被移除条目的图片文件应被清理")
            let imageBFile = dir.appendingPathComponent("\(id4.uuidString).png")
            try assertTrue(fm.fileExists(atPath: imageBFile.path), "保留条目的图片文件应存在")

            // 超限文本与超限图片不落盘
            let oversizedText = String(repeating: "a", count: ClipboardHistoryPersistence.maxTextUTF8Bytes + 1)
            let oversizedImage = Data(count: ClipboardHistoryPersistence.maxImageBytes + 1)
            persistence.save([
                ClipboardItem(kind: .text(oversizedText)),
                ClipboardItem(kind: .image(oversizedImage, pixelWidth: 100, pixelHeight: 100)),
                updatedItems[0],
            ])
            let afterLimit = persistence.load(limit: 10)
            try assertEqual(afterLimit.count, 1)
            try assertEqual(afterLimit[0], updatedItems[0])

            // 索引含损坏项、缺失图片或路径穿越名时只跳过非法项，不丢正常项
            let escapeFile = root.appendingPathComponent("escape.png")
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: escapeFile)
            let mixedJSON = """
            [
              {"broken": true},
              {"id":"\(UUID().uuidString)","copiedAt":1700000000,"type":"image","imageFileName":"../escape.png","pixelWidth":10,"pixelHeight":10},
              {"id":"\(UUID().uuidString)","copiedAt":1700000000,"type":"image","imageFileName":"missing.png","pixelWidth":10,"pixelHeight":10},
              {"id":"\(id1.uuidString)","copiedAt":1700000001,"type":"text","text":"kept item"}
            ]
            """
            try mixedJSON.data(using: .utf8)!.write(to: persistence.indexFileURL)
            let mixedLoaded = persistence.load(limit: 5)
            try assertEqual(mixedLoaded.count, 1)
            try assertEqual(mixedLoaded[0].kind, .text("kept item"))

            // 空列表与 clear 均删除整个目录
            persistence.save([])
            try assertTrue(!fm.fileExists(atPath: dir.path), "保存空列表应删除历史目录")

            persistence.save(updatedItems)
            try assertTrue(fm.fileExists(atPath: dir.path))
            persistence.clear()
            try assertTrue(!fm.fileExists(atPath: dir.path), "clear 应删除整个历史目录")

            let excludedDir = root.appendingPathComponent("FinderRightClipboard-123", isDirectory: true)
            let siblingDir = root.appendingPathComponent("FinderRightClipboard-1234", isDirectory: true)
            let localA = root.appendingPathComponent("a.txt")
            let localB = siblingDir.appendingPathComponent("b.txt")
            let insideExcluded = excludedDir.appendingPathComponent("temp.png")
            let normalized = ClipboardHistoryStore.normalizedFileURLs([
                URL(string: "https://example.com/demo.png")!,
                localA,
                insideExcluded,
                localB,
                URL(fileURLWithPath: localA.path),
            ], excludingDirectory: excludedDir)
            try assertEqual(normalized, [localA.standardizedFileURL, localB.standardizedFileURL], "应保留本地文件并排除临时拖拽目录且保留同前缀兄弟目录")
        }
    }
}
