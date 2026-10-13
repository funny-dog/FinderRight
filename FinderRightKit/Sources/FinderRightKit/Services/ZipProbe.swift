import Foundation

/// 只读 zip 中央目录的元数据探测（不解压任何内容）。
///
/// 解压前用它决定走哪条路：
/// - 含加密条目：ditto 解不了（AES 报「Unknown compression type」，ZipCrypto 没有密码回调），改用 bsdtar 带密码解；
/// - 有未声明编码的非 UTF-8 文件名（Windows 中文系统生成的 GBK 名）：bsdtar 需加 hdrcharset=CP936，否则报 Illegal byte sequence。
///
/// 拿不准（zip64、结构损坏、读不了）时返回 nil，调用方按普通包处理，行为与没有探测时一致。
public struct ZipProbe: Equatable {

    public let hasEncryptedEntries: Bool
    public let hasNonUTF8LegacyNames: Bool

    public init(hasEncryptedEntries: Bool, hasNonUTF8LegacyNames: Bool) {
        self.hasEncryptedEntries = hasEncryptedEntries
        self.hasNonUTF8LegacyNames = hasNonUTF8LegacyNames
    }

    /// 中央目录里的一条记录
    public struct Entry: Equatable {
        /// 通用标志位：bit 0 = 加密，bit 11 = 文件名为 UTF-8
        public let flags: UInt16
        public let nameBytes: [UInt8]
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

    /// EOCD 固定 22 字节，后面最多跟 65535 字节注释
    private static let eocdSize = 22
    private static let maxCommentLength = 65_535
    /// 中央目录超过这个大小就放弃探测（约对应上百万个条目），避免把异常文件整个读进内存
    private static let maxCentralDirectorySize: UInt64 = 64 * 1024 * 1024

    public static func centralDirectoryEntries(of url: URL) -> [Entry]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize >= UInt64(eocdSize) else { return nil }

        // 1. 从尾部反向找 EOCD（End of Central Directory）
        let tailLength = min(fileSize, UInt64(eocdSize + maxCommentLength))
        guard (try? handle.seek(toOffset: fileSize - tailLength)) != nil,
              let tailData = try? handle.read(upToCount: Int(tailLength)),
              tailData.count == Int(tailLength) else { return nil }
        let tail = [UInt8](tailData)
        var eocd = tail.count - eocdSize
        while eocd >= 0 && readUInt32(tail, eocd) != 0x0605_4b50 { eocd -= 1 }
        guard eocd >= 0 else { return nil }

        let entryCount = readUInt16(tail, eocd + 10)
        let directorySize = readUInt32(tail, eocd + 12)
        let directoryOffset = readUInt32(tail, eocd + 16)
        // zip64 用全 1 作占位，真实值在 zip64 EOCD 里：不处理，按拿不准返回
        guard entryCount != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else { return nil }
        guard UInt64(directorySize) <= maxCentralDirectorySize,
              UInt64(directoryOffset) + UInt64(directorySize) <= fileSize else { return nil }

        // 2. 读出整个中央目录，逐条解析
        guard (try? handle.seek(toOffset: UInt64(directoryOffset))) != nil,
              let directoryData = try? handle.read(upToCount: Int(directorySize)),
              directoryData.count == Int(directorySize) else { return nil }
        let directory = [UInt8](directoryData)

        var entries: [Entry] = []
        entries.reserveCapacity(Int(entryCount))
        var offset = 0
        for _ in 0..<entryCount {
            // 中央目录头固定 46 字节，之后依次是文件名、extra、注释
            guard offset + 46 <= directory.count, readUInt32(directory, offset) == 0x0201_4b50 else { return nil }
            let flags = readUInt16(directory, offset + 8)
            let nameLength = Int(readUInt16(directory, offset + 28))
            let extraLength = Int(readUInt16(directory, offset + 30))
            let commentLength = Int(readUInt16(directory, offset + 32))
            let nameStart = offset + 46
            let next = nameStart + nameLength + extraLength + commentLength
            guard next <= directory.count else { return nil }
            entries.append(Entry(flags: flags, nameBytes: Array(directory[nameStart..<(nameStart + nameLength)])))
            offset = next
        }
        return entries
    }

    private static func readUInt16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
}
