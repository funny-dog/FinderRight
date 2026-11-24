import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// MARK: - 测试辅助断言

// MARK: - 测试辅助断言

var totalTests = 0
var passedTests = 0
var failedTests = 0
let testFilter = ProcessInfo.processInfo.environment["FINDERRIGHT_TEST_FILTER"] ?? ""

func runTest(_ name: String, _ block: () throws -> Void) {
    guard testFilter.isEmpty || name.contains(testFilter) else { return }
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

struct TestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if a != b {
        throw TestFailure(message: "断言失败: [\(a)] 不等于 [\(b)] \(message) (at \(file):\(line))")
    }
}

func assertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if !condition {
        throw TestFailure(message: "断言失败: 期望为 true \(message) (at \(file):\(line))")
    }
}

func assertNil(_ value: Any?, _ message: String = "", file: StaticString = #file, line: UInt = #line) throws {
    if value != nil {
        throw TestFailure(message: "断言失败: 期望为 nil，但得到 [\(value!)] \(message) (at \(file):\(line))")
    }
}

func assertThrows<E: Error & Equatable>(_ expected: E, _ message: String = "", file: StaticString = #file, line: UInt = #line,
                                                _ block: () throws -> Void) throws {
    do {
        // 只关心是否抛出类型 E：其他错误同样说明没按要求失败，一并算失败
        try block()
        throw TestFailure(message: "断言失败: 应抛出 \(expected) \(message) (at \(file):\(line))")
    } catch let error as E {
        if error != expected {
            throw TestFailure(message: "断言失败: 期望 \(expected)，实际 \(error) \(message) (at \(file):\(line))")
        }
    }
}

/// 造一个只含 Info.plist 的「更新包内 App」目录，不触碰真实应用
func makeUpdateAppFixture(version: String, build: String,
                                  overrides: [String: (String, String)] = [:]) throws -> URL {
    let root = makeTempDirectory().appendingPathComponent("FinderRight.app", isDirectory: true)
    let bundles = [
        "FinderRight.app",
        "FinderRightSync.appex",
        "FinderRightPreview.appex",
        "FinderRightMarkdown.appex",
    ]
    for name in bundles {
        let path = name == "FinderRight.app" ? root : root.appendingPathComponent("Contents/PlugIns/\(name)", isDirectory: true)
        let plist = path.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
        var values: [String: String] = [
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
            "LSMinimumSystemVersion": "13.0",
        ]
        if let override = overrides[name] { values[override.0] = override.1 }
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: plist)
    }
    return root
}

func expectation(version: String, current: String = "1.0.0", system: String = "13.6.1") -> UpdatePackageCheck.Expectation {
    UpdatePackageCheck.Expectation(expectedVersion: version, currentVersion: current, operatingSystemVersion: system)
}

/// 每个用例独立的临时目录（真实文件系统语义，避免共享状态互相干扰）
func makeTempDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("finderright-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 读取 zip 内的条目名（已排序；忽略 ditto --sequesterRsrc 生成的 __MACOSX 资源分叉）
func zipEntries(_ zip: URL) throws -> [String] {
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

func transformTestImage(sourceURL: URL, operation: ImageTransformOperation) throws -> URL {
    try ImageTransformer.process(sourceURL: sourceURL, operation: operation,
                                 registry: ScratchDirectoryRegistry(registryDirectory: sourceURL.deletingLastPathComponent()))
}

/// 生成指定宽高与颜色的测试图片
func makeTestPNG(width: Int, height: Int, fillColor: CGColor, hasAlpha: Bool = false) -> (URL, URL) {
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
func makeTestAsymmetricDualColorJPEG(width: Int, height: Int, orientation: Int) -> (URL, URL) {
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
func makeTestJPEGWithOldMetadata(width: Int, height: Int) -> (URL, URL) {
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
func makeTestWebP() -> (URL, URL) {
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
func makeMultiFrameGIF() -> (URL, URL) {
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
func getPixelRGB(at point: CGPoint, from imageURL: URL) -> (r: UInt8, g: UInt8, b: UInt8)? {
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
func directoryListing(_ dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
}

/// 带一个 stored 文件的普通 ZIP，可修改字段验证目录解析边界。
func previewZipFixture(_ name: String, flags: UInt16 = 0x0800, mode: UInt32 = 0o100644) -> Data {
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

func putZipField(_ value: UInt32, at offset: Int, bytes: Int = 4, into data: inout Data) {
    for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
}

/// 当前进程的 audit token（测试「按 audit token 校验运行中进程的签名」用）
func currentProcessAuditToken() -> Data? {
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

