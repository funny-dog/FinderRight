import Foundation

public struct PreviewEntry: Equatable {
    public let path: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    public let size: Int64?
    public let modificationDate: Date?
}

public struct PreviewListing: Equatable {
    public let entries: [PreviewEntry]
    public let truncated: Bool
}

public enum PreviewError: String, LocalizedError {
    case invalidArchive = "Invalid or damaged ZIP archive"
    case zip64NotSupported = "ZIP64 archives are not supported yet"
    case multiDiskNotSupported = "Split ZIP archives are not supported yet"
    case invalidPath = "The archive contains an unsafe or excessively deep path"
    case encryptedDirectory = "The ZIP directory is encrypted and cannot be previewed"
    case tooLarge = "The archive directory is too large to preview"
    public var errorDescription: String? { rawValue }
}

/// 预览只读取元数据，不解压；文件夹按层读取，不跟随链接或进入文件包。
///
/// 访达元数据（`.DS_Store`）与 AppleDouble 资源叉（`._*`、ZIP 里的 `__MACOSX/`）始终不展示，
/// 其余点文件照常展示，与访达「显示隐藏文件」开关无关（访达 ⌘⇧. 不写回偏好，跨进程读不到真实状态）。
/// 数量上限按过滤后的可见项计算。
public enum PreviewContents {
    /// 预览始终不展示的系统杂项
    public static func isClutter(_ name: some StringProtocol) -> Bool {
        name == ".DS_Store" || name == "__MACOSX" || name.hasPrefix("._")
    }

    public static func folder(_ url: URL, limit: Int = 2000) throws -> PreviewListing {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
                                        .fileSizeKey, .contentModificationDateKey]
        let root = try url.resourceValues(forKeys: keys)
        guard root.isDirectory == true, root.isSymbolicLink != true, root.isPackage != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var readError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants],
            errorHandler: { _, error in readError = error; return false }) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var entries: [PreviewEntry] = []
        var truncated = false
        for case let item as URL in enumerator {
            if isClutter(item.lastPathComponent) { continue }
            if entries.count >= max(0, limit) { truncated = true; break }
            let values = try item.resourceValues(forKeys: keys)
            let link = values.isSymbolicLink == true
            let directory = values.isDirectory == true && !link && values.isPackage != true
            entries.append(PreviewEntry(path: item.lastPathComponent, isDirectory: directory,
                                        isSymbolicLink: link,
                                        size: values.isDirectory == true ? nil : values.fileSize.map(Int64.init),
                                        modificationDate: values.contentModificationDate))
        }
        if let readError { throw readError }
        return PreviewListing(entries: entries, truncated: truncated)
    }

    /// 本质是 ZIP 的安装包与归档，走自有中央目录解析（可列出加密条目）。
    public static let zipExtensions: Set<String> = ["zip", "apk", "ipa", "whl", "jar", "war"]

    public static func zip(_ url: URL, limit: Int = 10000) throws -> PreviewListing {
        let raw = try ZipProbe.parseCentralDirectory(of: url)
        var entries: [PreviewEntry] = []
        var truncated = false
        for entry in raw {
            let name = try decodeName(entry)
            let components = name.split(separator: "/", omittingEmptySubsequences: false)
            let parts = name.hasSuffix("/") ? components.dropLast() : components[...]
            // 仅展示安全相对路径；不把反斜杠解释成路径分隔符。
            guard !parts.isEmpty, parts.count <= 32, !name.contains("\0"), !name.contains("\\"),
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !(name.count >= 2 && name[name.index(after: name.startIndex)] == ":") else {
                throw PreviewError.invalidPath
            }
            // 任一层是杂项（如 __MACOSX/），整棵子树都不展示
            if parts.contains(where: isClutter) { continue }
            if entries.count >= max(0, limit) { truncated = true; break }
            let mode = (entry.externalAttributes >> 16) & 0o170000
            let link = mode == 0o120000
            let directory = !link && (name.hasSuffix("/") || mode == 0o040000 || entry.externalAttributes & 0x10 != 0)
            entries.append(PreviewEntry(path: name, isDirectory: directory, isSymbolicLink: link,
                                        size: directory ? nil : Int64(entry.uncompressedSize),
                                        modificationDate: modificationDate(entry)))
        }
        return PreviewListing(entries: entries, truncated: truncated)
    }

    private static func decodeName(_ entry: ZipProbe.Entry) throws -> String {
        if let name = String(bytes: entry.nameBytes, encoding: .utf8) { return name }
        // UTF-8 标志与实际字节冲突时按损坏处理，不静默展示乱码。
        guard entry.flags & ZipProbe.utf8NameFlag == 0 else { throw PreviewError.invalidArchive }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let name = String(bytes: entry.nameBytes, encoding: gbk) { return name }
        let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        guard let name = String(bytes: entry.nameBytes, encoding: dos) else { throw PreviewError.invalidArchive }
        return name
    }

    private static func modificationDate(_ entry: ZipProbe.Entry) -> Date? {
        let extra = entry.extraField
        var offset = 0
        while offset + 4 <= extra.count {
            let tag = UInt16(extra[offset]) | UInt16(extra[offset + 1]) << 8
            let length = Int(UInt16(extra[offset + 2]) | UInt16(extra[offset + 3]) << 8)
            let start = offset + 4
            guard start + length <= extra.count else { break }
            if tag == 0x5455, length >= 5, extra[start] & 1 != 0 {
                let seconds = UInt32(extra[start + 1]) | UInt32(extra[start + 2]) << 8 |
                    UInt32(extra[start + 3]) << 16 | UInt32(extra[start + 4]) << 24
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            offset = start + length
        }
        let date = entry.lastModFileDate, time = entry.lastModFileTime
        let month = Int((date >> 5) & 15), day = Int(date & 31)
        let hour = Int(time >> 11), minute = Int((time >> 5) & 63), second = Int(time & 31) * 2
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else { return nil }
        return Calendar(identifier: .gregorian).date(from: DateComponents(
            year: Int(date >> 9) + 1980, month: month, day: day, hour: hour, minute: minute, second: second))
    }
}
