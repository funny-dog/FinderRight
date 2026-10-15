import Foundation

/// 复制文件内容的大小预设选项（KB）
public enum CopyFileContentSizePreset: Int, CaseIterable, Identifiable {
    case kb500 = 512
    case mb1 = 1024
    case mb2 = 2048
    case mb5 = 5120
    case mb10 = 10240

    public var id: Int { rawValue }

    public var titleKey: String {
        switch self {
        case .kb500: return "500 KB"
        case .mb1: return "1 MB (默认)"
        case .mb2: return "2 MB"
        case .mb5: return "5 MB"
        case .mb10: return "10 MB"
        }
    }
}

/// 读取文件内容的结果
public enum FileContentReadResult: Equatable {
    case success(String)
    case notRegularFile
    case fileTooLarge(size: Int64, limit: Int64)
    case readFailed
    case binaryFile
}

/// 快速复制文件文本内容读取器
public enum FileContentReader {
    /// 检查指定 URL 是否满足单选快速复制内容的条件（用于在构建菜单时快速过滤，避免无谓 I/O）
    public static func isEligible(url: URL, maxBytes: Int64) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return false
        }
        return Int64(size) <= maxBytes
    }

    /// 读取文件内容并转换为纯文本。若包含二进制空字节或无法按文本解码则拒绝
    public static func readText(from url: URL, maxBytes: Int64) -> FileContentReadResult {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize else {
            return .notRegularFile
        }

        let fileSize = Int64(size)
        guard fileSize <= maxBytes else {
            return .fileTooLarge(size: fileSize, limit: maxBytes)
        }

        if fileSize == 0 {
            return .success("")
        }

        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .readFailed
        }

        // 1. 检查 UTF-16 BOM (FE FF 或 FF FE)
        if (data.starts(with: [0xFE, 0xFF]) || data.starts(with: [0xFF, 0xFE])),
           let text = String(data: data, encoding: .utf16),
           !text.contains("\0") {
            return .success(text)
        }

        // 2. 无 UTF-16 BOM 时，若前 8KB 包含空字符 (0x00)，视为二进制文件
        if data.prefix(8192).contains(0) {
            return .binaryFile
        }

        // 3. 按 UTF-8 解码
        if let text = String(data: data, encoding: .utf8) {
            return .success(text)
        }

        return .binaryFile
    }
}
