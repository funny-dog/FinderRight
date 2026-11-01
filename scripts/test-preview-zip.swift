import Foundation
import FinderRightKit

@main
struct ZIPScanChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finderright-zip-scan-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("test.zip")
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let names = [Data("first.txt".utf8), "中文.txt".data(using: encoding)!, Data("last.txt".utf8)]
        // UTC 时间扩展字段位于中央目录中间，检验非零起点切片的读取。
        var extra = Data([0x55, 0x54, 5, 0, 1, 0, 0, 0, 0])
        put(1_600_000_000, at: 5, bytes: 4, into: &extra)
        let fixture = makeZIP(names, extra: extra)
        try fixture.data.write(to: zip)
        let listing = try autoreleasepool { try PreviewContents.zip(zip) }
        precondition(listing.entries.map(\.path) == ["first.txt", "中文.txt", "last.txt"])
        precondition(listing.entries.allSatisfy { $0.modificationDate?.timeIntervalSince1970 == 1_600_000_000 })
        precondition(ZipProbe.inspect(zip) == ZipProbe(hasEncryptedEntries: false, hasNonUTF8LegacyNames: true))
        let raw = ZipProbe.centralDirectoryEntries(of: zip)!
        precondition(raw.map { Data($0.nameBytes) } == names && raw.allSatisfy { $0.extraField == Array(extra) })
        let limited = try PreviewContents.zip(zip, limit: 1)
        precondition(limited.entries.map(\.path) == ["first.txt"] && limited.truncated)

        func rejects(_ data: Data, _ error: PreviewError) throws {
            try data.write(to: zip)
            do { _ = try PreviewContents.zip(zip, limit: 1); preconditionFailure("截断后仍须校验结构") }
            catch let actual as PreviewError { precondition(actual == error) }
            precondition(ZipProbe.inspect(zip) == nil)
        }
        var damaged = fixture.data
        put(0x2000, at: fixture.centralOffsets.last! + 8, bytes: 2, into: &damaged)
        try rejects(damaged, .encryptedDirectory)
        let unsafe = makeZIP([Data("../bad".utf8), Data("tail".utf8)], extra: extra)
        damaged = unsafe.data
        put(0x2000, at: unsafe.centralOffsets.last! + 8, bytes: 2, into: &damaged)
        try rejects(damaged, .encryptedDirectory)
        try rejects(Data(fixture.data.dropLast()), .invalidArchive)

        try fixture.data.write(to: zip)
        var checks = 0
        do {
            _ = try PreviewContents.zip(zip, isCancelled: { checks += 1; return checks > 3 })
            preconditionFailure("扫描应响应在途取消")
        } catch { precondition((error as? CocoaError)?.code == .userCancelled) }
        let missing = root.appendingPathComponent("missing")
        for read in [
            { _ = try PreviewContents.zip(missing, isCancelled: { true }) },
            { _ = try PreviewContents.folder(missing, isCancelled: { true }) }
        ] {
            do { try read(); preconditionFailure("取消应先于文件访问") }
            catch { precondition((error as? CocoaError)?.code == .userCancelled) }
        }
        let link = root.appendingPathComponent("link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zip)
        precondition(ZipProbe.inspect(link) == nil)
        print("✓ ZIP 扫描：全量结构校验、错误优先级、GBK、UTC时间、独立展示数据、数组兼容、取消、符号链接拒绝")
    }

    private static func put(_ value: UInt32, at offset: Int, bytes: Int, into data: inout Data) {
        for index in 0..<bytes { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
    }

    private static func makeZIP(_ names: [Data], extra: Data) -> (data: Data, centralOffsets: [Int]) {
        var local = Data(), central = Data()
        var offsets: [Int] = []
        for name in names {
            let localOffset = local.count
            var header = Data(repeating: 0, count: 30)
            put(0x04034b50, at: 0, bytes: 4, into: &header)
            put(20, at: 4, bytes: 2, into: &header)
            put(UInt32(name.count), at: 26, bytes: 2, into: &header)
            put(UInt32(extra.count), at: 28, bytes: 2, into: &header)
            local.append(header); local.append(name); local.append(extra)
            offsets.append(central.count)
            header = Data(repeating: 0, count: 46)
            put(0x02014b50, at: 0, bytes: 4, into: &header)
            put(20, at: 4, bytes: 2, into: &header)
            put(20, at: 6, bytes: 2, into: &header)
            put(UInt32(name.count), at: 28, bytes: 2, into: &header)
            put(UInt32(extra.count), at: 30, bytes: 2, into: &header)
            put(UInt32(localOffset), at: 42, bytes: 4, into: &header)
            central.append(header); central.append(name); central.append(extra)
        }
        let centralStart = local.count
        var end = Data(repeating: 0, count: 22)
        put(0x06054b50, at: 0, bytes: 4, into: &end)
        put(UInt32(names.count), at: 8, bytes: 2, into: &end)
        put(UInt32(names.count), at: 10, bytes: 2, into: &end)
        put(UInt32(central.count), at: 12, bytes: 4, into: &end)
        put(UInt32(centralStart), at: 16, bytes: 4, into: &end)
        local.append(central); local.append(end)
        return (local, offsets.map { $0 + centralStart })
    }
}
