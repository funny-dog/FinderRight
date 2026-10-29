import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit

// MARK: - 测试辅助断言

private var totalTests = 0
private var passedTests = 0
private var failedTests = 0

private func runTest(_ name: String, _ block: () throws -> Void) {
    if let filter = ProcessInfo.processInfo.environment["FINDERRIGHT_TEST_FILTER"], !filter.isEmpty {
        guard name.contains(filter) else { return }
    }
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

private func transformTestImage(sourceURL: URL, operation: ImageTransformOperation) throws -> URL {
    try ImageTransformer.process(sourceURL: sourceURL, operation: operation,
                                 registry: ScratchDirectoryRegistry(registryDirectory: sourceURL.deletingLastPathComponent()))
}

/// 生成指定宽高与颜色的测试图片
private func makeTestPNG(width: Int, height: Int, fillColor: CGColor, hasAlpha: Bool = false) -> (URL, URL) {
    let tempDir = makeTempDirectory()
    let file = tempDir.appendingPathComponent("test_\(UUID().uuidString).png")
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo)!
    if !hasAlpha {
        ctx.setFillColor(fillColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    } else {
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(fillColor)
        ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
    }
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
    return (file, tempDir)
}

/// 生成非对称双色带 EXIF 方向的 JPEG（左半红，右半蓝，EXIF 方向为 orientation）
private func makeTestAsymmetricDualColorJPEG(width: Int, height: Int, orientation: Int) -> (URL, URL) {
    let tempDir = makeTempDirectory()
    let file = tempDir.appendingPathComponent("asym_\(UUID().uuidString).jpg")
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    // 左半部分：纯红 (1, 0, 0)
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    // 右半部分：纯蓝 (0, 0, 1)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFOrientation: orientation]
    ]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return (file, tempDir)
}

/// 生成包含旧元数据（TIFF/Exif 尺寸与方向）的测试图
private func makeTestJPEGWithOldMetadata(width: Int, height: Int) -> (URL, URL) {
    let tempDir = makeTempDirectory()
    let file = tempDir.appendingPathComponent("meta_\(UUID().uuidString).jpg")
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.5, green: 0.8, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFOrientation: 6,
            "ImageWidth" as CFString: width,
            "ImageLength" as CFString: height
        ],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifPixelXDimension: width,
            kCGImagePropertyExifPixelYDimension: height
        ]
    ]
    CGImageDestinationAddImage(dest, img, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    return (file, tempDir)
}

/// 生成 100x100 像素的有效 WebP 测试图片（只读格式）
private func makeTestWebP() -> (URL, URL) {
    let tempDir = makeTempDirectory()
    let file = tempDir.appendingPathComponent("test_\(UUID().uuidString).webp")
    let webpBytes: [UInt8] = [
        82, 73, 70, 70, 102, 0, 0, 0, 87, 69, 66, 80, 86, 80, 56, 32, 90, 0, 0, 0,
        16, 6, 0, 157, 1, 42, 100, 0, 100, 0, 62, 109, 54, 153, 73, 164, 35, 34,
        161, 32, 168, 0, 128, 13, 137, 105, 110, 225, 115, 233, 112, 31, 128, 0,
        1, 141, 174, 166, 247, 17, 121, 96, 26, 234, 111, 113, 23, 150, 1, 174, 166,
        247, 17, 121, 96, 26, 120, 0, 254, 254, 81, 125, 255, 255, 144, 92, 176,
        186, 228, 107, 255, 255, 32, 63, 228, 7, 252, 128, 255, 248, 248, 166, 70,
        149, 42, 116, 32, 0, 0, 0
    ]
    try! Data(webpBytes).write(to: file)
    return (file, tempDir)
}

/// 生成多帧 GIF
private func makeMultiFrameGIF() -> (URL, URL) {
    let tempDir = makeTempDirectory()
    let file = tempDir.appendingPathComponent("test_\(UUID().uuidString).gif")
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
    let img1 = ctx.makeImage()!
    ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
    let img2 = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(file as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
    CGImageDestinationAddImage(dest, img1, nil)
    CGImageDestinationAddImage(dest, img2, nil)
    CGImageDestinationFinalize(dest)
    return (file, tempDir)
}

/// 获取图片指定坐标的像素 RGB
private func getPixelRGB(at point: CGPoint, from imageURL: URL) -> (r: UInt8, g: UInt8, b: UInt8)? {
    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = img.width
    let height = img.height
    let x = Int(point.x)
    let y = Int(point.y)
    guard x >= 0, x < width, y >= 0, y < height else { return nil }
    var pixelData = [UInt8](repeating: 0, count: 4)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let ctx = CGContext(data: &pixelData, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: -x, y: -y, width: width, height: height))
    return (pixelData[0], pixelData[1], pixelData[2])
}

/// 目录下的全部条目名（含隐藏项，已排序）
private func directoryListing(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

/// 带一个 stored 文件的普通 ZIP，可修改字段验证目录解析边界。
private func previewZipFixture(_ name: String, flags: UInt16 = 0x0800, mode: UInt32 = 0o100644) -> Data {
    let name = Data(name.utf8)
    var local = Data(repeating: 0, count: 30)
    putZipField(0x04034b50, at: 0, into: &local)
    putZipField(20, at: 4, bytes: 2, into: &local)
    putZipField(UInt32(flags), at: 6, bytes: 2, into: &local)
    putZipField(0x3610a686, at: 14, into: &local) // "hello" 的 CRC32
    putZipField(5, at: 18, into: &local)
    putZipField(5, at: 22, into: &local)
    putZipField(UInt32(name.count), at: 26, bytes: 2, into: &local)
    local.append(name)
    local.append(Data("hello".utf8))
    var directory = Data(repeating: 0, count: 46)
    putZipField(0x02014b50, at: 0, into: &directory)
    putZipField(0x0314, at: 4, bytes: 2, into: &directory)
    putZipField(20, at: 6, bytes: 2, into: &directory)
    putZipField(UInt32(flags), at: 8, bytes: 2, into: &directory)
    putZipField(0x3610a686, at: 16, into: &directory)
    putZipField(5, at: 20, into: &directory)
    putZipField(5, at: 24, into: &directory)
    putZipField(UInt32(name.count), at: 28, bytes: 2, into: &directory)
    putZipField(mode << 16, at: 38, into: &directory)
    directory.append(name)
    var end = Data(repeating: 0, count: 22)
    putZipField(0x06054b50, at: 0, into: &end)
    putZipField(1, at: 8, bytes: 2, into: &end)
    putZipField(1, at: 10, bytes: 2, into: &end)
    putZipField(UInt32(directory.count), at: 12, into: &end)
    putZipField(UInt32(local.count), at: 16, into: &end)
    return local + directory + end
}

private func putZipField(_ value: UInt32, at offset: Int, bytes: Int = 4, into data: inout Data) {
    for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
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

        runTest("Preview 文件夹只读当前层、包含隐藏项、不展开链接与文件包，并限制数量") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("目录/下层"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work.appendingPathComponent("Demo.app/Contents"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("中文.txt"))
            try Data().write(to: work.appendingPathComponent(".hidden"))
            let link = work.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: work.appendingPathComponent("目录"))
            let listing = try PreviewContents.folder(work)
            try assertEqual(listing.entries.count, 5)
            try assertTrue(!listing.truncated)
            try assertTrue(listing.entries.contains { $0.path == ".hidden" })
            try assertEqual(listing.entries.first { $0.path == "中文.txt" }?.size, 5)
            try assertEqual(listing.entries.first { $0.path == "Demo.app" }?.isDirectory, false)
            try assertEqual(listing.entries.first { $0.path == "link" }?.isSymbolicLink, true)
            try assertTrue(!listing.entries.contains { $0.path.contains("/") })
            try assertTrue(try PreviewContents.folder(work, limit: 1).truncated)
            try assertEqual(try PreviewContents.folder(work, limit: 0).entries.count, 0)
            do {
                _ = try PreviewContents.folder(link)
                throw TestFailure(message: "不应跟随链接枚举目录")
            } catch is CocoaError {}
        }

        runTest("Preview 文件夹始终过滤 .DS_Store 与 ._*，其余隐藏项照常展示") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            for name in [".DS_Store", "._报告.txt", ".env", "flagged", "报告.txt"] {
                try Data().write(to: work.appendingPathComponent(name))
            }
            try FileManager.default.createDirectory(at: work.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let chflags = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/chflags"),
                                                arguments: ["hidden", work.appendingPathComponent("flagged").path])
            try assertEqual(chflags.status, 0, chflags.stderr)
            try assertEqual(try PreviewContents.folder(work).entries.map(\.path).sorted(),
                            [".env", ".git", "flagged", "报告.txt"])
            // 上限按可见项计算：被过滤的项不占名额，也不触发截断
            try assertTrue(!(try PreviewContents.folder(work, limit: 4)).truncated)
            try assertTrue(try PreviewContents.folder(work, limit: 3).truncated)
        }

        runTest("Preview ZIP 始终过滤 __MACOSX/._*/.DS_Store，其余点文件照常展示") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            for dir in ["资料/.cache", "__MACOSX/资料", ".git"] {
                try FileManager.default.createDirectory(at: work.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            for file in ["资料/报告.txt", "资料/.env", "资料/.cache/x", "资料/.DS_Store", "__MACOSX/资料/._报告.txt",
                         "._top", ".git/config", "a.txt"] {
                try Data("x".utf8).write(to: work.appendingPathComponent(file))
            }
            let zip = try makeZip("hidden.zip", in: work, entries: ["资料", "__MACOSX", "._top", ".git", "a.txt"],
                                  options: ["--options", "zip:hdrcharset=UTF-8"])
            // tar 可能为扩展属性额外写入 ._* 条目，一并验证被过滤
            let expected = [".git/", ".git/config", "a.txt", "资料/", "资料/.cache/", "资料/.cache/x",
                            "资料/.env", "资料/报告.txt"]
            try assertEqual(try PreviewContents.zip(zip).entries.map(\.path).sorted(), expected)
            try assertTrue(!(try PreviewContents.zip(zip, limit: expected.count)).truncated)
            try assertTrue(try PreviewContents.zip(zip, limit: expected.count - 1).truncated)
        }

        runTest("Preview 中文 ZIP 的元数据、GBK、加密目录和数量上限") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("资料"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("资料/报告.txt"))
            for (name, options) in [("utf8", ["--options", "zip:hdrcharset=UTF-8"]),
                                     ("gbk", ["--options", "zip:hdrcharset=CP936"]),
                                     ("encrypted", ["--options", "zip:encryption=zipcrypt,zip:hdrcharset=UTF-8", "--passphrase", "pw"])] {
                let zip = try makeZip(name + ".zip", in: work, entries: ["资料"], options: options)
                let listing = try PreviewContents.zip(zip)
                let file = listing.entries.first { $0.path == "资料/报告.txt" }
                try assertEqual(file?.size, 5, name)
                try assertTrue(file?.modificationDate != nil, name)
                try assertTrue(listing.entries.contains { $0.isDirectory && $0.path == "资料/" }, name)
                try assertTrue(try PreviewContents.zip(zip, limit: 1).truncated, name)
            }
        }

        runTest("Preview ZIP 隐式目录与符号链接只读元数据") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("test.zip")
            try previewZipFixture("a/b/中文.txt").write(to: zip)
            let listing = try PreviewContents.zip(zip)
            try assertEqual(listing.entries.map(\.path), ["a/b/中文.txt"])
            try assertEqual(listing.entries.first?.size, 5)
            try previewZipFixture("link", mode: 0o120777).write(to: zip)
            try assertEqual(try PreviewContents.zip(zip).entries.first?.isSymbolicLink, true)
        }

        runTest("Preview ZIP 空包与注释中的伪 EOCD") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("test.zip")
            var empty = Data(repeating: 0, count: 22)
            putZipField(0x06054b50, at: 0, into: &empty)
            try empty.write(to: zip)
            try assertEqual(try PreviewContents.zip(zip).entries.count, 0)
            var data = previewZipFixture("file.txt")
            putZipField(22, at: data.count - 2, bytes: 2, into: &data)
            data.append(empty)
            try data.write(to: zip)
            try assertEqual(try PreviewContents.zip(zip).entries.map(\.path), ["file.txt"])
        }

        runTest("Preview ZIP 拒绝损坏、ZIP64、分卷和异常目录字段") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("test.zip")
            func rejects(_ data: Data, _ expected: PreviewError) throws {
                try data.write(to: zip)
                let result = Result { try PreviewContents.zip(zip) }
                guard case let .failure(error) = result else {
                    throw TestFailure(message: "应拒绝异常 ZIP")
                }
                try assertEqual(error as? PreviewError, expected)
            }
            try rejects(Data("broken".utf8), .invalidArchive)
            let original = previewZipFixture("file.txt")
            try rejects(Data(original.dropLast()), .invalidArchive)
            var zip64 = original
            putZipField(0xFFFF, at: zip64.count - 12, bytes: 2, into: &zip64)
            try rejects(zip64, .zip64NotSupported)
            var split = original
            putZipField(1, at: split.count - 18, bytes: 2, into: &split)
            try rejects(split, .multiDiskNotSupported)
            var overflow = original
            putZipField(0xFFFF_FFFE, at: overflow.count - 10, into: &overflow)
            try rejects(overflow, .invalidArchive)
            try rejects(previewZipFixture("file.txt", flags: 0x2000), .encryptedDirectory)
        }

        runTest("Preview ZIP 拒绝绝对路径、穿越、空组件及过深路径") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("test.zip")
            for name in ["../x", "/x", "a//x", "a/./x", "C:/x", "a\\..\\x", String(repeating: "a/", count: 32) + "x"] {
                try previewZipFixture(name).write(to: zip)
                do {
                    _ = try PreviewContents.zip(zip)
                    throw TestFailure(message: "应拒绝路径 \(name)")
                } catch let error as PreviewError { try assertEqual(error, .invalidPath, name) }
            }
        }

        runTest("Preview ZIP 不读取管道或符号链接") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let fifo = work.appendingPathComponent("pipe.zip")
            try assertEqual(mkfifo(fifo.path, 0o600), 0)
            let file = work.appendingPathComponent("file.zip")
            try previewZipFixture("a.txt").write(to: file)
            let link = work.appendingPathComponent("link.zip")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            for url in [fifo, link] {
                do {
                    _ = try PreviewContents.zip(url)
                    throw TestFailure(message: "应拒绝非普通文件 \(url)")
                } catch let error as CocoaError { try assertEqual(error.code, .fileReadUnsupportedScheme) }
            }
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

        runTest("ExtractedOutput 以 ._ 开头的普通文件计入顶层项，不随暂存目录丢失") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let root = try makeExtractedRoot(in: work, ["foo/", "._notes.txt"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "pack")
            try assertEqual(placed.lastPathComponent, "pack", "两项应整体放入文件夹")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("._notes.txt").path))
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("foo/inner.txt").path))
        }

        runTest("ExtractedOutput 顶层 AppleDouble 与 __MACOSX 一样忽略") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let root = try makeExtractedRoot(in: work, ["foo/"])
            try Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]).write(to: root.appendingPathComponent("._foo"))
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "foo")
            try assertEqual(placed.lastPathComponent, "foo")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("inner.txt").path), "不应出现 foo/foo 嵌套")
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

        runTest("RecentOperations 新记录在前、超出容量丢弃最旧与清空") {
            let ops = RecentOperations(capacity: 3)
            ops.record(OperationRecord(kind: .compress, subject: "a"))
            ops.record(OperationRecord(kind: .decompress, subject: "b", failure: "坏包"))
            ops.record(OperationRecord(kind: .paste, subject: "c"))
            ops.record(OperationRecord(kind: .compress, subject: "d", failure: "磁盘满"))
            try assertEqual(ops.records.map(\.subject), ["d", "c", "b"])
            try assertEqual(ops.records.count, 3)
            ops.clear()
            try assertTrue(ops.records.isEmpty)
        }

        runTest("RecentOperations 已取消不算成功但正常记录") {
            let ops = RecentOperations(capacity: 3)
            let cancelled = OperationRecord(kind: .decompress, subject: "secret.zip", cancelled: true)
            try assertTrue(!cancelled.succeeded, "已取消不算成功")
            ops.record(cancelled)
            try assertEqual(ops.records.first?.cancelled, true)
            try assertEqual(ops.records.first?.subject, "secret.zip")
        }

        runTest("RecentOperations 容量为0时不保留历史记录") {
            let ops = RecentOperations(capacity: 0)
            try assertEqual(ops.capacity, 0)
            ops.record(OperationRecord(kind: .compress, subject: "a", failure: "坏包"))
            try assertTrue(ops.records.isEmpty, "容量为0不记录到内存")
        }

        runTest("RecentOperations 排序裁剪与恢复时按日期排序") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history-sort.json")
            let ops = RecentOperations(capacity: 3, storageURL: fileURL)

            let now = Date()
            let r1 = OperationRecord(kind: .copy, subject: "1", date: now.addingTimeInterval(-30))
            let r2 = OperationRecord(kind: .move, subject: "2", date: now.addingTimeInterval(-20))
            let r3 = OperationRecord(kind: .createFile, subject: "3", date: now.addingTimeInterval(-10))
            let r4 = OperationRecord(kind: .cut, subject: "4", date: now)

            ops.record(r1)
            ops.record(r2)
            ops.record(r3)
            ops.record(r4)
            ops.record(OperationRecord(kind: .copy, subject: "older", date: now.addingTimeInterval(-100)))

            try assertEqual(ops.records.map(\.subject), ["4", "3", "2"], "迟到的旧记录不能挤掉较新的记录")

            let restored = RecentOperations(capacity: 2, storageURL: fileURL)
            try assertEqual(restored.records.map(\.subject), ["4", "3"])
        }

        runTest("RecentOperations 重启恢复字段及UUID与权限保护") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history-fields.json")
            let ops = RecentOperations(capacity: 10, storageURL: fileURL)

            let customID = UUID()
            let locationURL = URL(fileURLWithPath: "/tmp/project")
            let results = [URL(fileURLWithPath: "/tmp/project/a.txt"), URL(fileURLWithPath: "/tmp/project/b.txt")]
            let date = Date()

            let record = OperationRecord(
                id: customID,
                kind: .createFile,
                subject: "new-file.swift",
                failure: "权限不足",
                results: results,
                cancelled: false,
                date: date,
                location: locationURL
            )
            ops.record(record)

            let restored = RecentOperations(capacity: 10, storageURL: fileURL)
            try assertEqual(restored.records.count, 1)
            guard let item = restored.records.first else {
                throw TestFailure(message: "恢复记录为空")
            }
            try assertEqual(item.id, customID, "UUID 保持一致")
            try assertEqual(item.kind, .createFile)
            try assertEqual(item.subject, "new-file.swift")
            try assertEqual(item.failure, "权限不足")
            try assertEqual(item.results, results)
            try assertEqual(item.cancelled, false)
            try assertEqual(item.location, locationURL)
            try assertEqual(item.succeeded, false)

            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let permissions = attrs[.posixPermissions] as? NSNumber {
                try assertEqual(permissions.intValue, 0o600, "持久化文件权限必须为仅用户可读写 0o600")
            }
        }

        runTest("RecentOperations 容量缩减与设置为0立即清空磁盘与内存") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history-capacity.json")
            let ops = RecentOperations(capacity: 5, storageURL: fileURL)

            for i in 1...5 {
                ops.record(OperationRecord(kind: .compress, subject: "item-\(i)"))
            }
            try assertEqual(ops.records.count, 5)
            try assertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            ops.setCapacity(2)
            try assertEqual(ops.capacity, 2)
            try assertEqual(ops.records.map(\.subject), ["item-5", "item-4"])

            let reloaded = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertEqual(reloaded.records.map(\.subject), ["item-5", "item-4"])

            ops.setCapacity(0)
            try assertEqual(ops.capacity, 0)
            try assertTrue(ops.records.isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: fileURL.path), "容量为0时磁盘文件必须被清空删除")
        }

        runTest("RecentOperations 清空后重载") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history-clear.json")
            let ops = RecentOperations(capacity: 5, storageURL: fileURL)
            ops.record(OperationRecord(kind: .paste, subject: "paste-item"))
            try assertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            ops.clear()
            try assertTrue(ops.records.isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: fileURL.path))

            let reloaded = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertTrue(reloaded.records.isEmpty)
            try assertNil(reloaded.persistenceError)
        }

        runTest("RecentOperations 损坏与不可写路径容错") {
            let dir = makeTempDirectory()
            let corruptURL = dir.appendingPathComponent("corrupt.json")
            try "invalid json content".write(to: corruptURL, atomically: true, encoding: .utf8)

            let corruptOps = RecentOperations(capacity: 5, storageURL: corruptURL)
            try assertTrue(corruptOps.records.isEmpty, "损坏文件加载后内存保持为空")
            try assertTrue(corruptOps.persistenceError != nil, "损坏文件需记录 persistenceError")
            corruptOps.setCapacity(5)
            try assertTrue(corruptOps.persistenceError != nil, "启动时同步相同容量不能抹掉加载失败信息")
            try assertEqual(try String(contentsOf: corruptURL), "invalid json content")

            let roDir = dir.appendingPathComponent("read-only-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: roDir.path)

            let roOps = RecentOperations(capacity: 5, storageURL: roDir.appendingPathComponent("history.json"))
            roOps.record(OperationRecord(kind: .copy, subject: "fallback-item"))
            try assertEqual(roOps.records.map(\.subject), ["fallback-item"], "不可写时内存仍应保留")
            try assertTrue(roOps.persistenceError != nil, "写入失败需记录 persistenceError")

            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: roDir.path)
        }

        runTest("RecentOperations 无法识别的记录逐条跳过并留底原文件") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history.json")
            let backupURL = dir.appendingPathComponent("history.unreadable.json")
            let known = OperationRecord(kind: .copy, subject: "known", date: Date())
            // 模拟降级：新版本写入了旧版本不认识的操作类型
            var entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode([known])) as! [[String: Any]]
            var future = entries[0]
            future["id"] = UUID().uuidString
            future["kind"] = "futureKind"
            future["subject"] = "from-newer-version"
            entries.insert(future, at: 0)
            let original = try JSONSerialization.data(withJSONObject: entries)
            try original.write(to: fileURL)

            let ops = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertEqual(ops.records.map(\.subject), ["known"], "可识别的记录照常加载")
            try assertNil(ops.persistenceError)
            try assertEqual(try Data(contentsOf: backupURL), original, "覆盖前原文件必须留底")

            ops.record(OperationRecord(kind: .paste, subject: "new"))
            let reloaded = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertEqual(reloaded.records.map(\.subject), ["new", "known"])
            try assertEqual(try Data(contentsOf: backupURL), original, "后续写入不能动备份")
        }

        runTest("RecentOperations 损坏文件先留底再覆盖") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history.json")
            let backupURL = dir.appendingPathComponent("history.unreadable.json")
            try "invalid json content".write(to: fileURL, atomically: true, encoding: .utf8)

            let ops = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertEqual(try String(contentsOf: backupURL), "invalid json content")
            ops.record(OperationRecord(kind: .copy, subject: "after-corrupt"))
            try assertNil(ops.persistenceError, "留底成功后可以正常保存")
            try assertEqual(RecentOperations(capacity: 5, storageURL: fileURL).records.map(\.subject), ["after-corrupt"])
            try assertEqual(try String(contentsOf: backupURL), "invalid json content")
        }

        runTest("RecentOperations 无法留底时不覆盖原文件") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history.json")
            try "invalid json content".write(to: fileURL, atomically: true, encoding: .utf8)
            // 备份位置被一个删不掉的目录占住，留底必然失败
            let locked = dir.appendingPathComponent("history.unreadable.json/locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try "x".write(to: locked.appendingPathComponent("f"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

            let ops = RecentOperations(capacity: 5, storageURL: fileURL)
            ops.record(OperationRecord(kind: .copy, subject: "kept-in-memory"))
            try assertEqual(ops.records.map(\.subject), ["kept-in-memory"])
            try assertTrue(ops.persistenceError != nil, "暂停保存需要提示")
            try assertEqual(try String(contentsOf: fileURL), "invalid json content", "未留底的文件不能被覆盖")

            ops.clear()
            try assertTrue(!FileManager.default.fileExists(atPath: fileURL.path), "用户主动清空时可以删除")
            ops.record(OperationRecord(kind: .copy, subject: "after-clear"))
            try assertEqual(RecentOperations(capacity: 5, storageURL: fileURL).records.map(\.subject), ["after-clear"],
                            "清空后恢复正常保存")
        }

        runTest("RecentOperations 容量0仍发完成事件") {
            var receivedRecord: OperationRecord?
            var onMainThread = false
            let observer = NotificationCenter.default.addObserver(
                forName: RecentOperations.didFinishNotification,
                object: nil,
                queue: nil
            ) { notif in
                onMainThread = Thread.isMainThread
                receivedRecord = notif.object as? OperationRecord
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let ops = RecentOperations(capacity: 0, storageURL: nil)
            let rec = OperationRecord(kind: .cut, subject: "zero-capacity-event.txt")
            ops.record(rec)

            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

            try assertTrue(onMainThread, "完成事件必须在主线程发出")
            try assertEqual(receivedRecord?.subject, "zero-capacity-event.txt")
            try assertEqual(receivedRecord?.kind, .cut)
            try assertTrue(ops.records.isEmpty, "容量为0时不保留在内存历史中")
        }

        runTest("RecentOperations 清空历史不影响独立UndoCenter实例") {
            let dir = makeTempDirectory()
            let center = UndoCenter(stateDirectory: dir)
            let fp = FileFingerprint(fileNumber: 1, device: 1, isDirectory: false, modificationDate: nil, size: 0)
            let move = UndoRecord(kind: .move, name: "Projects", items: [
                .init(current: URL(fileURLWithPath: "/tmp/Projects/a"), original: URL(fileURLWithPath: "/tmp/a"), fingerprint: fp)
            ], cutQueueBefore: nil, finderSnapshot: nil)
            center.register(move)
            try assertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(UndoMenuState.fileName).path))

            let historyURL = dir.appendingPathComponent("operation-history.json")
            let ops = RecentOperations(capacity: 5, storageURL: historyURL)
            ops.record(OperationRecord(kind: .move, subject: "Projects"))
            try assertTrue(FileManager.default.fileExists(atPath: historyURL.path))

            ops.clear()
            try assertTrue(ops.records.isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: historyURL.path), "历史记录文件被删除")

            try assertEqual(center.current, move, "UndoCenter 内存记录保持完整")
            try assertEqual(UndoMenuState.read(from: dir), UndoMenuState(kind: .move, count: 1, name: "Projects"), "Undo 状态文件保持完整")
        }

        runTest("RecentOperations capacityKey与范围限制") {
            try assertEqual(RecentOperations.capacityKey, "operationHistoryLimit")
            let opsClampMax = RecentOperations(capacity: 999)
            try assertEqual(opsClampMax.capacity, 500, "容量最多500")
            let opsClampMin = RecentOperations(capacity: -10)
            try assertEqual(opsClampMin.capacity, 0, "容量最小为0")
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
            try assertEqual(ids.first, MenuFeatureCatalog.undo, "新增的撤销没有前一项，放最前")
            try assertEqual(ids[1], "feature.toggleHidden", "用户的自定义顺序保持不变")
            let paste = ids.firstIndex(of: "feature.paste")!
            try assertEqual(Array(ids[paste...paste + 2]), ["feature.paste", "feature.moveTo", "feature.copyTo"])
        }

        runTest("常用目录按最近使用排序：用过的倒序在前，没用过的保持手动顺序") {
            let paths = ["/a", "/b", "/c", "/d"]
            let used = ["/c": 100.0, "/a": 200.0, "/gone": 999.0]
            try assertEqual(FavoriteDirectories.ordered(paths, lastUsed: used, byRecent: true), ["/a", "/c", "/b", "/d"])
            try assertEqual(FavoriteDirectories.ordered(paths, lastUsed: used, byRecent: false), paths, "关闭时就是手动顺序")
            try assertEqual(FavoriteDirectories.ordered(paths, lastUsed: [:], byRecent: true), paths, "都没用过时不变")
            try assertEqual(FavoriteDirectories.ordered(paths, lastUsed: ["/b": 1, "/d": 1], byRecent: true),
                            ["/b", "/d", "/a", "/c"], "同一时间按手动顺序")
        }

        runTest("常用目录使用记录：默认按最近使用排序，记录时丢掉已移除的目录") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let config = SharedConfig(fileURL: dir.appendingPathComponent("settings.plist"))
            try assertTrue(config.favoriteSortByRecent, "默认开启")
            config.favoriteDirectories = ["/a", "/b"]
            config.favoriteLastUsed = ["/removed": 1]
            config.markFavoriteUsed("/b", at: Date(timeIntervalSince1970: 50))
            try assertEqual(config.favoriteLastUsed, ["/b": 50])
            try assertEqual(config.orderedFavoriteDirectories, ["/b", "/a"])
            config.favoriteSortByRecent = false
            try assertEqual(config.orderedFavoriteDirectories, ["/a", "/b"])
            try assertEqual(SharedConfig(fileURL: dir.appendingPathComponent("settings.plist")).favoriteLastUsed, ["/b": 50], "写入磁盘")
        }

        runTest("FavoriteDirectories 显示名：重名时附上级路径") {
            let names = FavoriteDirectories.displayNames(
                for: ["/Users/me/Downloads", "/Volumes/E/Downloads", "/Users/me/项目"], home: "/Users/me")
            try assertEqual(names, ["Downloads — ~", "Downloads — /Volumes/E", "项目"])
            try assertEqual(FavoriteDirectories.displayNames(for: ["/"], home: "/Users/me"), ["/"], "根目录显示为 /")
        }

        runTest("常用目录可用性：失效目录置灰，恢复后重新可用") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let missing = dir.appendingPathComponent("missing")
            let file = dir.appendingPathComponent("file")
            let link = dir.appendingPathComponent("link")
            let dangling = dir.appendingPathComponent("dangling")
            try Data().write(to: file)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
            try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
            let paths = [dir.path, missing.path, file.path, link.path, dangling.path]
            let cache = FavoriteDirectoryAvailability()
            func waitFor(_ expected: Set<String>, now: TimeInterval) throws {
                let deadline = Date().addingTimeInterval(2)
                while cache.unavailablePaths(in: paths, now: now) != expected {
                    guard Date() < deadline else { throw TestFailure(message: "目录可用性未按预期更新") }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            try waitFor([missing.path, file.path, dangling.path], now: 0)
            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            try waitFor([], now: 5)
            try FileManager.default.removeItem(at: missing)
            try waitFor([missing.path, dangling.path], now: 10)
        }

        runTest("常用目录可用性：慢目录不阻塞快照或其他目录，权限不明不误禁用") {
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let lock = NSLock()
            var calls: [String: Int] = [:]
            let cache = FavoriteDirectoryAvailability { path in
                lock.lock()
                calls[path, default: 0] += 1
                lock.unlock()
                if path == "slow" {
                    _ = release.wait(timeout: .now() + 3)
                    return true
                }
                return path == "missing" ? false : nil
            }
            let paths = ["slow", "missing", "denied"]
            let deadline = Date().addingTimeInterval(2)
            while true {
                let unavailable = cache.unavailablePaths(in: paths, now: 0)
                lock.lock()
                let started = calls.count == 3
                let slowCalls = calls["slow"]
                lock.unlock()
                if started, unavailable == ["missing"] {
                    try assertEqual(slowCalls, 1, "在途检查不重复派发")
                    break
                }
                guard Date() < deadline else { throw TestFailure(message: "慢目录阻塞了其他目录或快照") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            try assertEqual(cache.unavailablePaths(in: [], now: 1), [], "移除配置后不保留失效标记")
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

        runTest("终端识别：仅接受同一文档声明中的 Shell 角色与脚本或可执行类型") {
            func info(role: String?, types: [String]) -> [String: Any] {
                var document: [String: Any] = ["LSItemContentTypes": types]
                document["CFBundleTypeRole"] = role
                return ["CFBundleDocumentTypes": [document]]
            }
            for type in ["com.apple.terminal.shell-script", "public.shell-script", "public.unix-executable"] {
                try assertTrue(TerminalCatalog.declaresShell(infoDictionary: info(role: "Shell", types: [type])))
                for role in ["Editor", "Viewer", "None", nil] as [String?] {
                    try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: info(role: role, types: [type])))
                }
            }
            try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: info(role: "Shell", types: ["public.folder"])))
            try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: [:]))
            try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: ["CFBundleDocumentTypes": "invalid"]))
            try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: ["CFBundleDocumentTypes": [
                ["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.plain-text"]],
                ["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.unix-executable"]],
            ]]))
        }

        runTest("终端发现：任意品牌的应用须有 Shell 声明与可执行文件，去重并保留名称") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            func app(_ name: String, id: String, role: String = "Shell", executable: Bool = true) throws -> URL {
                let url = dir.appendingPathComponent("\(name).app")
                let contents = url.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                let info: [String: Any] = [
                    "CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL",
                    "CFBundleExecutable": "terminal", "CFBundleInfoDictionaryVersion": "6.0",
                    "CFBundleDocumentTypes": [["CFBundleTypeRole": role, "LSItemContentTypes": ["public.unix-executable"]]],
                ]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                if executable {
                    let binary = contents.appendingPathComponent("MacOS/terminal")
                    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                }
                return url
            }
            let cmux = try app("cmux", id: "com.cmuxterm.app")
            let unknown = try app("New Terminal", id: "org.example.new-terminal")
            let editor = try app("Editor", id: "org.example.editor", role: "Editor")
            let broken = try app("Broken", id: "org.example.broken", executable: false)
            let found = TerminalCatalog.installed(applicationURLs: [cmux, unknown, editor, broken, cmux, dir])
            try assertEqual(found.map(\.bundleIdentifier), ["com.cmuxterm.app", "org.example.new-terminal"])
            try assertEqual(found.first?.name, "cmux")
            try assertEqual(TerminalCatalog.menuTerminals(available: found, selected: ["com.cmuxterm.app"],
                                                        preferred: "com.cmuxterm.app").first?.name, "cmux")
            try assertNil(TerminalCatalog.terminal(at: editor))
            try assertNil(TerminalCatalog.terminal(at: broken))
        }

        runTest("终端菜单：单选、多选、卸载回退与全部关闭") {
            let terminal = "com.apple.Terminal"
            let ghostty = "com.mitchellh.ghostty"
            let available = [terminal, ghostty, "com.example.Terminal"].map {
                KnownTerminal(id: $0, name: $0, bundleIdentifier: $0)
            }
            func ids(_ selected: Set<String>, preferred: String = "com.apple.Terminal") -> [String] {
                TerminalCatalog.menuTerminals(available: available, selected: selected, preferred: preferred)
                    .map(\.bundleIdentifier)
            }
            try assertEqual(ids([ghostty]), [ghostty])
            try assertEqual(ids([ghostty, terminal]), [terminal, ghostty])
            try assertEqual(ids(["removed"], preferred: ghostty), [ghostty])
            try assertEqual(ids(["removed"], preferred: "removed"), [terminal])
            try assertEqual(ids(["com.example.Terminal"]), ["com.example.Terminal"])
            try assertTrue(ids([]).isEmpty, "全部关闭时不显示入口")
            try assertTrue(TerminalCatalog.menuTerminals(available: [], selected: [terminal], preferred: terminal).isEmpty)
        }

        runTest("终端排序：设置与菜单顺序一致，忽略重复和失效项") {
            let terminal = "com.apple.Terminal"
            let ghostty = "com.mitchellh.ghostty"
            let iterm = "com.googlecode.iterm2"
            let order = [ghostty, "removed", ghostty, terminal]
            let available = [terminal, ghostty, iterm].map { KnownTerminal(id: $0, name: $0, bundleIdentifier: $0) }
            try assertEqual(TerminalCatalog.ordered(available, by: order).map(\.bundleIdentifier),
                            [ghostty, terminal, iterm])
            try assertEqual(TerminalCatalog.ordered(available, by: []).map(\.bundleIdentifier),
                            available.map(\.bundleIdentifier))
            let menu = TerminalCatalog.menuTerminals(available: available, selected: [terminal, ghostty],
                                                     preferred: terminal, order: order)
            try assertEqual(menu.map(\.bundleIdentifier), [ghostty, terminal])
        }

        runTest("终端偏好：兼容旧单选、多选与空选择持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.followsSystemTerminal)
            try assertEqual(config.selectedTerminals, [config.preferredTerminal])
            try assertTrue(config.terminalOrder.isEmpty)
            config.preferredTerminal = "com.mitchellh.ghostty"
            try assertTrue(!config.followsSystemTerminal)
            try assertEqual(SharedConfig(fileURL: url).selectedTerminals, ["com.mitchellh.ghostty"])
            config.selectedTerminals = ["com.apple.Terminal", "com.mitchellh.ghostty"]
            config.terminalOrder = ["com.mitchellh.ghostty", "com.apple.Terminal"]
            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.selectedTerminals, config.selectedTerminals)
            try assertEqual(reloaded.terminalOrder, config.terminalOrder)
            try assertEqual(reloaded.preferredTerminal, "com.mitchellh.ghostty")
            reloaded.selectedTerminals = []
            try assertTrue(SharedConfig(fileURL: url).selectedTerminals.isEmpty)
            reloaded.preferredTerminal = ""
            reloaded.resetTerminalMenuToDefault()
            let following = SharedConfig(fileURL: url)
            try assertTrue(following.followsSystemTerminal)
            try assertEqual(following.preferredTerminal, TerminalCatalog.defaultTerminalBundleIdentifier())
            try assertEqual(following.selectedTerminals, [following.preferredTerminal])
            try assertEqual(following.terminalOrder, config.terminalOrder)
        }

        runTest("编辑器识别：要求同一文档中的 Editor 与文本类型，兼容通配符和旧文本类型") {
            func doc(_ role: String?, exts: [String] = [], types: [String] = [], osTypes: [String] = []) -> [String: Any] {
                var d: [String: Any] = ["CFBundleTypeExtensions": exts, "LSItemContentTypes": types, "CFBundleTypeOSTypes": osTypes]
                if let role { d["CFBundleTypeRole"] = role }
                return d
            }
            func check(_ docs: [[String: Any]]) -> Bool {
                EditorCatalog.declaresEditing(infoDictionary: ["CFBundleDocumentTypes": docs])
            }
            try assertTrue(check([doc("Editor", exts: ["PY"])]), "代码扩展名大小写不敏感")
            try assertTrue(check([doc("Editor", types: ["public.swift-source"])]))
            try assertTrue(check([doc("Editor", types: ["public.plain-text"])]), "文本编辑器")
            try assertTrue(check([doc("Editor", types: ["public.source-code"])]))
            try assertTrue(check([doc("Editor", exts: ["*"])]), "JetBrains 通配符")
            try assertTrue(check([doc("Editor", osTypes: ["TEXT"])]), "旧式文本类型")
            for role in ["Viewer", "Shell", "None", nil] as [String?] {
                try assertTrue(!check([doc(role, exts: ["txt", "*"])]), "角色必须明确为 Editor")
            }
            for type in ["public.image", "com.adobe.pdf", "public.folder", "public.data"] {
                try assertTrue(!check([doc("Editor", types: [type])]), "只编辑图片等非文本内容的应用不算")
            }
            try assertTrue(!check([doc("Viewer", types: ["public.text"]), doc("Editor", types: ["public.image"])]),
                           "角色和文本类型不能跨条目拼接")
            try assertTrue(!check([doc("Editor", exts: ["*"], types: ["public.image"])]),
                           "现代 UTI 声明优先于旧扩展名")
            try assertTrue(!check([doc("Editor", types: ["public.text"]), doc("Shell", types: ["public.unix-executable"])]),
                           "终端不混入编辑器")
            try assertTrue(!EditorCatalog.declaresEditing(infoDictionary: [:]))
            try assertTrue(!EditorCatalog.declaresEditing(infoDictionary: ["CFBundleURLTypes": [doc("Editor", exts: ["txt"])]]),
                           "URL 协议的 Editor 角色不代表文件编辑能力")
        }

        runTest("编辑器自动推荐：要求明确的通用编辑声明，专用格式保留手动添加") {
            func document(_ types: [String] = [], extensions: [String] = [], role: String = "Editor") -> [String: Any] {
                ["CFBundleTypeRole": role, "LSItemContentTypes": types, "CFBundleTypeExtensions": extensions]
            }
            func check(_ documents: [[String: Any]]) -> Bool {
                EditorCatalog.declaresGeneralEditing(infoDictionary: ["CFBundleDocumentTypes": documents])
            }
            for type in ["public.text", "public.plain-text", "public.source-code", "public.utf8-plain-text"] {
                try assertTrue(check([document([type])]))
            }
            for ext in ["TXT", "text", "*"] { try assertTrue(check([document(extensions: [ext])])) }
            try assertTrue(check([["CFBundleTypeRole": "Editor", "CFBundleTypeOSTypes": ["TEXT"]]]))
            for type in ["public.comma-separated-values-text", "net.daringfireball.markdown", "public.python-script", "public.json", "public.image"] {
                try assertTrue(!check([document([type])]), "文本子类型不等于通用文本声明")
            }
            for ext in ["md", "sql", "csv", "py", "json"] {
                let info: [String: Any] = ["CFBundleDocumentTypes": [document(extensions: [ext])]]
                // md、sql 的类型可能由已安装应用注册，不能假定干净系统已将它们识别为文本。
                if ["csv", "py", "json"].contains(ext) {
                    try assertTrue(EditorCatalog.declaresEditing(infoDictionary: info), "系统内建文本类型仍可手动添加：\(ext)")
                }
                try assertTrue(!EditorCatalog.declaresGeneralEditing(infoDictionary: info), "专用格式不自动推荐：\(ext)")
            }
            try assertTrue(!check([document(["public.text"], role: "Viewer"), document(["public.image"])]))
            try assertTrue(!check([document(["public.image"], extensions: ["txt", "*"])]), "UTI 声明优先")
        }

        runTest("编辑器发现：通用编辑器自动显示，手动项与系统默认仍须通过基础校验") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            func app(_ name: String, id: String, role: String?, types: [String] = ["public.plain-text"], executable: Bool = true) throws -> URL {
                let url = dir.appendingPathComponent("\(name).app")
                let contents = url.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL",
                                           "CFBundleExecutable": "editor", "CFBundleInfoDictionaryVersion": "6.0"]
                if let role {
                    info["CFBundleDocumentTypes"] = [["CFBundleTypeRole": role, "LSItemContentTypes": types]]
                }
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                if executable {
                    let binary = contents.appendingPathComponent("MacOS/editor")
                    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                }
                return url
            }
            let ide = try app("Antigravity IDE", id: "com.google.antigravity-ide", role: "Editor")
            let agent = try app("Antigravity", id: "com.google.antigravity", role: nil)
            let unknown = try app("New Editor", id: "org.example.new-editor", role: "Editor")
            let viewer = try app("Viewer", id: "org.example.viewer", role: "Viewer")
            let broken = try app("Broken", id: "org.example.broken", role: "Editor", executable: false)
            let oldBrand = try app("Zed without declarations", id: "dev.zed.Zed", role: nil)
            let specific = try app("Python IDE", id: "org.example.python", role: "Editor", types: ["public.python-script"])
            let urls = [ide, agent, unknown, viewer, broken, oldBrand, specific, ide, dir]
            let available = EditorCatalog.installed(applicationURLs: urls)
            try assertEqual(available.map(\.id), ["com.google.antigravity-ide", "org.example.new-editor"])
            try assertEqual(available.first?.name, "Antigravity IDE")
            try assertNil(EditorCatalog.editor(at: agent))
            try assertNil(EditorCatalog.editor(at: broken))
            try assertNil(EditorCatalog.editor(at: oldBrand))
            try assertTrue(EditorCatalog.editor(at: specific) != nil, "专用编辑器可手动添加")
            let explicit = EditorCatalog.installed(applicationURLs: urls, including: ["org.example.python", "com.google.antigravity", "dev.zed.Zed"])
            try assertEqual(Set(explicit.map(\.id)), ["com.google.antigravity-ide", "org.example.new-editor", "org.example.python"],
                           "手动项或系统默认可放宽通用要求，但不能绕过基础编辑能力校验")
        }

        runTest("编辑器菜单：保持保存的排序和显示开关，去掉重复与失效顺序项") {
            let available = [KnownEditor(id: "org.example.alpha", name: "Alpha"), KnownEditor(id: "org.example.beta", name: "Beta")]
            let order = ["org.example.beta", "removed", "org.example.beta", "org.example.alpha"]
            try assertEqual(EditorCatalog.ordered(available, by: order).map(\.id), ["org.example.beta", "org.example.alpha"])
            let menu = EditorCatalog.menuEditors(available: available, hidden: ["org.example.alpha"], order: order)
            try assertEqual(menu.map(\.id), ["org.example.beta"])
            try assertTrue(EditorCatalog.menuEditors(available: available, hidden: Set(available.map(\.id))).isEmpty)
        }

        runTest("编辑器默认：跟随系统且只使用通过校验的应用，不受菜单可见性影响") {
            let valid: Set<String> = ["org.example.Editor", "org.example.SystemEditor", "org.example.NewSystemEditor"]
            func resolve(_ preferred: String?, systemDefault: String = "org.example.SystemEditor") -> String {
                EditorCatalog.resolvedDefault(preferred: preferred, systemDefault: systemDefault, isInstalled: valid.contains)
            }
            try assertEqual(resolve("org.example.Editor"), "org.example.Editor")
            try assertEqual(resolve(nil), "org.example.SystemEditor")
            try assertEqual(resolve(""), "org.example.SystemEditor")
            try assertEqual(resolve("com.google.antigravity"), "org.example.SystemEditor", "旧无效偏好回退")
            try assertEqual(resolve(nil, systemDefault: "org.example.NewSystemEditor"), "org.example.NewSystemEditor")
            try assertEqual(resolve(nil, systemDefault: "org.example.Viewer"), EditorCatalog.textEditBundleId,
                            "系统关联若没有编辑能力则回退到文本编辑")
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

        runTest("EditorDiscovery 图标来源优先常规安装位置副本") {
            let home = "/Users/me"
            let buildProduct = URL(fileURLWithPath: "/Users/me/codes/work/_build/Debug/Inkpot.app")
            let installed = URL(fileURLWithPath: "/Applications/Inkpot.app")
            let toolbox = URL(fileURLWithPath: "/Users/me/Applications/JetBrains Toolbox/PyCharm.app")
            try assertEqual(EditorDiscovery.preferredCopy(among: [buildProduct, installed], fallback: buildProduct, home: home), installed)
            try assertEqual(EditorDiscovery.preferredCopy(among: [buildProduct, toolbox], fallback: buildProduct, home: home), toolbox)
            try assertEqual(EditorDiscovery.preferredCopy(among: [buildProduct], fallback: buildProduct, home: home), buildProduct,
                            "没有常规副本时退回 LaunchServices 解析结果")
            try assertNil(EditorDiscovery.preferredCopy(among: [], fallback: nil, home: home))
        }

        runTest("SharedConfig 编辑器偏好：默认跟随系统、手动项与隐藏项可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertNil(config.preferredEditor)
            try assertTrue(config.customEditors.isEmpty)
            try assertTrue(config.hiddenEditors.isEmpty)
            try assertTrue(config.editorOrder.isEmpty)

            config.preferredEditor = "dev.zed.Zed"
            config.customEditors = [KnownEditor(id: "com.example.Foo", name: "Foo")]
            config.hiddenEditors = ["com.apple.dt.Xcode"]
            config.editorOrder = ["com.example.Foo", "dev.zed.Zed"]
            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.preferredEditor, "dev.zed.Zed")
            try assertEqual(reloaded.customEditors, [KnownEditor(id: "com.example.Foo", name: "Foo")])
            try assertEqual(reloaded.hiddenEditors, ["com.apple.dt.Xcode"])
            try assertEqual(reloaded.editorOrder, config.editorOrder)

            reloaded.preferredEditor = ""
            try assertNil(SharedConfig(fileURL: url).preferredEditor, "空串恢复跟随系统")
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

            let longText = Data(repeating: 0x61, count: 8193)
            try longText.write(to: binaryFile)
            try assertEqual(FileContentReader.readText(from: binaryFile, maxBytes: limit),
                            .success(String(decoding: longText, as: UTF8.self)), "超过 8KB 的正常文本仍可读取")
            try (longText + Data([0])).write(to: binaryFile)
            try assertEqual(FileContentReader.readText(from: binaryFile, maxBytes: limit),
                            .binaryFile, "8KB 之后的空字符也必须拦截")

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

        runTest("ServiceShortcuts 菜单开关覆盖全部服务并保留其他设置") {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let data = try Data(contentsOf: root.appendingPathComponent("FinderRight/Info.plist"))
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let services = (plist?["NSServices"] as? [[String: Any]]) ?? []
            try assertTrue(services.count > ServiceShortcuts.bindings.count, "开关也应覆盖没有快捷键的服务")
            let bid = "com.finderright.app"
            let binding = ServiceShortcuts.bindings.first { $0.actionId == "shortcut.copyPath" }!
            let key = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: binding)
            let shortcuts = ["shortcut.copyPath": ActionShortcut(key: "c", modifiers: cmdBit | ctlBit)]
            let otherKey = "other.app - Other - doIt"
            let existing: [String: Any] = [
                otherKey: ["enabled_context_menu": true],
                key: ["custom": "keep", "presentation_modes": ["CustomMode": true]],
            ]
            let untouched = ServiceShortcuts.mergedStatus(existing, bundleId: bid, shortcuts: shortcuts,
                                                         services: services)
            try assertNil((untouched[key] as? [String: Any])?["enabled_context_menu"], "未操作开关时不改系统显示偏好")
            var status = existing
            for enabled in [false, true] {
                status = ServiceShortcuts.mergedStatus(status, bundleId: bid, shortcuts: shortcuts,
                                                      services: services, showsInServicesMenu: enabled)
                for service in services {
                    let title = (service["NSMenuItem"] as! [String: String])["default"]!
                    let message = service["NSMessage"] as! String
                    let entry = status["\(bid) - \(title) - \(message)"] as? [String: Any]
                    try assertEqual(entry?["enabled_context_menu"] as? Bool, enabled)
                    try assertEqual(entry?["enabled_services_menu"] as? Bool, enabled)
                    let modes = entry?["presentation_modes"] as? [String: Any]
                    try assertEqual(modes?["ContextMenu"] as? Bool, enabled)
                    try assertEqual(modes?["ServicesMenu"] as? Bool, enabled)
                }
                let entry = status[key] as? [String: Any]
                try assertEqual(entry?["key_equivalent"] as? String, "@^c", "显示开关保留快捷键配置")
                try assertEqual(entry?["custom"] as? String, "keep")
                try assertEqual((entry?["presentation_modes"] as? [String: Any])?["CustomMode"] as? Bool, true)
                try assertEqual(status[otherKey] as? [String: Bool], ["enabled_context_menu": true])
            }
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
            let services: [[String: Any]] = [["NSMenuItem": ["default": "FinderRight: Copy Path"], "NSMessage": "copyPath"]]
            try assertTrue(ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, services: services,
                                                showsInServicesMenu: false, domain: domain))
            let status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString, domain as CFString) as? [String: Any]
            let key = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: ServiceShortcuts.bindings.first { $0.actionId == "shortcut.copyPath" }!)
            try assertEqual((status?[key] as? [String: Any])?["enabled_services_menu"] as? Bool, false)
            try assertTrue(!ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, services: services,
                                                 showsInServicesMenu: false, domain: domain), "关闭状态不重复写入")
            try assertTrue(ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, services: services,
                                                showsInServicesMenu: true, domain: domain))
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
            let cmdZ = ActionShortcut(key: "z", modifiers: cmd)
            let all = ["shortcut.cut": cmdX, "shortcut.paste": cmdV, "shortcut.copyPath": optCmdC,
                       "shortcut.toggleHidden": sftCmdDot, "shortcut.undo": cmdZ]
            try assertEqual(T.defaultShortcuts, all, "默认值与访达原生一致")
            try assertNil(T.defaultShortcuts["shortcut.goToDirectory"], "前往目录不占用访达的 ⇧⌘G")
            try assertEqual(T.defaultsToApply(current: [:], alreadyApplied: []), all, "全新安装")
            try assertEqual(T.defaultsToApply(current: [
                "shortcut.cut": ActionShortcut(key: "c", modifiers: ctl),
                "shortcut.paste": ActionShortcut(key: "v", modifiers: ctl),
                "shortcut.copyPath": ActionShortcut(key: "p", modifiers: cmd | ctl),
            ], alreadyApplied: []).keys.sorted(), ["shortcut.toggleHidden", "shortcut.undo"], "用户设置过的行一律保留")
            try assertEqual(T.defaultsToApply(current: ["shortcut.paste": ActionShortcut(key: "v", modifiers: cmd | ctl)],
                                              alreadyApplied: ["shortcut.copyPath", "shortcut.toggleHidden", "shortcut.undo"]),
                            ["shortcut.cut": cmdX], "只补没设置的那一行")
            try assertEqual(T.defaultsToApply(current: ["shortcut.openTerminal": ActionShortcut(key: "V", modifiers: cmd)],
                                              alreadyApplied: ["shortcut.copyPath", "shortcut.toggleHidden", "shortcut.undo"]),
                            ["shortcut.cut": cmdX], "⌘V 已被其他动作占用则不填")
            // 1.6.4 升级：剪切 / 粘贴补过（用户之后清空了剪切），新增的三项默认只补空位
            let legacy = T.legacyAppliedActionIds(cutPasteApplied: true)
            try assertEqual(T.defaultsToApply(current: ["shortcut.paste": cmdV, "shortcut.copyPath": ActionShortcut(key: "p", modifiers: cmd | ctl)],
                                              alreadyApplied: legacy),
                            ["shortcut.toggleHidden": sftCmdDot, "shortcut.undo": cmdZ], "清空的剪切不补回，用户的复制路径不覆盖；升级时补上新增的撤销")
            try assertEqual(T.defaultsToApply(current: ["shortcut.openTerminal": cmdZ], alreadyApplied: Set(all.keys).subtracting(["shortcut.undo"])),
                            [:], "⌘Z 已被用户占用则不补撤销")
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

        // MARK: 撤销上一次操作

        runTest("UndoExecutor 移回原处并拒绝覆盖") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let a = src.appendingPathComponent("a.txt"), b = src.appendingPathComponent("b.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: b)
            let a2 = dst.appendingPathComponent("a.txt"), b2 = dst.appendingPathComponent("b.txt")
            try fm.moveItem(at: a, to: a2)
            try fm.moveItem(at: b, to: b2)
            let record = UndoRecord(kind: .move, name: "dst", items: [
                .init(current: a2, original: a, fingerprint: FileFingerprint.capture(a2)!),
                .init(current: b2, original: b, fingerprint: FileFingerprint.capture(b2)!)],
                cutQueueBefore: nil, finderSnapshot: nil)
            try Data("占位".utf8).write(to: b)   // 原位置被同名文件占用
            let outcome = UndoExecutor.run(record, trash: { _ in throw TestFailure(message: "不应进废纸篓") })
            try assertEqual(outcome.undone, [a])
            try assertEqual(outcome.skipped, [UndoOutcome.Skip(name: "b.txt", reason: .originalOccupied)])
            try assertEqual(outcome.status, .partial)
            try assertEqual(try String(contentsOf: b, encoding: .utf8), "占位", "绝不覆盖")
            try assertTrue(fm.fileExists(atPath: b2.path), "跳过的项保持原样")
        }

        runTest("UndoExecutor 被修改 / 已不存在 / 原文件夹没了 都跳过") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let src = root.appendingPathComponent("src"), gone = root.appendingPathComponent("gone")
            let dst = root.appendingPathComponent("dst")
            for dir in [src, gone, dst] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            let a = src.appendingPathComponent("a.txt"), b = src.appendingPathComponent("b.txt")
            let c = gone.appendingPathComponent("c.txt")
            for (url, text) in [(a, "a"), (b, "b"), (c, "c")] { try Data(text.utf8).write(to: url) }
            var items: [UndoRecord.Item] = []
            for url in [a, b, c] {
                let moved = dst.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: moved)
                items.append(.init(current: moved, original: url, fingerprint: FileFingerprint.capture(moved)!))
            }
            try Data("改过了，长度也变了".utf8).write(to: items[0].current)
            try fm.removeItem(at: items[1].current)
            try fm.removeItem(at: gone)
            let record = UndoRecord(kind: .move, name: "dst", items: items, cutQueueBefore: nil, finderSnapshot: nil)
            let outcome = UndoExecutor.run(record, trash: { _ in })
            try assertEqual(outcome.undone, [])
            try assertEqual(outcome.status, .failure)
            try assertEqual(outcome.skipped.map(\.reason), [.modified, .missing, .originalFolderMissing])
        }

        runTest("UndoExecutor 复制品进废纸篓，文件夹内新增文件视为已修改") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let dst = root.appendingPathComponent("dst"), trashDir = root.appendingPathComponent("trash")
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let file = dst.appendingPathComponent("a.txt"), folder = dst.appendingPathComponent("folder")
            try Data("a".utf8).write(to: file)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // 先把文件夹修改时间拨回过去，确保之后新增文件一定改变它
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: folder.path)
            let record = UndoRecord(kind: .copy, name: "dst", items: [
                .init(current: file, original: nil, fingerprint: FileFingerprint.capture(file)!),
                .init(current: folder, original: nil, fingerprint: FileFingerprint.capture(folder)!)],
                cutQueueBefore: nil, finderSnapshot: nil)
            try Data("new".utf8).write(to: folder.appendingPathComponent("added.txt"))
            var trashed: [URL] = []
            let outcome = UndoExecutor.run(record, trash: { url in
                try fm.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
                trashed.append(url)
            })
            try assertEqual(trashed, [file])
            try assertEqual(outcome.undone, [file])
            try assertEqual(outcome.skipped, [UndoOutcome.Skip(name: "folder", reason: .modified)])
            try assertEqual(outcome.status, .partial)
        }

        runTest("UndoExecutor 符号链接按链接本身移回") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let link = src.appendingPathComponent("link")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/target")
            let moved = dst.appendingPathComponent("link")
            try fm.moveItem(at: link, to: moved)
            guard let fingerprint = FileFingerprint.capture(moved) else {
                throw TestFailure(message: "指向不存在目标的链接也要能取到指纹（不跟随链接）")
            }
            let record = UndoRecord(kind: .move, name: "dst",
                                    items: [.init(current: moved, original: link, fingerprint: fingerprint)],
                                    cutQueueBefore: nil, finderSnapshot: nil)
            let outcome = UndoExecutor.run(record, trash: { _ in })
            try assertEqual(outcome.status, .success)
            try assertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "/nonexistent/target")
        }

        runTest("UndoCenter 快照比较决定 ⌘Z 归属") {
            let center = UndoCenter(stateDirectory: makeTempDirectory())
            let snap = FinderUndoSnapshot(title: "撤销重命名", enabled: true)
            try assertEqual(center.shortcutDecision(finderSnapshot: snap), .passThrough, "无记录放行")
            center.register(UndoRecord(kind: .cut, name: "", items: [], cutQueueBefore: [], finderSnapshot: snap), displayCount: 1)
            try assertEqual(center.shortcutDecision(finderSnapshot: snap), .undo)
            try assertEqual(center.shortcutDecision(finderSnapshot: FinderUndoSnapshot(title: "撤销移动", enabled: true)),
                            .passThrough, "访达之后又有操作")
            try assertEqual(center.shortcutDecision(finderSnapshot: nil), .passThrough, "读不到访达菜单")
            try assertTrue(center.beginUndo() != nil)
            try assertEqual(center.shortcutDecision(finderSnapshot: snap), .ignore, "撤销中吞掉连按")
            try assertNil(center.beginUndo(), "撤销中不能再开始一次")
            center.endUndo()
            try assertEqual(center.shortcutDecision(finderSnapshot: snap), .passThrough, "撤销后记录已清空")
        }

        runTest("UndoCenter 记录快照为 nil 时 ⌘Z 一律放行") {
            let center = UndoCenter(stateDirectory: makeTempDirectory())
            center.register(UndoRecord(kind: .cut, name: "", items: [], cutQueueBefore: [], finderSnapshot: nil), displayCount: 1)
            try assertEqual(center.shortcutDecision(finderSnapshot: FinderUndoSnapshot(title: "撤销", enabled: false)), .passThrough)
            try assertEqual(center.shortcutDecision(finderSnapshot: nil), .passThrough)
            try assertTrue(center.beginUndo() != nil, "菜单入口仍能取到记录")
        }

        runTest("UndoCenter 状态文件随记录写入与清除，且不含路径") {
            let dir = makeTempDirectory()
            let center = UndoCenter(stateDirectory: dir)
            let fp = FileFingerprint(fileNumber: 1, device: 1, isDirectory: false, modificationDate: nil, size: 0)
            let move = UndoRecord(kind: .move, name: "Projects", items: [
                .init(current: URL(fileURLWithPath: "/tmp/Projects/a"), original: URL(fileURLWithPath: "/tmp/a"), fingerprint: fp),
                .init(current: URL(fileURLWithPath: "/tmp/Projects/b"), original: URL(fileURLWithPath: "/tmp/b"), fingerprint: fp)],
                cutQueueBefore: nil, finderSnapshot: nil)
            center.register(move)
            try assertEqual(UndoMenuState.read(from: dir), UndoMenuState(kind: .move, count: 2, name: "Projects"))
            let raw = try String(contentsOf: dir.appendingPathComponent(UndoMenuState.fileName), encoding: .utf8)
            try assertTrue(!raw.contains("/tmp"), "状态文件不能写路径")
            _ = center.beginUndo()
            try assertNil(UndoMenuState.read(from: dir), "开始撤销即清除状态")
            center.register(move)
            center.endUndo()
            try assertEqual(center.current, move, "撤销期间登记的新记录在 endUndo 后保留")
            center.invalidate(kind: .copy)
            try assertEqual(center.current, move, "类型不符不作废")
            center.invalidate(kind: .move)
            try assertNil(center.current)
            try assertNil(UndoMenuState.read(from: dir))
            center.register(move)
            center.clear()
            try assertNil(center.current)
            try assertNil(UndoMenuState.read(from: dir))
        }

        runTest("UndoRecord 移进废纸篓 / 改名 / 换成别的文件的项被剔除，只改了内容的保留") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let dst = root.appendingPathComponent("dst"), trashDir = root.appendingPathComponent("trash")
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let names = ["trashed.txt", "renamed.txt", "replaced.txt", "edited.txt"]
            var items: [UndoRecord.Item] = []
            for name in names {
                let url = dst.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
                items.append(.init(current: url, original: nil, fingerprint: FileFingerprint.capture(url)!))
            }
            let record = UndoRecord(kind: .copy, name: "dst", items: items, cutQueueBefore: nil,
                                    finderSnapshot: FinderUndoSnapshot(title: "撤销拷贝", enabled: true))
            try assertEqual(record.pruningRemovedItems(cutQueue: []), record, "都还在时原样返回")

            try fm.moveItem(at: items[0].current, to: trashDir.appendingPathComponent("trashed.txt"))
            try fm.moveItem(at: items[1].current, to: dst.appendingPathComponent("renamed 2.txt"))
            try fm.removeItem(at: items[2].current)
            try Data("新文件".utf8).write(to: items[2].current)
            try Data("改过了".utf8).write(to: items[3].current)
            guard let pruned = record.pruningRemovedItems(cutQueue: []) else {
                throw TestFailure(message: "还有项在原处，不应作废")
            }
            try assertEqual(pruned.items.map(\.current), [items[3].current], "只留下原处仍是同一个项目的")
            try assertEqual(pruned.count, 1, "菜单显示的项数随之减少")
            try assertEqual(pruned.finderSnapshot, record.finderSnapshot, "⌘Z 归属比对不受影响")

            try fm.moveItem(at: items[3].current, to: trashDir.appendingPathComponent("edited.txt"))
            try assertNil(record.pruningRemovedItems(cutQueue: []), "全部移走后作废")
        }

        runTest("UndoRecord 剪切新增的项都已离开剪切队列时作废") {
            let record = UndoRecord(kind: .cut, name: "", items: [], cutQueueBefore: ["/a", "/b"],
                                    finderSnapshot: nil, displayCount: 2)
            try assertEqual(record.pruningRemovedItems(cutQueue: ["/a", "/b", "/c", "/d"]), record, "都还在时不变")
            let pruned = record.pruningRemovedItems(cutQueue: ["/a", "/d"])
            try assertEqual(pruned?.count, 1, "新增项只剩一个")
            try assertEqual(pruned?.cutQueueBefore, ["/a"], "已移走的旧项撤销时不再写回队列")
            try assertNil(record.pruningRemovedItems(cutQueue: ["/a", "/b"]), "新增项全被移走")
            try assertNil(record.pruningRemovedItems(cutQueue: []))
        }

        runTest("UndoCenter 按修订结果更新或清除状态文件") {
            let dir = makeTempDirectory()
            let center = UndoCenter(stateDirectory: dir)
            try assertTrue(!center.revalidate { _ in nil }, "没有记录时无事可做")
            let fp = FileFingerprint(fileNumber: 1, device: 1, isDirectory: false, modificationDate: nil, size: 0)
            let a = UndoRecord.Item(current: URL(fileURLWithPath: "/tmp/dst/a"), original: nil, fingerprint: fp)
            let b = UndoRecord.Item(current: URL(fileURLWithPath: "/tmp/dst/b"), original: nil, fingerprint: fp)
            let copy = UndoRecord(kind: .copy, name: "dst", items: [a, b], cutQueueBefore: nil, finderSnapshot: nil)
            center.register(copy)
            try assertTrue(!center.revalidate { $0 }, "没变化时不重写")
            let one = UndoRecord(kind: .copy, name: "dst", items: [a], cutQueueBefore: nil, finderSnapshot: nil)
            try assertTrue(center.revalidate { _ in one })
            try assertEqual(center.current, one)
            try assertEqual(UndoMenuState.read(from: dir), UndoMenuState(kind: .copy, count: 1, name: "dst"))
            try assertTrue(center.revalidate { _ in nil })
            try assertNil(center.current)
            try assertNil(UndoMenuState.read(from: dir), "作废后扩展不再显示撤销项")
        }

        runTest("UndoText 菜单标题与提示文案") {
            let id: (String) -> String = { $0 }
            try assertEqual(UndoText.menuTitle(for: UndoMenuState(kind: .move, count: 3, name: "Projects"), localize: id),
                            "撤销移动到“Projects”（3 项）")
            try assertEqual(UndoText.menuTitle(for: UndoMenuState(kind: .cut, count: 2, name: ""), localize: id), "撤销剪切（2 项）")
            let fp = FileFingerprint(fileNumber: 1, device: 1, isDirectory: false, modificationDate: nil, size: 0)
            let item = UndoRecord.Item(current: URL(fileURLWithPath: "/x/a.txt"), original: nil, fingerprint: fp)
            let record = UndoRecord(kind: .move, name: "Projects", items: [item, item, item], cutQueueBefore: nil, finderSnapshot: nil)
            let two = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
            try assertEqual(UndoText.feedback(for: record, outcome: UndoOutcome(undone: two + [URL(fileURLWithPath: "/c")]), localize: id),
                            "已撤销：移动到“Projects”（3 项）")
            try assertEqual(UndoText.feedback(for: record, outcome: UndoOutcome(undone: two, skipped: [
                .init(name: "b.txt", reason: .modified), .init(name: "c.txt", reason: .missing)]), localize: id),
                            "已撤销 2 项，跳过 2 项：“b.txt”在操作后被修改等 1 项")
            try assertEqual(UndoText.feedback(for: record, outcome: UndoOutcome(skipped: [
                .init(name: "a.txt", reason: .originalOccupied)]), localize: id),
                            "无法撤销：“a.txt”原位置已有同名项目")
        }

        runTest("FinderKeyTakeover 撤销键按决策吞键或放行") {
            typealias T = FinderKeyTakeover
            try assertEqual(T.defaultShortcuts[T.undoActionId], ActionShortcut(key: "z", modifiers: 1 << 20), "默认 ⌘Z")
            try assertTrue(T.handlesAction(T.undoActionId))
            try assertEqual(T.decide(.undo, focusIsText: false, pasteboardIsCutMirror: false, undo: .undo), .undo)
            try assertEqual(T.decide(.undo, focusIsText: false, pasteboardIsCutMirror: false, undo: .ignore), .swallow)
            try assertEqual(T.decide(.undo, focusIsText: false, pasteboardIsCutMirror: false, undo: .passThrough), .passThrough)
            try assertEqual(T.decide(.undo, focusIsText: true, pasteboardIsCutMirror: false, undo: .undo), .passThrough, "重命名时放行")
            // ANSI 布局 Z=6；与现有按键测试一致，修饰键直接用 CGEventFlags 位（⌘ = 1 << 20）
            let chord = T.KeyChord(keyCode: 6, modifiers: 1 << 20)
            try assertEqual(T.command(keyCode: 6, modifierFlags: 1 << 20, chords: [T.undoActionId: chord], copy: nil), .undo)
        }

        runTest("MenuFeatureCatalog 撤销排第一且默认开启") {
            try assertEqual(MenuFeatureCatalog.all.first?.id, MenuFeatureCatalog.undo)
            try assertTrue(!MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.undo))
            try assertEqual(MenuFeatureCatalog.ordered(by: [MenuFeatureCatalog.newFile]).first?.id, MenuFeatureCatalog.undo,
                            "老用户保存的顺序里没有它时也放最前")
        }

        runTest("NewFileTemplateCatalog 内置项与默认顺序") {
            let items = NewFileTemplateCatalog.builtInItems
            try assertEqual(items.count, 13)
            try assertEqual(items.map(\.id), NewFileTemplateCatalog.defaultOrder)
            try assertTrue(items.contains(where: { $0.id == "txt" && !$0.isOffice && !$0.isCustom }))
            try assertTrue(items.contains(where: { $0.id == "docx" && $0.isOffice && !$0.isCustom }))
        }

        runTest("NewFileTemplateCatalog.resolvedTemplates 排序与合并") {
            let custom1 = FileTemplate(id: "c1", name: "Custom 1", fileExtension: "conf", content: "port=8080")
            let custom2 = FileTemplate(id: "c2", name: "Custom 2", fileExtension: "log", content: "")

            // 1. 空 order：返回默认内置 + 自定义项
            let defaultResolved = NewFileTemplateCatalog.resolvedTemplates(order: [], customTemplates: [custom1, custom2])
            try assertEqual(defaultResolved.count, 15)
            try assertEqual(defaultResolved.prefix(13).map(\.id), NewFileTemplateCatalog.defaultOrder)
            try assertEqual(defaultResolved.suffix(2).map(\.id), ["c1", "c2"])

            // 2. 自定义 order：按指定顺序排列，未提及的自动追加
            let customOrder = ["c1", "docx", "md"]
            let resolved = NewFileTemplateCatalog.resolvedTemplates(order: customOrder, customTemplates: [custom1, custom2])
            try assertEqual(resolved.count, 15)
            try assertEqual(Array(resolved.prefix(3).map(\.id)), ["c1", "docx", "md"])
            // 其余未列出的项应追加在后
            try assertTrue(resolved.contains(where: { $0.id == "c2" }))
            try assertTrue(resolved.contains(where: { $0.id == "txt" }))
        }

        runTest("SharedConfig 新建文件模板顺序、隐藏与编辑持久化") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let configURL = tempDir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: configURL)

            try assertEqual(config.newFileOrder, [])
            try assertEqual(config.hiddenNewFileTemplates, Set())
            try assertTrue(config.isNewFileTemplateEnabled("txt"))

            config.newFileOrder = ["docx", "txt"]
            config.setNewFileTemplateEnabled("md", enabled: false)
            try assertTrue(!config.isNewFileTemplateEnabled("md"))
            try assertEqual(config.newFileOrder, ["docx", "txt"])
            try assertEqual(config.hiddenNewFileTemplates, ["md"])

            // 测试添加与更新自定义模板
            let tmpl = FileTemplate(id: "custom_tpl", name: "Old", fileExtension: "txt", content: "old")
            config.addFileTemplate(tmpl)
            try assertEqual(config.customFileTemplates.first?.name, "Old")

            let updatedTmpl = FileTemplate(id: "custom_tpl", name: "New", fileExtension: "txt", content: "new")
            config.updateFileTemplate(updatedTmpl)
            try assertEqual(config.customFileTemplates.first?.name, "New")
            try assertEqual(config.customFileTemplates.first?.content, "new")

            // 加入 order 和 hidden 后删除，测试自动清理
            config.newFileOrder = ["custom_tpl", "txt"]
            config.setNewFileTemplateEnabled("custom_tpl", enabled: false)
            config.removeFileTemplate(withId: "custom_tpl")
            try assertTrue(config.customFileTemplates.isEmpty)
            try assertEqual(config.newFileOrder, ["txt"])
            try assertTrue(!config.hiddenNewFileTemplates.contains("custom_tpl"))
        }

        runTest("SharedConfig 内置类型移除后不再显示，恢复后重新启用") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let configURL = tempDir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: configURL)

            config.removeBuiltInNewFileTemplate("csv")
            config.removeBuiltInNewFileTemplate("custom_tpl")
            try assertEqual(config.removedNewFileTemplates, ["csv"], "只接受内置类型")
            try assertTrue(!config.isNewFileTemplateEnabled("csv"), "移除即从菜单隐藏，菜单与服务只看隐藏集合")
            try assertEqual(SharedConfig(fileURL: configURL).removedNewFileTemplates, ["csv"], "写入磁盘")

            config.restoreBuiltInNewFileTemplate("csv")
            try assertEqual(config.removedNewFileTemplates, Set())
            try assertTrue(config.isNewFileTemplateEnabled("csv"), "恢复后为启用状态")
        }

        runTest("复制文件名：SharedConfig 默认值、持久化与未知值回退") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let configURL = tempDir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: configURL)

            // 1. 默认值
            try assertEqual(config.copyFileNameFormat, .full, "默认含扩展名")

            // 2. 持久化
            config.copyFileNameFormat = .withoutExtension
            try assertEqual(config.copyFileNameFormat, .withoutExtension)
            let reloaded = SharedConfig(fileURL: configURL)
            try assertEqual(reloaded.copyFileNameFormat, .withoutExtension, "磁盘重新加载保持 withoutExtension")

            // 3. 未知值回退到 full
            guard let data = try? Data(contentsOf: configURL),
                  var dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                throw TestFailure(message: "无法读取 plist")
            }
            dict["copyFileNameFormat"] = "unknown_invalid_format"
            let mutatedData = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try mutatedData.write(to: configURL)

            let fallbackConfig = SharedConfig(fileURL: configURL)
            try assertEqual(fallbackConfig.copyFileNameFormat, .full, "未知值应安全回退到 .full")
        }

        runTest("复制文件名：中文、多点文件名、普通文件与无扩展名") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fm = FileManager.default

            // 1. 中文多点普通文件
            let file1 = tempDir.appendingPathComponent("项目 汇报.2026.docx")
            fm.createFile(atPath: file1.path, contents: Data("test".utf8))
            try assertEqual(PathFormatter.fileName(for: file1, format: .full), "项目 汇报.2026.docx")
            try assertEqual(PathFormatter.fileName(for: file1, format: .withoutExtension), "项目 汇报.2026")

            // 2. 多点文件名 (report.tar.gz)
            let file2 = tempDir.appendingPathComponent("report.tar.gz")
            fm.createFile(atPath: file2.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: file2, format: .full), "report.tar.gz")
            try assertEqual(PathFormatter.fileName(for: file2, format: .withoutExtension), "report.tar")

            // 3. 普通单扩展名文件
            let file3 = tempDir.appendingPathComponent("notes.txt")
            fm.createFile(atPath: file3.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: file3, format: .full), "notes.txt")
            try assertEqual(PathFormatter.fileName(for: file3, format: .withoutExtension), "notes")

            // 4. 无扩展名文件
            let file4 = tempDir.appendingPathComponent("LICENSE")
            fm.createFile(atPath: file4.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: file4, format: .full), "LICENSE")
            try assertEqual(PathFormatter.fileName(for: file4, format: .withoutExtension), "LICENSE")

            let trailingDot = tempDir.appendingPathComponent("report.")
            try Data().write(to: trailingDot)
            try assertEqual(PathFormatter.fileName(for: trailingDot, format: .withoutExtension), "report.", "末尾单独的点不是扩展名")
        }

        runTest("复制文件名：点文件、带点目录、app 包与类型未知") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fm = FileManager.default

            // 1. 点文件 .gitignore (保留原名)
            let dot1 = tempDir.appendingPathComponent(".gitignore")
            fm.createFile(atPath: dot1.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: dot1, format: .full), ".gitignore")
            try assertEqual(PathFormatter.fileName(for: dot1, format: .withoutExtension), ".gitignore")

            // 2. 多点点文件 .env.local (去掉最后一段扩展名)
            let dot2 = tempDir.appendingPathComponent(".env.local")
            fm.createFile(atPath: dot2.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: dot2, format: .full), ".env.local")
            try assertEqual(PathFormatter.fileName(for: dot2, format: .withoutExtension), ".env")

            // 3. 带点目录 (保留全名)
            let dirWithDot = tempDir.appendingPathComponent("project.v2.dir")
            try fm.createDirectory(at: dirWithDot, withIntermediateDirectories: true)
            try assertEqual(PathFormatter.fileName(for: dirWithDot, format: .full), "project.v2.dir")
            try assertEqual(PathFormatter.fileName(for: dirWithDot, format: .withoutExtension), "project.v2.dir")

            // 4. app 包目录 (保留全名)
            let appBundle = tempDir.appendingPathComponent("DemoTool.app")
            try fm.createDirectory(at: appBundle, withIntermediateDirectories: true)
            try assertEqual(PathFormatter.fileName(for: appBundle, format: .full), "DemoTool.app")
            try assertEqual(PathFormatter.fileName(for: appBundle, format: .withoutExtension), "DemoTool.app")

            // 5. 类型未知 (不存在的路径，保留全名避免误截目录)
            let ghostFile = tempDir.appendingPathComponent("non_existent.dir.or.file.txt")
            try assertEqual(PathFormatter.fileName(for: ghostFile, format: .full), "non_existent.dir.or.file.txt")
            try assertEqual(PathFormatter.fileName(for: ghostFile, format: .withoutExtension), "non_existent.dir.or.file.txt")
        }

        runTest("复制文件名：多选格式化每行一项") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fm = FileManager.default
            let f1 = tempDir.appendingPathComponent("文档.pdf")
            let f2 = tempDir.appendingPathComponent("data.tar.gz")
            let d3 = tempDir.appendingPathComponent("folder.bundle")
            fm.createFile(atPath: f1.path, contents: Data())
            fm.createFile(atPath: f2.path, contents: Data())
            try fm.createDirectory(at: d3, withIntermediateDirectories: true)

            let urls = [f1, f2, d3]

            let full = PathFormatter.fileNames(for: urls, format: .full)
            try assertEqual(full, "文档.pdf\ndata.tar.gz\nfolder.bundle")

            let withoutExt = PathFormatter.fileNames(for: urls, format: .withoutExtension)
            try assertEqual(withoutExt, "文档\ndata.tar\nfolder.bundle")
        }

        runTest("反馈链接：模板与字段预填、特殊字符编码") {
            let url = IssueLink.url(template: .bug, fields: [
                (id: "version", value: "1.11.0 (build 42)"),
                (id: "permissions", value: "辅助功能：已授权\na&b=c+d"),
                (id: "logs", value: "  \n"),
            ])
            try assertEqual(url.host, "github.com")
            try assertEqual(url.path, "/funny-dog/FinderRight/issues/new")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            try assertEqual(dict["template"], "bug_report.yml")
            try assertEqual(dict["version"], "1.11.0 (build 42)")
            // & = + 换行都必须被编码，否则会截断或拆出多余参数
            try assertEqual(dict["permissions"], "辅助功能：已授权\na&b=c+d")
            try assertTrue(!url.absoluteString.contains("+"), "加号未编码会被 GitHub 解析成空格")
            try assertEqual(dict["logs"], nil, "空字段应省略")
            try assertEqual(items.count, 3)
        }

        runTest("反馈链接：功能建议模板与超长字段截断") {
            let feature = IssueLink.url(template: .feature)
            try assertEqual(feature.query, "template=01-feature_request.yml")

            let long = String(repeating: "长", count: IssueLink.fieldLimit + 100)
            let url = IssueLink.url(template: .bug, fields: [(id: "logs", value: long)])
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "logs" }?.value ?? ""
            try assertEqual(value.count, IssueLink.fieldLimit + 1)
            try assertTrue(value.hasSuffix("…"))
        }

        runTest("图标缩略图：只保留目标 2x 位图、透明背景与模板标记，不修改原图") {
            let source = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
                NSColor.red.setFill()
                rect.insetBy(dx: 64, dy: 64).fill()
                return true
            }
            source.isTemplate = true
            for size in [16, 28] {
                guard let image = IconThumbnail.make(from: source, pointSize: size),
                      let bitmap = image.representations.first as? NSBitmapImageRep else {
                    throw TestFailure(message: "未生成图标位图")
                }
                try assertEqual(image.size, NSSize(width: size, height: size))
                try assertEqual(image.representations.count, 1)
                try assertEqual(bitmap.pixelsWide, size * 2)
                try assertEqual(bitmap.pixelsHigh, size * 2)
                try assertTrue(image.isTemplate)
                try assertTrue((bitmap.colorAt(x: size, y: size)?.alphaComponent ?? 0) > 0.9)
                let center = bitmap.colorAt(x: size, y: size)!.usingColorSpace(.sRGB)!
                try assertTrue(center.redComponent > 0.9 && center.greenComponent < 0.1)
                try assertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
                let data = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
                let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: data)
                try assertEqual(restored?.representations.count, 1)
                try assertTrue(restored?.isTemplate == true)
                try assertEqual(restored?.representations.first?.pixelsWide, size * 2)
            }
            try assertEqual(source.size, NSSize(width: 256, height: 256))
            source.isTemplate = false
            try assertTrue(IconThumbnail.make(from: source, pointSize: 16)?.isTemplate == false)
            try assertNil(IconThumbnail.make(from: source, pointSize: 0))
        }

        // MARK: - 复制哈希 / 创建符号链接

        runTest("复制哈希：三种算法与已知摘要一致，跨块读取结果不变") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("abc.txt")
            try Data("abc".utf8).write(to: file)
            try assertEqual(FileHasher.hexDigest(of: file, algorithm: .sha256),
                            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            try assertEqual(FileHasher.hexDigest(of: file, algorithm: .sha1), "a9993e364706816aba3e25717850c26c9cd0d89d")
            try assertEqual(FileHasher.hexDigest(of: file, algorithm: .md5), "900150983cd24fb0d6963f7d28e17f72")

            let empty = dir.appendingPathComponent("empty")
            try Data().write(to: empty)
            try assertEqual(FileHasher.hexDigest(of: empty, algorithm: .md5), "d41d8cd98f00b204e9800998ecf8427e", "空文件")

            // 超过一块（1 MiB）的文件：与一次性计算的结果一致
            let big = dir.appendingPathComponent("big.bin")
            let bytes = Data((0..<(3 << 20) + 7).map { UInt8($0 % 251) })
            try bytes.write(to: big)
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try assertEqual(FileHasher.hexDigest(of: big, algorithm: .sha256), expected)
            try assertEqual(try FileHasher.hexDigest(reading: big, algorithm: .sha256), expected)
        }

        runTest("复制哈希：文件夹与不存在的文件不计算，取消即中止，符号链接按目标") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try assertNil(FileHasher.hexDigest(of: dir, algorithm: .sha256), "文件夹")
            try assertNil(FileHasher.hexDigest(of: dir.appendingPathComponent("missing"), algorithm: .sha256))
            do {
                _ = try FileHasher.hexDigest(reading: dir.appendingPathComponent("missing"), algorithm: .sha256)
                throw TestFailure(message: "读取失败应抛出具体文件错误")
            } catch is TestFailure { throw TestFailure(message: "读取失败未抛错") }
            catch { try assertEqual((error as NSError).domain, NSCocoaErrorDomain) }
            let file = dir.appendingPathComponent("a")
            try Data("abc".utf8).write(to: file)
            try assertNil(FileHasher.hexDigest(of: file, algorithm: .sha256, isCancelled: { true }))
            let link = dir.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            try assertTrue(FileHasher.isRegularFile(link))
            try assertEqual(FileHasher.hexDigest(of: link, algorithm: .md5), "900150983cd24fb0d6963f7d28e17f72")
            try assertTrue(!FileHasher.isRegularFile(dir))
        }

        runTest("复制哈希：单个文件只给摘要，多个文件与 shasum 输出一致") {
            try assertEqual(FileHasher.clipboardText([("a.txt", "aa")]), "aa")
            try assertEqual(FileHasher.clipboardText([("a.txt", "aa"), ("b c.txt", "bb")]), "aa  a.txt\nbb  b c.txt")
        }

        runTest("复制哈希与创建符号链接默认关闭，排在复制文件内容 / 复制到之后") {
            try assertTrue(MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.createSymlink))
            let ids = MenuFeatureCatalog.all.map(\.id)
            try assertEqual(ids[ids.firstIndex(of: MenuFeatureCatalog.copyFileContent)! + 1], MenuFeatureCatalog.copyFileHash)
            try assertEqual(ids[ids.firstIndex(of: MenuFeatureCatalog.copyTo)! + 1], MenuFeatureCatalog.createSymlink)
        }

        runTest("符号链接命名：保留完整文件名，重名自动编号") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("报告.pdf")
            try Data().write(to: source)
            let first = SymlinkNaming.linkURL(for: source, suffix: "链接")
            try assertEqual(first.lastPathComponent, "报告.pdf 链接")
            try FileManager.default.createSymbolicLink(at: first, withDestinationURL: dir.appendingPathComponent("missing"))
            try assertEqual(SymlinkNaming.linkURL(for: source, suffix: "链接").lastPathComponent, "报告.pdf 链接 1",
                            "悬空的同名链接也算占用")
            let folder = dir.appendingPathComponent("src/")
            try assertEqual(SymlinkNaming.linkURL(for: folder, suffix: "link").lastPathComponent, "src link")
        }

        runTest("菜单单一数据源：空白处（container）右键菜单分支") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let templates = [MenuTemplateData(id: "txt", displayName: "纯文本", systemImage: "doc.text", tint: .blue, tag: 0)]
            let terminals = [MenuTerminalData(bundleIdentifier: "com.apple.Terminal", name: "终端", icon: nil, tag: 0)]
            let input = MenuBuildInput(
                location: .container,
                selection: .empty,
                enabledFeatureIds: allFeatures,
                newFileTemplates: templates,
                terminals: terminals
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            let ids = nodes.map(\.id)

            // 空白处应该有新建文件、打开路径、终端、粘贴（disabled）、切换隐藏文件
            try assertTrue(ids.contains(MenuFeatureCatalog.newFile))
            try assertTrue(ids.contains(MenuFeatureCatalog.goToDirectory))
            try assertTrue(ids.contains(MenuFeatureCatalog.openTerminal))
            try assertTrue(ids.contains(MenuFeatureCatalog.paste))
            try assertTrue(ids.contains(MenuFeatureCatalog.toggleHidden))

            // 粘贴项无剪切时应置灰
            let pasteNode = nodes.first { $0.id == MenuFeatureCatalog.paste }!
            try assertTrue(!pasteNode.isEnabled)

            // 不应有依赖选中项的操作
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyPath))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileName))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(!ids.contains(MenuFeatureCatalog.cut))
            try assertTrue(!ids.contains(MenuFeatureCatalog.moveTo))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyTo))
            try assertTrue(!ids.contains(MenuFeatureCatalog.createSymlink))
            try assertTrue(!ids.contains(MenuFeatureCatalog.compress))
            try assertTrue(!ids.contains(MenuFeatureCatalog.decompress))
        }

        runTest("菜单单一数据源：单选普通文本文件分支") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let editors = [MenuEditorData(bundleIdentifier: "com.microsoft.VSCode", name: "VS Code", icon: nil, tag: 0)]
            let input = MenuBuildInput(
                location: .items,
                selection: .singleFile(isTextEligible: true, isArchive: false),
                enabledFeatureIds: allFeatures,
                editors: editors
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            let ids = nodes.map(\.id)

            // 单选文本文件包含复制内容与哈希，包含打开编辑器，不包含解压与新建文件
            try assertTrue(ids.contains(MenuFeatureCatalog.copyPath))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyFileName))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(ids.contains(MenuFeatureCatalog.openEditor))
            try assertTrue(ids.contains(MenuFeatureCatalog.cut))
            try assertTrue(ids.contains(MenuFeatureCatalog.moveTo))
            try assertTrue(ids.contains(MenuFeatureCatalog.createSymlink))
            try assertTrue(ids.contains(MenuFeatureCatalog.compress))
            try assertTrue(!ids.contains(MenuFeatureCatalog.decompress))
            try assertTrue(!ids.contains(MenuFeatureCatalog.newFile))
        }

        runTest("菜单单一数据源：单选非文本普通文件与文件夹差异") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            // 非文本普通文件：无 copyFileContent，有 copyFileHash
            let fileInput = MenuBuildInput(
                location: .items,
                selection: .singleFile(isTextEligible: false, isArchive: false),
                enabledFeatureIds: allFeatures
            )
            let fileNodes = MenuTreeBuilder.buildMenuTree(input: fileInput)
            try assertTrue(!fileNodes.map(\.id).contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(fileNodes.map(\.id).contains(MenuFeatureCatalog.copyFileHash))

            // 文件夹：无 copyFileContent，无 copyFileHash，无 decompress，有 cut/moveTo/compress
            let folderInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures
            )
            let folderNodes = MenuTreeBuilder.buildMenuTree(input: folderInput)
            let folderIds = folderNodes.map(\.id)
            try assertTrue(!folderIds.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(!folderIds.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(!folderIds.contains(MenuFeatureCatalog.decompress))
            try assertTrue(folderIds.contains(MenuFeatureCatalog.cut))
            try assertTrue(folderIds.contains(MenuFeatureCatalog.compress))
            try assertTrue(folderIds.contains(MenuFeatureCatalog.moveTo))
        }

        runTest("菜单单一数据源：多选且包含压缩包分支") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let input = MenuBuildInput(
                location: .items,
                selection: .multiple(count: 3, hasRegularFiles: true, hasArchives: true),
                enabledFeatureIds: allFeatures
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            let ids = nodes.map(\.id)

            // 多选：有哈希与解压，无复制内容
            try assertTrue(ids.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(ids.contains(MenuFeatureCatalog.decompress))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(ids.contains(MenuFeatureCatalog.compress))
        }

        runTest("菜单单一数据源：剪切队列与取消剪切联动及文案格式化") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let input = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures,
                cutState: CutState(count: 3, isSelectionSubsetOfCut: true)
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)

            // 剪切项标题应为已在队列提示
            let cutNode = nodes.first { $0.id == MenuFeatureCatalog.cut }!
            try assertEqual(cutNode.titleKey, "剪切 (已在剪切队列)")

            // 应跟随取消剪切项
            try assertTrue(nodes.contains(where: { $0.id == "action.cancelCut" }))

            // 粘贴项格式化文案与高亮启用
            let pasteNode = nodes.first { $0.id == MenuFeatureCatalog.paste }!
            try assertTrue(pasteNode.isEnabled)
            try assertEqual(pasteNode.title, .formatted(key: "粘贴 (已剪切 %d 项)", count: 3))
        }

        runTest("菜单单一数据源：关闭剪切开关时取消剪切兜底插入粘贴之后") {
            var features = Set(MenuFeatureCatalog.all.map(\.id))
            features.remove(MenuFeatureCatalog.cut) // 关闭剪切
            let input = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: features,
                cutState: CutState(count: 2, isSelectionSubsetOfCut: false)
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            let ids = nodes.map(\.id)

            try assertTrue(!ids.contains(MenuFeatureCatalog.cut))
            let pasteIdx = ids.firstIndex(of: MenuFeatureCatalog.paste)!
            let cancelCutIdx = ids.firstIndex(of: "action.cancelCut")!
            try assertEqual(cancelCutIdx, pasteIdx + 1, "取消剪切应紧随粘贴之后插入")
        }

        runTest("菜单单一数据源：常用目录子菜单与状态展示") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            // 场景 1：无常用目录
            let emptyInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures,
                favoriteDirectories: []
            )
            let emptyNodes = MenuTreeBuilder.buildMenuTree(input: emptyInput)
            let moveToNode1 = emptyNodes.first { $0.id == MenuFeatureCatalog.moveTo }!
            guard case .submenu(let children1) = moveToNode1.kind else {
                throw TestFailure(message: "moveTo 必须是 submenu")
            }
            try assertEqual(children1[0].titleKey, "尚未添加常用目录")
            try assertTrue(!children1[0].isEnabled)

            // 场景 2：有常用目录且包含不可用目录
            let favs = [
                MenuFavoriteData(path: "/Users/test/Downloads", displayName: "下载", isUnavailable: false, canTransfer: true, tag: 0),
                MenuFavoriteData(path: "/Volumes/Lost", displayName: "外部盘", isUnavailable: true, canTransfer: false, tag: 1)
            ]
            let favInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures,
                favoriteDirectories: favs
            )
            let favNodes = MenuTreeBuilder.buildMenuTree(input: favInput)
            let moveToNode2 = favNodes.first { $0.id == MenuFeatureCatalog.moveTo }!
            guard case .submenu(let children2) = moveToNode2.kind else {
                throw TestFailure(message: "moveTo 必须是 submenu")
            }
            try assertEqual(children2[0].title, .dynamic("下载"))
            try assertTrue(children2[0].isEnabled)
            try assertEqual(children2[1].title, .unavailableDirectory("外部盘"))
            try assertTrue(!children2[1].isEnabled)
        }

        runTest("菜单单一数据源：整棵目录菜单区分同目录复制与移动") {
            let favorite = MenuFavoriteData(path: "/tmp", displayName: "临时目录", isUnavailable: false, canTransfer: false, tag: 0, canCopy: true)
            let input = MenuBuildInput(location: .items, selection: .singleFolder,
                                       enabledFeatureIds: [MenuFeatureCatalog.copyTo], favoriteDirectories: [favorite])
            let expected: [MenuDataNode] = [.submenu(id: MenuFeatureCatalog.copyTo, titleKey: "复制到", systemImage: "plus.square.on.square", tint: .green, children: [
                .dynamicAction(id: "feature.copyTo.0", title: "临时目录", systemImage: "folder", tint: .cyan, actionId: "copyToFavorite", isEnabled: true, toolTip: "/tmp"),
                .separator(id: "feature.copyTo.separator"),
                .action(id: "feature.copyTo.manage", titleKey: "管理常用目录…", systemImage: "gearshape", tint: .gray, actionId: "manageFavorites")
            ])]
            try assertEqual(MenuTreeBuilder.buildMenuTree(input: input), expected)
            let noFeatures = MenuBuildInput(location: .items, selection: .singleFolder, enabledFeatureIds: [])
            try assertEqual(MenuTreeBuilder.buildMenuTree(input: noFeatures), [])
        }

        runTest("服务菜单防漂移：完整声明对齐时校验无 issue") {
            let testFeatures = [
                MenuFeature(id: "test.copy", nameKey: "测试复制", descriptionKey: "", systemImage: "link",
                            serviceDeclaration: ServiceMenuDeclaration(message: "testCopy", menuItemTitle: "FinderRight: Test Copy"))
            ]
            let plist = [("testCopy", "FinderRight: Test Copy")]
            let provider = "func testCopy(_ pboard: NSPasteboard) {}"
            let strings: Set<String> = ["FinderRight: Test Copy"]

            let issues = ServiceMenuDriftChecker.verify(
                features: testFeatures,
                plistServices: plist,
                providerSource: provider,
                servicesMenuKeys: strings
            )
            try assertTrue(issues.isEmpty, "对齐时 issues 必须为空")
        }

        runTest("服务菜单防漂移：缺失条目与多余条目准确报错") {
            let testFeatures = [
                MenuFeature(id: "test.copy", nameKey: "测试复制", descriptionKey: "", systemImage: "link",
                            serviceDeclaration: ServiceMenuDeclaration(message: "testCopy", menuItemTitle: "FinderRight: Test Copy"))
            ]
            // Plist 缺少该声明
            let issuesMissing = ServiceMenuDriftChecker.verify(
                features: testFeatures,
                plistServices: [],
                providerSource: "func testCopy() {}",
                servicesMenuKeys: ["FinderRight: Test Copy"]
            )
            try assertEqual(issuesMissing.count, 1)
            try assertEqual(issuesMissing[0].file, "FinderRight/Info.plist")
            try assertEqual(issuesMissing[0].featureId, "test.copy")

            // Plist 含有未声明的多余服务
            let issuesExtra = ServiceMenuDriftChecker.verify(
                features: [],
                plistServices: [("extraService", "FinderRight: Extra")],
                providerSource: "",
                servicesMenuKeys: []
            )
            try assertEqual(issuesExtra.count, 1)
            try assertEqual(issuesExtra[0].message, "extraService")

            // Provider 缺失同名处理方法
            let issuesNoMethod = ServiceMenuDriftChecker.verify(
                features: testFeatures,
                plistServices: [("testCopy", "FinderRight: Test Copy")],
                providerSource: "// 没有任何方法",
                servicesMenuKeys: ["FinderRight: Test Copy"]
            )
            try assertEqual(issuesNoMethod.count, 1)
            try assertEqual(issuesNoMethod[0].file, "FinderRight/Services/ServicesProvider.swift")

            // Strings 缺失本地化映射
            let issuesNoStrings = ServiceMenuDriftChecker.verify(
                features: testFeatures,
                plistServices: [("testCopy", "FinderRight: Test Copy")],
                providerSource: "func testCopy() {}",
                servicesMenuKeys: []
            )
            try assertEqual(issuesNoStrings.count, 1)
            try assertEqual(issuesNoStrings[0].file, "FinderRight/zh-Hans.lproj/ServicesMenu.strings")
        }

        runTest("ServiceInvocationPolicy 下沉参数校验") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let file = tempDir.appendingPathComponent("note.txt")
            try Data().write(to: file)

            // targetDirectory: 文件夹返回自身，普通文件返回父目录
            try assertEqual(ServiceInvocationPolicy.targetDirectory(for: tempDir).path, tempDir.path)
            try assertEqual(ServiceInvocationPolicy.targetDirectory(for: file).path, tempDir.path)

            // validateSingleFile
            try assertEqual(ServiceInvocationPolicy.validateSingleFile(from: [file])?.path, file.path)
            try assertNil(ServiceInvocationPolicy.validateSingleFile(from: []))
            try assertNil(ServiceInvocationPolicy.validateSingleFile(from: [file, tempDir]))

            // filterArchives
            let zip = tempDir.appendingPathComponent("a.zip")
            let doc = tempDir.appendingPathComponent("b.docx")
            try assertEqual(ServiceInvocationPolicy.filterArchives(from: [zip, doc, file]), [zip])

            // validateFavoritesTransfer
            try assertTrue(ServiceInvocationPolicy.validateFavoritesTransfer(items: [file], favorites: ["/tmp"]))
            try assertTrue(!ServiceInvocationPolicy.validateFavoritesTransfer(items: [], favorites: ["/tmp"]))
            try assertTrue(!ServiceInvocationPolicy.validateFavoritesTransfer(items: [file], favorites: []))
        }

        runTest("UpdatePolicy 备用源地址双向映射及拒绝非法 URL") {
            let tag = "v1.2.3"
            let name = "FinderRight-\(tag).zip"
            let githubZIP = URL(string: "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/\(name)")!
            let websiteZIP = URL(string: "\(UpdatePolicy.websiteOrigin)/download/\(tag)/\(name)")!

            // 双向映射正常推导
            try assertEqual(UpdatePolicy.alternateAssetURL(for: githubZIP), websiteZIP)
            try assertEqual(UpdatePolicy.alternateAssetURL(for: websiteZIP), githubZIP)

            // .sha256 校验和文件映射
            let githubSHA = URL(string: githubZIP.absoluteString + ".sha256")!
            let websiteSHA = URL(string: websiteZIP.absoluteString + ".sha256")!
            try assertEqual(UpdatePolicy.alternateAssetURL(for: githubSHA), websiteSHA)
            try assertEqual(UpdatePolicy.alternateAssetURL(for: websiteSHA), githubSHA)

            // fallbackAssetURL 判定
            try assertEqual(UpdatePolicy.fallbackAssetURL(for: githubZIP, allowFallback: true), websiteZIP)
            try assertNil(UpdatePolicy.fallbackAssetURL(for: githubZIP, allowFallback: false))

            // 拒绝非法 URL
            let invalids = [
                "http://github.com/funny-dog/FinderRight/releases/download/\(tag)/\(name)", // 非 HTTPS
                "https://github.com/other-org/FinderRight/releases/download/\(tag)/\(name)", // 跨仓库
                "https://github.com/funny-dog/FinderRight/releases/download/latest/\(name)", // latest
                "https://github.com/funny-dog/FinderRight/releases/download/v1.2.3/FinderRight-v1.2.4.zip", // 版本不匹配
                "\(UpdatePolicy.websiteOrigin)/download/\(tag)/\(name)?query=1", // 带 query
                "\(UpdatePolicy.websiteOrigin)/download/\(tag)/\(name)#hash" // 带 fragment
            ]
            for invalid in invalids {
                try assertNil(UpdatePolicy.alternateAssetURL(for: URL(string: invalid)!), "应拒绝: \(invalid)")
            }
        }

        runTest("UpdatePolicy Release 数据解析：带 digest 完整新版本") {
            let hash = String(repeating: "f", count: 64)
            let tag = "v2.0.0"
            let json = """
            {
                "tag_name": "\(tag)",
                "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
                "assets": [
                    {
                        "name": "FinderRight-\(tag).zip",
                        "browser_download_url": "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/FinderRight-\(tag).zip",
                        "digest": "sha256:\(hash)"
                    }
                ]
            }
            """
            let status = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: false, currentVersion: "1.0.0")
            let expectedURL = URL(string: "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/FinderRight-\(tag).zip")!
            try assertEqual(status, .updateAvailable(
                version: tag,
                releaseURL: URL(string: "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)")!,
                downloadURL: expectedURL,
                checksum: .digest(hash)
            ))
        }

        runTest("UpdatePolicy Release 数据解析：带 sha256 文件且走官网镜像") {
            let tag = "v2.0.0"
            let json = """
            {
                "tag_name": "\(tag)",
                "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
                "assets": [
                    {
                        "name": "FinderRight-\(tag).zip",
                        "browser_download_url": "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/FinderRight-\(tag).zip"
                    },
                    {
                        "name": "FinderRight-\(tag).zip.sha256",
                        "browser_download_url": "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/FinderRight-\(tag).zip.sha256"
                    }
                ]
            }
            """
            let status = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: true, currentVersion: "1.0.0")
            let expectedDownloadURL = URL(string: "\(UpdatePolicy.websiteOrigin)/download/\(tag)/FinderRight-\(tag).zip")!
            let expectedChecksumURL = URL(string: "\(UpdatePolicy.websiteOrigin)/download/\(tag)/FinderRight-\(tag).zip.sha256")!
            try assertEqual(status, .updateAvailable(
                version: tag,
                releaseURL: URL(string: "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)")!,
                downloadURL: expectedDownloadURL,
                checksum: .file(expectedChecksumURL)
            ))
        }

        runTest("UpdatePolicy Release 数据解析：无匹配资产或跨仓库资产") {
            let tag = "v2.0.0"
            let json = """
            {
                "tag_name": "\(tag)",
                "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
                "assets": [
                    {
                        "name": "OtherApp.zip",
                        "browser_download_url": "https://example.com/OtherApp.zip"
                    }
                ]
            }
            """
            let status = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: false, currentVersion: "1.0.0")
            try assertEqual(status, .updateAvailable(
                version: tag,
                releaseURL: URL(string: "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)")!,
                downloadURL: nil,
                checksum: nil
            ))
        }

        runTest("UpdatePolicy Release 数据解析：版本相同或更旧") {
            let tagSame = "v1.0.0"
            let jsonSame = """
            {"tag_name": "\(tagSame)", "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tagSame)"}
            """
            let statusSame = try UpdatePolicy.releaseStatus(from: Data(jsonSame.utf8), viaWebsite: false, currentVersion: "1.0.0")
            try assertEqual(statusSame, .upToDate)

            let tagOlder = "v0.9.5"
            let jsonOlder = """
            {"tag_name": "\(tagOlder)", "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tagOlder)"}
            """
            let statusOlder = try UpdatePolicy.releaseStatus(from: Data(jsonOlder.utf8), viaWebsite: false, currentVersion: "1.0.0")
            try assertEqual(statusOlder, .upToDate)
        }

        runTest("UpdatePolicy Release 数据解析：draft 与 prerelease 保留现有行为") {
            let tag = "v2.1.0"
            let json = """
            {
                "tag_name": "\(tag)",
                "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
                "draft": true,
                "prerelease": true
            }
            """
            let status = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: false, currentVersion: "1.0.0")
            try assertEqual(status, .updateAvailable(
                version: tag,
                releaseURL: URL(string: "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)")!,
                downloadURL: nil,
                checksum: nil
            ))
            let ignoredFields = json.replacingOccurrences(of: "\"draft\": true", with: "\"draft\": \"ignored\"")
                .replacingOccurrences(of: "\"prerelease\": true", with: "\"prerelease\": 1")
            try assertEqual(try UpdatePolicy.releaseStatus(from: Data(ignoredFields.utf8), viaWebsite: false, currentVersion: "1.0.0"), status)

        }

        runTest("UpdatePolicy Release 数据解析：非法标签格式抛出错误") {
            for invalidTag in ["1.0.0", "v1.0", "v1.0.0-beta", "not-a-version"] {
                let json = """
                {"tag_name": "\(invalidTag)", "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(invalidTag)"}
                """
                var didThrow = false
                do {
                    _ = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: false, currentVersion: "1.0.0")
                } catch {
                    didThrow = true
                }
                try assertTrue(didThrow, "非法 tag [\(invalidTag)] 应抛出错误")
            }
        }

        runTest("UpdatePolicy 两路检查仲裁：首个完整可安装新版直接完成") {
            let fullStatus: UpdateCheckStatus = .updateAvailable(
                version: "v2.0.0",
                releaseURL: URL(string: "https://example.com/rel")!,
                downloadURL: URL(string: "https://example.com/dl")!,
                checksum: .digest("abcd")
            )
            let decision = UpdatePolicy.arbitrateCheck(
                result: .success(fullStatus),
                currentFallback: nil,
                remaining: 1
            )
            try assertEqual(decision, .finish(status: fullStatus, recordSuccessDate: true))
        }

        runTest("UpdatePolicy 两路检查仲裁：部分响应暂存 fallback 与最终裁决") {
            let partialStatus: UpdateCheckStatus = .updateAvailable(
                version: "v2.0.0",
                releaseURL: URL(string: "https://example.com/rel")!,
                downloadURL: nil,
                checksum: nil
            )

            // 第一路返回缺少校验和的新版，仍有 1 路待返回 -> 继续等待并暂存
            let step1 = UpdatePolicy.arbitrateCheck(
                result: .success(partialStatus),
                currentFallback: nil,
                remaining: 1
            )
            try assertEqual(step1, .waitForRemaining(fallback: partialStatus))

            // 第二路返回更高版本（同样缺少校验和），剩余 0 路 -> 决出最新版本
            let partialStatusHigher: UpdateCheckStatus = .updateAvailable(
                version: "v2.1.0",
                releaseURL: URL(string: "https://example.com/rel2")!,
                downloadURL: nil,
                checksum: nil
            )
            let step2 = UpdatePolicy.arbitrateCheck(
                result: .success(partialStatusHigher),
                currentFallback: partialStatus,
                remaining: 0
            )
            try assertEqual(step2, .finish(status: partialStatusHigher, recordSuccessDate: true))
        }

        runTest("UpdatePolicy 两路检查仲裁：一路失败一路成功与双路全败") {
            let err = UpdateError("网络错误")

            // 第一路失败，剩余 1 路 -> 继续等待
            let step1 = UpdatePolicy.arbitrateCheck(
                result: .failure(err),
                currentFallback: nil,
                remaining: 1
            )
            try assertEqual(step1, .waitForRemaining(fallback: nil))

            // 第二路也失败，剩余 0 路 -> 决出失败，且不记录成功时间
            let step2Fail = UpdatePolicy.arbitrateCheck(
                result: .failure(err),
                currentFallback: nil,
                remaining: 0
            )
            try assertEqual(step2Fail, .finish(status: .failed(err.localizedDescription), recordSuccessDate: false))

            // 若已有 fallback，第二路失败时采用已有 fallback
            let fallback: UpdateCheckStatus = .upToDate
            let step2Fallback = UpdatePolicy.arbitrateCheck(
                result: .failure(err),
                currentFallback: fallback,
                remaining: 0
            )
            try assertEqual(step2Fallback, .finish(status: fallback, recordSuccessDate: true))
        }

        runTest("UpdatePolicy 缓存复用决策与请求构造") {
            let now = Date()
            let status: UpdateCheckStatus = .upToDate

            // 10 分钟内正常复用
            try assertTrue(UpdatePolicy.shouldReuseCachedStatus(currentStatus: status, lastCheckedDate: now.addingTimeInterval(-300), now: now, force: false))
            // 超过 10 分钟不复用
            try assertTrue(!UpdatePolicy.shouldReuseCachedStatus(currentStatus: status, lastCheckedDate: now.addingTimeInterval(-700), now: now, force: false))
            // force 强制检查不复用
            try assertTrue(!UpdatePolicy.shouldReuseCachedStatus(currentStatus: status, lastCheckedDate: now.addingTimeInterval(-100), now: now, force: true))
            // failed 状态不复用
            try assertTrue(!UpdatePolicy.shouldReuseCachedStatus(currentStatus: .failed("err"), lastCheckedDate: now.addingTimeInterval(-100), now: now, force: false))

            // 请求构造
            let req = UpdatePolicy.makeCheckRequest(for: URL(string: "https://example.com")!)
            try assertEqual(req.value(forHTTPHeaderField: "User-Agent"), "FinderRight-App")
            try assertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github.v3+json")
        }

        runTest("UpdatePolicy 下载超时状态机决策") {
            var tracker = DownloadTimeoutTracker(firstByteTimeout: 3, stallTimeout: 10)
            try assertEqual(tracker.initialTimeout(), 3)
            try assertTrue(!tracker.isCompleted)

            // 收到数据，未确定预期总量
            let step1 = tracker.handleDataWritten(bytesWritten: 100, totalBytesWritten: 100, totalBytesExpected: -1)
            try assertEqual(step1?.resetTimeoutInterval, 10)
            try assertNil(step1?.progress)

            // 收到数据，进度计算与边界裁切
            let step2 = tracker.handleDataWritten(bytesWritten: 50, totalBytesWritten: 50, totalBytesExpected: 100)
            try assertEqual(step2?.progress, 0.5)

            let stepOverflow = tracker.handleDataWritten(bytesWritten: 200, totalBytesWritten: 200, totalBytesExpected: 100)
            try assertEqual(stepOverflow?.progress, 1.0)

            // 首次完成返回 true，二次完成返回 false
            try assertTrue(tracker.handleFinished())
            try assertTrue(tracker.isCompleted)
            try assertTrue(!tracker.handleFinished())
            try assertNil(tracker.handleDataWritten(bytesWritten: 10, totalBytesWritten: 10, totalBytesExpected: 10))
        }

        runTest("操作历史：未执行缩放保留失败状态并直接说明原因") {
            let reason = ImageTransformError.alreadySmallerThanTarget(longEdge: 436, target: 800).localizedDescription
            let record = OperationRecord(kind: .scaleImage, subject: "photo.heic", failure: reason)
            try assertTrue(!record.succeeded)
            try assertEqual(OperationHistoryPresentation.Outcome(record), .failed)
            try assertEqual(OperationHistoryPresentation.failureSummary(record), reason)
            try assertTrue(reason.contains("436") && reason.contains("800") && reason.contains("不放大"))
        }

        runTest("操作历史：无需缩放说明不属于失败且兼容旧记录") {
            let note = "photo.heic：图片长边（436 像素）未超过 800 像素，已跳过"
            let record = OperationRecord(kind: .scaleImage, subject: "photo.heic", note: note)
            try assertTrue(record.succeeded)
            try assertEqual(OperationHistoryPresentation.Outcome(record), .completed)
            try assertEqual(OperationHistoryFilter(searchText: "436").apply(to: [record]), [record])
            let encoded = try JSONEncoder().encode(record)
            try assertEqual(try JSONDecoder().decode(OperationRecord.self, from: encoded), record)
            var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            legacy.removeValue(forKey: "note")
            let old = try JSONDecoder().decode(OperationRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
            try assertNil(old.note)
            try assertTrue(old.succeeded)
            let failed = OperationRecord(kind: .scaleImage, subject: "bad.heic", failure: "decode failed", note: note)
            try assertEqual(OperationHistoryPresentation.Outcome(failed), .failed)
        }

        runTest("操作历史 状态搜索筛选与日期分组") {
        let ok = OperationRecord(kind: .compress, subject: "资料")
        let cancelled = OperationRecord(kind: .decompress, subject: "资料.zip", cancelled: true)
        let failed = OperationRecord(kind: .decompress, subject: "资料.zip", failure: "unsupported compression method (exit 1)")
        let partial = OperationRecord(kind: .move, subject: "3 个项目", failure: "Permission denied",
                                      results: [URL(fileURLWithPath: "/tmp/completed.txt")])
        let destination = URL(fileURLWithPath: "/tmp/目标文件夹")
        let results = [destination.appendingPathComponent("a.txt"), destination.appendingPathComponent("b.txt")]
        for (kind, action) in [(OperationRecord.Kind.move, "移动"), (.copy, "复制")] {
            let completed = OperationRecord(kind: kind, subject: "3 个项目", results: results, location: destination)
            precondition(OperationHistoryPresentation.transferSuccessMessage(completed) == "已\(action) 2 项到“目标文件夹”")
            precondition(OperationHistoryPresentation.transferSuccessMessage(
                OperationRecord(kind: kind, subject: "a", results: results, cancelled: true)) == nil)
            precondition(OperationHistoryPresentation.transferSuccessMessage(
                OperationRecord(kind: kind, subject: "a")) == nil)
        }
        for record in [ok, cancelled, failed, partial,
                       OperationRecord(kind: .paste, subject: "a", results: results)] {
            precondition(OperationHistoryPresentation.transferSuccessMessage(record) == nil)
        }
        precondition(OperationHistoryPresentation.transferSuccessMessage(
            OperationRecord(kind: .copy, subject: "a", results: [results[0]])) == "已复制 1 项到“目标文件夹”")
        precondition(OperationHistoryPresentation.status(ok) == "已完成")
        precondition(OperationHistoryPresentation.status(cancelled) == "已取消")
        precondition(OperationHistoryPresentation.status(failed) == "未完成")
        precondition(OperationHistoryPresentation.status(partial) == "部分完成")
        precondition(OperationHistoryPresentation.failureSummary(partial).contains("权限"))
        precondition(!OperationHistoryPresentation.failureSummary(failed).contains("exit"))
        precondition(OperationHistoryPresentation.failureSummary(failed).contains("格式"))
        for (reason, expected) in [("No space left on device", "空间"), ("Incorrect password", "密码"),
                                   ("No such file", "找不到"), ("File exists", "同名")] {
            precondition(OperationHistoryPresentation.failureSummary(
                OperationRecord(kind: .copy, subject: "a", failure: reason)).contains(expected))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 5))!
        precondition(OperationHistoryPresentation.dayTitle(now, now: now, calendar: calendar) == "今天")
        precondition(OperationHistoryPresentation.dayTitle(now.addingTimeInterval(-600), now: now, calendar: calendar) == "昨天")
        let groups = OperationHistoryPresentation.dayGroups([
            OperationRecord(kind: .copy, subject: "a", date: now.addingTimeInterval(60)),
            OperationRecord(kind: .copy, subject: "b", date: now.addingTimeInterval(-600)),
            OperationRecord(kind: .copy, subject: "c", date: now),
        ], calendar: calendar)
        precondition(groups.map { $0.records.map(\.subject) } == [["a", "c"], ["b"]], "按天分组：组按日期倒序，组内保持原顺序")
        precondition([ok, cancelled, failed, partial].map(OperationHistoryPresentation.Outcome.init)
                     == [.completed, .cancelled, .failed, .partial])
        print("✓ 历史状态、用户可读失败原因及跨午夜日期分组检查通过")

        let searchRecord = OperationRecord(kind: .copy, subject: "3 个项目",
                                           results: [URL(fileURLWithPath: "/tmp/Projects/Résumé.PDF")],
                                           location: URL(fileURLWithPath: "/tmp/Projects"))
        let candidates = [ok, cancelled, failed, partial, searchRecord]
        precondition(OperationHistoryFilter().apply(to: candidates) == candidates)
        precondition(OperationHistoryFilter(searchText: " \n ").apply(to: candidates) == candidates)
        precondition(!OperationHistoryFilter(searchText: " \n ").isActive)
        precondition(OperationHistoryFilter(searchText: "资料").apply(to: candidates) == [ok, cancelled, failed])
        precondition(OperationHistoryFilter(searchText: "复制 resume projects").apply(to: candidates) == [searchRecord])
        precondition(OperationHistoryFilter(searchText: "résumé.pdf").apply(to: candidates) == [searchRecord])
        precondition(OperationHistoryFilter(searchText: "权限").apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(searchText: "unsupported").apply(to: candidates) == [failed])
        precondition(OperationHistoryFilter(searchText: "move").apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(kind: .move, status: .partial).apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(kind: .compress, status: .failed).apply(to: candidates).isEmpty)
        for (status, expected) in [(OperationHistoryFilter.Status.completed, [ok, searchRecord]),
                                   (.partial, [partial]), (.failed, [failed]), (.cancelled, [cancelled])] {
            precondition(OperationHistoryFilter(status: status).apply(to: candidates) == expected)
        }
        let counts = OperationHistoryFilter(status: .failed).statusCounts(in: candidates)
        precondition(counts == [.all: 5, .completed: 2, .partial: 1, .failed: 1, .cancelled: 1], "状态数量不受当前状态筛选影响")
        precondition(OperationHistoryFilter(kind: .decompress).statusCounts(in: candidates) == [.all: 2, .failed: 1, .cancelled: 1])
        let memoryStore = RecentOperations()
        candidates.reversed().forEach { memoryStore.record($0) }
        let before = memoryStore.records
        _ = OperationHistoryFilter(searchText: "不存在的文件", kind: .move, status: .failed).apply(to: before)
        precondition(memoryStore.records == before, "搜索和筛选不得删除或修改历史")
        print("✓ 搜索覆盖名称、操作、结果文件、位置、失败说明；组合筛选与空结果检查通过")

        }

        runTest("文本预览 刚好 1 MiB 完整显示") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("exact.yaml")
            let data = Data(repeating: 65, count: 1_048_576)
            try data.write(to: file)
            guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(text.utf8.count, data.count)
            try assertTrue(!truncated)
        }

        runTest("文本预览 超出上限在最后完整换行处截断") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for name in [".gitignore", "main.go", "settings.ini"] {
                let file = root.appendingPathComponent(name)
                let head = "# 中文注释\r\nkey = true\n"
                try (Data(head.utf8) + Data(repeating: 65, count: 1_048_576)).write(to: file)
                guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
                try assertEqual(text, head)
                try assertTrue(truncated)
            }
        }

        runTest("文本预览 截断不切开 CRLF 换行") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("windows.conf")
            let head = "first\n"
            let padding = Data(repeating: 65, count: 1_048_576 - head.utf8.count - 1)
            try (Data(head.utf8) + padding + Data("\r\nnext".utf8)).write(to: file)
            guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(text, head)
            try assertTrue(truncated)
            let padded = head + String(repeating: "a", count: (1_048_576 - 2) / 2 - head.utf16.count - 1) + "\r\nnext"
            for (encoding, bom) in [(String.Encoding.utf16LittleEndian, [UInt8(0xFF), 0xFE]), (.utf16BigEndian, [0xFE, 0xFF])] {
                try (Data(bom) + padded.data(using: encoding)!).write(to: file)
                guard case .text(let utf16Text, let limited) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
                try assertEqual(utf16Text, head)
                try assertTrue(limited)
            }

        }

        runTest("文本预览 截断不切开 UTF-8 多字节字符") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("multi.conf")
            for character in ["中", "😀"] {
                for count in 1..<character.utf8.count {
                    let prefix = Data(repeating: 65, count: 1_048_576 - count)
                    try (prefix + Data(character.utf8) + Data([66])).write(to: file)
                    guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
                    try assertEqual(Data(text.utf8), prefix)
                    try assertTrue(truncated)
                }
            }
        }

        runTest("文本预览 无换行保留限长前缀且拒绝非法内容") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("long.config")
            try Data(repeating: 65, count: 1_048_577).write(to: file)
            guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(text.utf8.count, 1_048_576)
            try assertTrue(truncated)
            for invalid in [Data([0xFF]), Data([0])] {
                try (invalid + Data(repeating: 65, count: 1_048_576)).write(to: file)
                do {
                    _ = try PreviewDocument.read(file)
                    throw TestFailure(message: "必须拒绝二进制内容")
                } catch PreviewDocumentError.invalid {}
            }
            let link = root.appendingPathComponent("link.conf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            for url in [link, root] {
                do {
                    _ = try PreviewDocument.read(url)
                    throw TestFailure(message: "必须拒绝符号链接与目录")
                } catch PreviewDocumentError.invalid {}
            }
        }

        runTest("文本预览 保留 UTF-16 支持与原有文档上限") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("utf16.ini")
            let head = "中文 = 内容\r\n"
            try (head + String(repeating: "中", count: 524_288)).data(using: .utf16)!.write(to: file)
            guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(text, head)
            try assertTrue(truncated)
            let prefix = String(repeating: "a", count: (1_048_576 - 4) / 2)
            try (prefix + "😀").data(using: .utf16)!.write(to: file)
            guard case .text(let unicodePrefix, let unicodeTruncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(unicodePrefix, prefix)
            try assertTrue(unicodeTruncated)
            for (ext, limit) in [("md", 1_048_576), ("ipynb", 5 * 1_048_576)] {
                let large = root.appendingPathComponent("large." + ext)
                try Data(repeating: 65, count: limit + 1).write(to: large)
                do {
                    if ext == "md" { _ = try PreviewDocument.readMarkdown(large) }
                    else { _ = try PreviewDocument.read(large) }
                    throw TestFailure(message: "原有文档必须保持上限")
                } catch PreviewDocumentError.tooLarge {}
            }
        }

        runTest("表格预览 简单 CSV 解析") {
            let table = PreviewDelimited.parse("a,b\n1,2\n", delimiter: ",")
            try assertEqual(table.name, "")
            try assertEqual(table.columns, ["a", "b"])
            try assertEqual(table.rows, [["1", "2"]])
            try assertTrue(!table.truncated)
        }

        runTest("表格预览 引号内逗号与转义引号") {
            let table = PreviewDelimited.parse("name,note\n\"x, y\",\"say \"\"hi\"\"\"\n", delimiter: ",")
            try assertEqual(table.columns, ["name", "note"])
            try assertEqual(table.rows, [["x, y", "say \"hi\""]])
        }

        runTest("表格预览 引号内换行清洗为空格") {
            let table = PreviewDelimited.parse("a\n\"line1\nline2\"\n", delimiter: ",")
            try assertEqual(table.rows, [["line1 line2"]])
        }

        runTest("表格预览 CRLF 与 LF 解析一致") {
            let crlf = PreviewDelimited.parse("a,b\r\n1,2\r\n", delimiter: ",")
            let lf = PreviewDelimited.parse("a,b\n1,2\n", delimiter: ",")
            try assertEqual(crlf.columns, lf.columns)
            try assertEqual(crlf.rows, lf.rows)
            try assertEqual(crlf.rows, [["1", "2"]])
        }

        runTest("表格预览 UTF-8 BOM 被去掉") {
            let table = PreviewDelimited.parse("\u{FEFF}a,b\n1,2", delimiter: ",")
            try assertEqual(table.columns, ["a", "b"])
            try assertEqual(table.rows, [["1", "2"]])
        }

        runTest("表格预览 行长度不齐末尾补空") {
            let table = PreviewDelimited.parse("a,b,c\n1\n", delimiter: ",")
            try assertEqual(table.columns, ["a", "b", "c"])
            try assertEqual(table.rows, [["1", "", ""]])
        }

        runTest("表格预览 分隔符识别与 sep 提示行") {
            try assertEqual(PreviewDelimited.detectDelimiter("a;b;c\n1;2;3").delimiter, ";")
            let sep = PreviewDelimited.detectDelimiter("sep=;\na;b\n1;2")
            try assertEqual(sep.delimiter, ";")
            try assertTrue(sep.skipFirstLine)
            let table = PreviewDelimited.parse("a;b\n1;2", delimiter: sep.delimiter)
            try assertEqual(table.columns, ["a", "b"])
            try assertEqual(table.rows, [["1", "2"]])
            try assertEqual(PreviewDelimited.detectDelimiter("a\tb").delimiter, "\t")
        }

        runTest("表格预览 超过最大行数只保留前 500 行") {
            var source = "h\n"
            for index in 0...500 { source += "\(index)\n" }
            let table = PreviewDelimited.parse(source, delimiter: ",")
            try assertEqual(table.rows.count, PreviewDelimited.maxRows)
            try assertEqual(table.rows.first, ["0"])
            try assertEqual(table.rows.last, ["499"])
            try assertTrue(table.truncated)
        }

        runTest("表格预览 超过最大列数只保留前 50 列") {
            let source = (1...60).map { "c\($0)" }.joined(separator: ",") + "\n"
                + (1...60).map { "v\($0)" }.joined(separator: ",") + "\n"
            let table = PreviewDelimited.parse(source, delimiter: ",")
            try assertEqual(table.columns.count, PreviewDelimited.maxColumns)
            try assertEqual(table.rows.count, 1)
            try assertEqual(table.rows[0].count, PreviewDelimited.maxColumns)
            try assertTrue(table.truncated)
        }

        runTest("表格预览 超长单元格截断加省略号") {
            let table = PreviewDelimited.parse("a\n\(String(repeating: "字", count: 301))\n", delimiter: ",")
            try assertEqual(table.rows[0][0].count, PreviewDelimited.maxCellCharacters)
            try assertTrue(table.rows[0][0].hasSuffix("…"))
        }

        runTest("表格预览 丢弃的末尾宽行仍决定列数与单元格上限") {
            let wide = (1...50).map { "c\($0)" }.joined(separator: ",")
            let table = PreviewDelimited.parse("h\n" + String(repeating: "v\n", count: 500) + wide, delimiter: ",")
            try assertEqual(table.columns.count, 50)
            try assertEqual(table.columns[49], "列 50")
            try assertEqual(table.rows.count, 200)
            try assertEqual(table.rows.last?.first, "v")
            try assertEqual(table.rows.last?.last, "")
            try assertTrue(table.truncated)
            for (columns, rows) in [(1, 500), (20, 500), (50, 200)] {
                let line = Array(repeating: "v", count: columns).joined(separator: ",") + "\n"
                let exact = PreviewDelimited.parse(line + String(repeating: line, count: rows), delimiter: ",")
                try assertEqual(exact.rows.count, rows)
                try assertTrue(!exact.truncated)
                let extra = PreviewDelimited.parse(line + String(repeating: line, count: rows + 1), delimiter: ",")
                try assertEqual(extra.rows.count, rows)
                try assertTrue(extra.truncated)
            }
        }

        runTest("表格预览 超出列数的字段仍正确处理引号与内嵌换行") {
            let wide = Array(repeating: "x", count: 50).joined(separator: ",")
            let table = PreviewDelimited.parse("h\n" + wide + ",\"ignored\nsay \"\"hi\"\"\"\na,b\n", delimiter: ",")
            try assertEqual(table.rows.count, 2)
            try assertEqual(table.rows[0], Array(repeating: "x", count: 50))
            try assertEqual(Array(table.rows[1].prefix(2)), ["a", "b"])
            try assertTrue(table.truncated)
        }

        runTest("表格预览 密集分隔符与空行只保留展示字段") {
            let table = PreviewDelimited.parse(String(repeating: "a,", count: 524_287) + "a", delimiter: ",")
            try assertEqual(table.columns, Array(repeating: "a", count: 50))
            try assertTrue(table.rows.isEmpty && table.truncated)
            let hint = PreviewDelimited.detectDelimiter(String(repeating: "\n", count: 10_000) + "a;b\n1;2")
            try assertEqual(hint.delimiter, ";")
            try assertTrue(!hint.skipFirstLine)
            try assertTrue(PreviewDelimited.parse("\n\"\"\n", delimiter: ",").columns.isEmpty)
        }

        runTest("表格预览 长字段截断后仍正确解析转义引号与组合字符") {
            let prefix = String(repeating: "e\u{301}", count: 299)
            let table = PreviewDelimited.parse("a,b\n\"" + prefix + "\"\"tail\",ok\nlast,row", delimiter: ",")
            try assertEqual(table.rows[0], [prefix + "…", "ok"])
            try assertEqual(table.rows[1], ["last", "row"])
            let boundary = PreviewDelimited.parse("a\n" + String(repeating: "字", count: 300), delimiter: ",")
            try assertEqual(boundary.rows[0][0], String(repeating: "字", count: 300))
            let merged = PreviewDelimited.parse("a\n\"" + String(repeating: "x", count: 298) + "\n\u{301}zq\"", delimiter: ",")
            try assertEqual(merged.rows[0][0], String(repeating: "x", count: 298) + " \u{301}…")
        }

        runTest("表格预览 GBK 编码的 CSV 读取") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let file = root.appendingPathComponent("gbk.csv")
            try "姓名,城市\n张三,北京\n".data(using: encoding)!.write(to: file)
            try assertTrue(PreviewDocument.supports(file))
            guard case .table(let table) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少表格") }
            try assertEqual(table.columns, ["姓名", "城市"])
            try assertEqual(table.rows, [["张三", "北京"]])
            try assertTrue(!table.truncated)
        }

        runTest("表格预览 TSV 固定按制表符分列") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("data.tsv")
            try "a,b\tc\n1,2\t3\n".write(to: file, atomically: true, encoding: .utf8)
            guard case .table(let table) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少表格") }
            try assertEqual(table.columns, ["a,b", "c"])
            try assertEqual(table.rows, [["1,2", "3"]])
        }

        runTest("plist 预览 二进制转换 XML 文本") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("binary.plist")
            try PropertyListSerialization.data(fromPropertyList: ["键": "值", "n": 1], format: .binary, options: 0).write(to: file)
            try assertTrue(PreviewDocument.supports(file))
            guard case .propertyList(let text, let binary, let truncated) = try PreviewDocument.read(file) else {
                throw TestFailure(message: "缺少 plist 文本")
            }
            try assertTrue(binary)
            try assertTrue(!truncated)
            try assertTrue(text.contains("<key>键</key>"))
            try assertTrue(text.contains("<string>值</string>"))
        }

        runTest("plist 预览 XML 原文完整保留") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("plain.plist")
            let source = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                + "<plist version=\"1.0\">\n<!-- 注释 -->\n<dict>\n\t<key>名称</key>\n\t<string>值</string>\n</dict>\n</plist>\n"
            try Data(source.utf8).write(to: file)
            guard case .propertyList(let text, let binary, let truncated) = try PreviewDocument.read(file) else {
                throw TestFailure(message: "缺少 plist 文本")
            }
            try assertEqual(text, source)
            try assertTrue(!binary)
            try assertTrue(!truncated)
        }

        runTest("plist 预览 损坏的二进制文件抛错") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("broken.plist")
            try (Data("bplist00".utf8) + Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])).write(to: file)
            do {
                _ = try PreviewDocument.read(file)
                throw TestFailure(message: "必须拒绝损坏的二进制 plist")
            } catch PreviewDocumentError.invalid {}
        }

        runTest("表格预览 无备用编码仍拒绝非法 UTF-8") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("invalid.conf")
            try Data([0xC3, 0x28, 0xFF]).write(to: file)
            do {
                _ = try PreviewDocument.read(file)
                throw TestFailure(message: "必须拒绝非法 UTF-8")
            } catch PreviewDocumentError.invalid {}
        }

        runTest("图片菜单：只按扩展名判定，不读取文件内容") {
            // 路径不存在也能判定：证明构建菜单时不碰磁盘
            let root = URL(fileURLWithPath: "/not-readable")
            let images = ["a.PNG", "b.jpeg", "c.heic", "d.webp", "e.tiff"].map { root.appendingPathComponent($0) }
            let state = ImageMenuState.evaluate(selection: images)
            try assertTrue(state.isAllImages)
            try assertEqual(state.formats, [.png, .jpeg, .heic, .other, .other])
            try assertTrue(ImageMenuState.evaluate(selection: [root.appendingPathComponent("x.jpg")]).allAreJPEG)
            try assertTrue(ImageMenuState.evaluate(selection: [root.appendingPathComponent("x.heif")]).allAreHEIC)
            try assertTrue(!ImageMenuState.evaluate(selection: []).isAllImages, "空选择不显示")
            try assertTrue(!ImageMenuState.evaluate(selection: images + [root.appendingPathComponent("note.txt")]).isAllImages, "混有非图片不显示")
            try assertTrue(!ImageMenuState.evaluate(selection: [root.appendingPathComponent("README")]).isAllImages, "无扩展名不显示")
            try assertTrue(!ImageMenuState.evaluate(selection: [root.appendingPathComponent("foo.png", isDirectory: true)]).isAllImages,
                           "名为 foo.png 的目录不显示")
        }

        runTest("图片菜单：按所选格式隐藏同格式转换项") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let detectedState = ImageMenuState.evaluate(selection: [URL(fileURLWithPath: "/tmp/photo.png")])
            let input = MenuBuildInput(
                location: .items,
                selection: .singleFile(isTextEligible: false, isArchive: false),
                enabledFeatureIds: allFeatures,
                imageMenuState: detectedState
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            guard let imgNode = nodes.first(where: { $0.id == MenuFeatureCatalog.imageTools }),
                  case .submenu(let children) = imgNode.kind else {
                throw TestFailure(message: "应该显示图片子菜单")
            }
            let childIds = children.map(\.id)
            try assertTrue(!childIds.contains("image.convertToPNG"), "PNG 应隐藏转换为 PNG")
            try assertTrue(childIds.contains("image.convertToJPEG"), "显示转换为 JPEG")
            try assertTrue(childIds.contains("image.convertToHEIC"), "显示转换为 HEIC")
            var hiddenInput = input
            hiddenInput.location = .container
            try assertTrue(!MenuTreeBuilder.buildMenuTree(input: hiddenInput).contains { $0.id == MenuFeatureCatalog.imageTools })
            hiddenInput = input
            hiddenInput.enabledFeatureIds.remove(MenuFeatureCatalog.imageTools)
            try assertTrue(!MenuTreeBuilder.buildMenuTree(input: hiddenInput).contains { $0.id == MenuFeatureCatalog.imageTools })
            try assertTrue(!MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.imageTools))
            try assertEqual(ImageSourceFormat.from(uti: "public.jpeg-2000" as CFString), .other)
            for (format, hiddenID) in [(ImageSourceFormat.jpeg, "image.convertToJPEG"), (.heic, "image.convertToHEIC")] {
                var formatInput = input
                formatInput.imageMenuState = ImageMenuState(isAllImages: true, formats: [format])
                guard let menu = MenuTreeBuilder.buildMenuTree(input: formatInput).first(where: { $0.id == MenuFeatureCatalog.imageTools }),
                      case .submenu(let formatChildren) = menu.kind else { throw TestFailure(message: "缺少图片子菜单") }
                try assertTrue(!formatChildren.contains { $0.id == hiddenID })
            }

        }

        runTest("图片处理：实际输出命名重名和悬空链接不覆盖") {
            let (file, directory) = makeTestPNG(width: 100, height: 50, fillColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            defer { try? FileManager.default.removeItem(at: directory) }
            let base = file.deletingPathExtension().lastPathComponent
            let original = try Data(contentsOf: file)
            let first = try transformTestImage(sourceURL: file, operation: .convert(format: .jpeg))
            try assertEqual(first.lastPathComponent, base + ".jpg")
            let link = directory.appendingPathComponent(base + " 1.jpg")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
            let second = try transformTestImage(sourceURL: file, operation: .convert(format: .jpeg))
            try assertEqual(second.lastPathComponent, base + " 2.jpg")
            try assertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "missing-target")
            try assertEqual(try Data(contentsOf: file), original)
        }

        runTest("图片处理：实际缩放尺寸命名与不放大") {
            let (file, directory) = makeTestPNG(width: 100, height: 50, fillColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            defer { try? FileManager.default.removeItem(at: directory) }
            for target in [100, 1920] {
                do {
                    _ = try transformTestImage(sourceURL: file, operation: .scale(maxPixelSize: target))
                    throw TestFailure(message: "不得放大或重复输出相同大小图片")
                } catch ImageTransformError.alreadySmallerThanTarget(let edge, let requested) {
                    try assertEqual(edge, 100)
                    try assertEqual(requested, target)
                }
            }
            let output = try transformTestImage(sourceURL: file, operation: .scale(maxPixelSize: 40))
            try assertEqual(output.lastPathComponent, file.deletingPathExtension().lastPathComponent + " 40px.png")
            let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
            try assertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let (width, height, _, _) = try ImageTransformer.inspectImageSource(source)
            try assertEqual(width, 40)
            try assertEqual(height, 20)
        }

        runTest("图片处理：异常缩放尺寸与非普通文件拒绝") {
            let (file, directory) = makeTestPNG(width: 20, height: 10, fillColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            defer { try? FileManager.default.removeItem(at: directory) }
            for target in [0, -1, 2561, Int.max] {
                do {
                    _ = try transformTestImage(sourceURL: file, operation: .scale(maxPixelSize: target))
                    throw TestFailure(message: "必须拒绝异常尺寸")
                } catch ImageTransformError.invalidScaleSize {}
            }
            do {
                _ = try transformTestImage(sourceURL: directory, operation: .convert(format: .png))
                throw TestFailure(message: "必须拒绝目录")
            } catch ImageTransformError.cannotReadImageSource {}
        }

        runTest("图片处理：非对称双色图旋转后断言两个像素方位与方向重置") {
            // 构造宽 200 高 100 的非对称双色图（左半红、右半蓝），设置 EXIF 方向 6（顺时针旋转 90 度）
            let (jpegFile, tempDir) = makeTestAsymmetricDualColorJPEG(width: 200, height: 100, orientation: 6)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 缩放到 150 像素（原长边 200 > 150，应用旋转后高为 150，宽为 75）
            let scaledURL = try transformTestImage(sourceURL: jpegFile, operation: .scale(maxPixelSize: 150))
            defer { try? FileManager.default.removeItem(at: scaledURL) }

            guard let src = CGImageSourceCreateWithURL(scaledURL as CFURL, nil) else {
                throw TestFailure(message: "无法读取缩放后的 JPEG")
            }
            let (w, h, _, props) = try ImageTransformer.inspectImageSource(src)

            // 1. 断言输出方向重置为 1
            let outOrientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
            try assertEqual(outOrientation, 1, "输出方向必须重置为 1 (TopLeft)")

            // 2. 变换后尺寸
            try assertEqual(h, 150, "顺时针旋转 90 度后高为长边 150")
            try assertEqual(w, 75, "顺时针旋转 90 度后宽为短边 75")

            // 3. 断言旋转后至少两个像素方位：
            guard let topPixel = getPixelRGB(at: CGPoint(x: 37, y: 35), from: scaledURL),
                  let bottomPixel = getPixelRGB(at: CGPoint(x: 37, y: 115), from: scaledURL) else {
                throw TestFailure(message: "无法获取变换后两个方位的像素")
            }
            // 顺时针旋转 90 度校正后，上方方位为蓝色 (B 高，R 低)，下方方位为红色 (R 高，B 低)
            try assertTrue(topPixel.b > 200 && topPixel.r < 50, "上方像素方位应为蓝色，实际: (\(topPixel.r), \(topPixel.g), \(topPixel.b))")
            try assertTrue(bottomPixel.r > 200 && bottomPixel.b < 50, "下方像素方位应为红色，实际: (\(bottomPixel.r), \(bottomPixel.g), \(bottomPixel.b))")
        }

        runTest("图片处理：HEIC 格式转换可读回与元数据清洗") {
            let (jpegFile, tempDir) = makeTestJPEGWithOldMetadata(width: 200, height: 100)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 转换为 HEIC
            let heicURL = try transformTestImage(sourceURL: jpegFile, operation: .convert(format: .heic))
            defer { try? FileManager.default.removeItem(at: heicURL) }

            // 断言可正常读回
            guard let src = CGImageSourceCreateWithURL(heicURL as CFURL, nil) else {
                throw TestFailure(message: "HEIC 转换结果无法通过 ImageIO 读回")
            }
            let (w, h, count, props) = try ImageTransformer.inspectImageSource(src)
            try assertEqual(count, 1, "单帧 HEIC")
            try assertEqual(w, 100, "应用方向校正后宽为 100")
            try assertEqual(h, 200, "应用方向校正后高为 200")

            // 元数据清洗断言：顶层方向重置为 1
            let outOrientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
            try assertEqual(outOrientation, 1, "HEIC 输出顶层方向必须重置为 1")

            // TIFF 字典若存在，方向重置为 1，且不应残留旧的尺寸键
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let tiffOrient = (tiff[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue ?? 1
                try assertEqual(tiffOrient, 1)
                try assertNil(tiff["ImageWidth" as CFString], "TIFF 字典不应残留旧尺寸")
                try assertNil(tiff["ImageLength" as CFString], "TIFF 字典不应残留旧尺寸")
            }

            // Exif 字典若存在，不应残留旧尺寸
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                try assertNil(exif[kCGImagePropertyExifPixelXDimension], "Exif 字典不应残留旧尺寸")
                try assertNil(exif[kCGImagePropertyExifPixelYDimension], "Exif 字典不应残留旧尺寸")
            }
        }

        runTest("图片处理：WebP 格式支持转换输入，但直接缩放明确跳过并提示原因") {
            let (webpFile, tempDir) = makeTestWebP()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 1. 允许作为转换输入：WebP -> PNG
            let pngURL = try transformTestImage(sourceURL: webpFile, operation: .convert(format: .png))
            defer { try? FileManager.default.removeItem(at: pngURL) }
            guard let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil) else {
                throw TestFailure(message: "无法读取转换自 WebP 的 PNG")
            }
            let (w, h, _, _) = try ImageTransformer.inspectImageSource(src)
            try assertEqual(w, 100)
            try assertEqual(h, 100)

            // 2. 缩放 WebP：系统不支持写入 WebP，应明确跳过并抛出原因，禁止静默改变格式
            var rejected = false
            do {
                _ = try transformTestImage(sourceURL: webpFile, operation: .scale(maxPixelSize: 50))
            } catch let err as ImageTransformError {
                if case .unwritableSourceFormat(let ext) = err {
                    try assertEqual(ext.lowercased(), "webp")
                    rejected = true
                }
            }
            try assertTrue(rejected, "WebP 缩放应明确拒绝并告知不可写原因")
        }

        runTest("图片处理：预解码尺寸上限与乘法溢出检查") {
            try ImageTransformer.validateConversionSize(width: 8000, height: 5000)
            for (width, height) in [(10_000, 10_000), (Int.max, 2)] {
                do {
                    try ImageTransformer.validateConversionSize(width: width, height: height)
                    throw TestFailure(message: "必须在解码前拦截超大位图")
                } catch ImageTransformError.pixelCountExceedsLimit(_, let limit) {
                    try assertEqual(limit, 40_000_000)
                }
            }
        }

        runTest("图片处理：缩放撤销文案使用图片处理避免错称转换") {
            let id: (String) -> String = { $0 }
            let scaleSingle = UndoText.actionDescription(kind: .scaleImage, count: 1, name: "photo 1920px.png", localize: id)
            try assertEqual(scaleSingle, "图片处理“photo 1920px.png”")

            let scaleMultiple = UndoText.actionDescription(kind: .scaleImage, count: 3, name: "", localize: id)
            try assertEqual(scaleMultiple, "图片处理（3 项）")

            let convertSingle = UndoText.actionDescription(kind: .convertImage, count: 1, name: "photo.jpg", localize: id)
            try assertEqual(convertSingle, "转换“photo.jpg”")
        }

        runTest("图片处理：无透明通道时复用原图，不创建白底位图") {
            for alpha in [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast] {
                let space = CGColorSpace(name: alpha == .none ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.displayP3)!
                let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)!
                context.setFillColor(CGColor(gray: 0.5, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
                let original = context.makeImage()!
                let result = try ImageTransformer.flattenOnWhiteBackground(original)
                try assertTrue(result === original, "无 Alpha 图像应直接复用，保持像素与色彩空间")
                try assertEqual(result.colorSpace?.name, space.name)
            }
        }

        runTest("图片处理：不透明图转 JPEG 保持颜色、校正方向并保留源文件") {
            let (file, directory) = makeTestAsymmetricDualColorJPEG(width: 200, height: 100, orientation: 6)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = try Data(contentsOf: file)
            let output = try transformTestImage(sourceURL: file, operation: .convert(format: .jpeg))
            let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
            let (width, height, _, properties) = try ImageTransformer.inspectImageSource(source)
            try assertEqual(width, 100)
            try assertEqual(height, 200)
            try assertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
            let top = getPixelRGB(at: CGPoint(x: 50, y: 40), from: output)!
            let bottom = getPixelRGB(at: CGPoint(x: 50, y: 160), from: output)!
            try assertTrue(top.b > 200 && top.r < 50)
            try assertTrue(bottom.r > 200 && bottom.b < 50)
            try assertEqual(try Data(contentsOf: file), original)
            try assertTrue(output != file)
        }

        runTest("图片处理：透明 PNG 转 JPEG 后角落像素为白色") {
            // 创建四周透明、中心红色的 PNG
            let (pngFile, tempDir) = makeTestPNG(width: 100, height: 100, fillColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1), hasAlpha: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 转换为 JPEG
            let jpegURL = try transformTestImage(sourceURL: pngFile, operation: .convert(format: .jpeg))
            defer { try? FileManager.default.removeItem(at: jpegURL) }

            // 检查角落 (0, 0) 像素：在透明转 JPEG 后必须铺白底，RGB 应为白色 (>= 240)
            guard let rgb = getPixelRGB(at: CGPoint(x: 0, y: 0), from: jpegURL) else {
                throw TestFailure(message: "无法获取角落像素 RGB")
            }
            try assertTrue(rgb.r >= 240 && rgb.g >= 240 && rgb.b >= 240, "透明角落转 JPEG 必须为白色，实际为: (\(rgb.r), \(rgb.g), \(rgb.b))")
        }

        runTest("图片处理：多帧图片被拒绝") {
            let (gifFile, tempDir) = makeMultiFrameGIF()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            var rejected = false
            do {
                _ = try transformTestImage(sourceURL: gifFile, operation: .convert(format: .png))
            } catch let err as ImageTransformError {
                if case .multiFrameNotSupported(let count) = err {
                    try assertEqual(count, 2)
                    rejected = true
                }
            }
            try assertTrue(rejected, "多帧动图应被明确拒绝并跳过")
        }

        print("\n-----------------------------------------")
        print("测试结果: 总数 \(totalTests)，通过 \(passedTests)，失败 \(failedTests)")
        print("-----------------------------------------")

        if failedTests > 0 {
            exit(1)
        }
    }
}
