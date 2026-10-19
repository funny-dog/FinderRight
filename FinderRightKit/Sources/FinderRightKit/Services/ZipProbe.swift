import Foundation

/// 只读 ZIP 中央目录；解压前探测密码/编码，预览时复用元数据。不解压文件内容。
/// ZIP64、分卷、损坏或无法读取时 inspect 返回 nil，保留原解压流程的回退行为。
public struct ZipProbe: Equatable {
    public let hasEncryptedEntries: Bool
    public let hasNonUTF8LegacyNames: Bool

    public init(hasEncryptedEntries: Bool, hasNonUTF8LegacyNames: Bool) {
        self.hasEncryptedEntries = hasEncryptedEntries
        self.hasNonUTF8LegacyNames = hasNonUTF8LegacyNames
    }

    public struct Entry: Equatable {
        public let flags: UInt16
        public let nameBytes: [UInt8]
        public let uncompressedSize: UInt32
        public let externalAttributes: UInt32
        public let lastModFileTime: UInt16
        public let lastModFileDate: UInt16
        public let extraField: [UInt8]
    }

    static let encryptedFlag: UInt16 = 0x0001
    static let utf8NameFlag: UInt16 = 0x0800

    public static func inspect(_ url: URL) -> ZipProbe? {
        guard let entries = centralDirectoryEntries(of: url) else { return nil }
        return ZipProbe(
            hasEncryptedEntries: entries.contains { $0.flags & encryptedFlag != 0 },
            hasNonUTF8LegacyNames: entries.contains {
                $0.flags & utf8NameFlag == 0 && String(bytes: $0.nameBytes, encoding: .utf8) == nil
            })
    }

    public static func centralDirectoryEntries(of url: URL) -> [Entry]? {
        try? parseCentralDirectory(of: url)
    }

    static func parseCentralDirectory(of url: URL) throws -> [Entry] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw PreviewError.invalidArchive }
        // EOCD 固定 22 字节，注释最多 65535 字节。
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = Array(try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard tail.count == Int(tailLength) else { throw PreviewError.invalidArchive }
        var index = tail.count - 22
        var header: (count: Int, size: Int, offset: UInt64)?
        var failure = PreviewError.invalidArchive
        while index >= 0 {
            defer { index -= 1 }
            guard readUInt32(tail, index) == 0x0605_4b50,
                  index + 22 + Int(readUInt16(tail, index + 20)) == tail.count else { continue }
            let count = readUInt16(tail, index + 10)
            let size = readUInt32(tail, index + 12)
            let offset = readUInt32(tail, index + 16)
            let disk = readUInt16(tail, index + 4)
            let directoryDisk = readUInt16(tail, index + 6)
            if count == 0xFFFF || size == .max || offset == .max || disk == .max || directoryDisk == .max {
                failure = .zip64NotSupported
                continue
            }
            if disk != 0 || directoryDisk != 0 || readUInt16(tail, index + 8) != count {
                failure = .multiDiskNotSupported
                continue
            }
            let end = fileSize - tailLength + UInt64(index)
            // 必须紧接 EOCD，避免把 ZIP 注释中的伪 EOCD 当作空包或截断的目录。
            guard UInt64(offset) + UInt64(size) == end else { continue }
            guard size <= 64 * 1024 * 1024 else { throw PreviewError.tooLarge }
            if index >= 20 && readUInt32(tail, index - 20) == 0x0706_4b50 {
                failure = .zip64NotSupported
                continue
            }
            header = (Int(count), Int(size), UInt64(offset))
            break
        }
        guard let header else { throw failure }
        try handle.seek(toOffset: header.offset)
        let directory = Array(try handle.read(upToCount: header.size) ?? Data())
        guard directory.count == header.size else { throw PreviewError.invalidArchive }
        var entries: [Entry] = []
        entries.reserveCapacity(header.count)
        var offset = 0
        for _ in 0..<header.count {
            guard offset + 46 <= directory.count, readUInt32(directory, offset) == 0x0201_4b50 else {
                throw PreviewError.invalidArchive
            }
            let compressedSize = readUInt32(directory, offset + 20)
            let size = readUInt32(directory, offset + 24)
            let localOffset = readUInt32(directory, offset + 42)
            let disk = readUInt16(directory, offset + 34)
            guard compressedSize != .max, size != .max, localOffset != .max, disk != .max else {
                throw PreviewError.zip64NotSupported
            }
            guard disk == 0 else { throw PreviewError.multiDiskNotSupported }
            let nameStart = offset + 46
            let extraStart = nameStart + Int(readUInt16(directory, offset + 28))
            let commentStart = extraStart + Int(readUInt16(directory, offset + 30))
            let next = commentStart + Int(readUInt16(directory, offset + 32))
            guard next <= directory.count else { throw PreviewError.invalidArchive }
            let extra = Array(directory[extraStart..<commentStart])
            var extraOffset = 0
            while extraOffset < extra.count {
                guard extraOffset + 4 <= extra.count else { throw PreviewError.invalidArchive }
                let length = Int(readUInt16(extra, extraOffset + 2))
                guard extraOffset + 4 + length <= extra.count else { throw PreviewError.invalidArchive }
                guard readUInt16(extra, extraOffset) != 0x0001 else { throw PreviewError.zip64NotSupported }
                extraOffset += 4 + length
            }
            let flags = readUInt16(directory, offset + 8)
            guard flags & 0x2000 == 0 else { throw PreviewError.encryptedDirectory }
            entries.append(Entry(flags: flags, nameBytes: Array(directory[nameStart..<extraStart]),
                                 uncompressedSize: size, externalAttributes: readUInt32(directory, offset + 38),
                                 lastModFileTime: readUInt16(directory, offset + 12),
                                 lastModFileDate: readUInt16(directory, offset + 14), extraField: extra))
            offset = next
        }
        guard offset == directory.count else { throw PreviewError.invalidArchive }
        return entries
    }

    private static func readUInt16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
