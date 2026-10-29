import Foundation
import CryptoKit

/// 「复制哈希」的纯逻辑：流式计算文件摘要，并按 shasum 的格式拼出剪贴板文本。扩展与主 App 共用。
public enum FileHasher {

    public enum Algorithm: String, CaseIterable {
        case sha256, sha1, md5

        /// 菜单标题，与 shasum / md5 等命令行工具的叫法一致，不做本地化
        public var title: String {
            switch self {
            case .sha256: return "SHA-256"
            case .sha1: return "SHA-1"
            case .md5: return "MD5"
            }
        }
    }

    /// 每次读 1 MiB：大文件不整块进内存
    static let chunkSize = 1 << 20

    /// 流式计算小写十六进制摘要。读不到（不存在、无权限、不是普通文件）时返回 nil。
    /// isCancelled 在每块之间检查，返回 true 时中止并返回 nil
    public static func hexDigest(of url: URL, algorithm: Algorithm,
                                 isCancelled: () -> Bool = { false }) -> String? {
        try? hexDigest(reading: url, algorithm: algorithm, isCancelled: isCancelled)
    }

    /// 更新校验需要保留具体读取错误；复制哈希入口仍使用上面的可选结果。
    public static func hexDigest(reading url: URL, algorithm: Algorithm,
                                 isCancelled: () -> Bool = { false }) throws -> String {
        guard try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha256 = SHA256(), sha1 = Insecure.SHA1(), md5 = Insecure.MD5()
        while true {
            if isCancelled() { throw CocoaError(.userCancelled) }
            // 读到末尾时返回 nil（不是空 Data）；抛错才是读取失败
            // Foundation 的临时读取对象也逐块释放，避免 autorelease 累积成整文件大小。
            let chunk = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let data = chunk, !data.isEmpty else { break }
            switch algorithm {
            case .sha256: sha256.update(data: data)
            case .sha1: sha1.update(data: data)
            case .md5: md5.update(data: data)
            }
        }
        switch algorithm {
        case .sha256: return hex(sha256.finalize())
        case .sha1: return hex(sha1.finalize())
        case .md5: return hex(md5.finalize())
        }
    }

    /// 剪贴板文本：单个文件只给摘要本身，便于直接粘贴比对；
    /// 多个文件每行「摘要␣␣文件名」，与 shasum 的输出一致，SHA 系列可直接在该目录 `shasum -c` 校验
    public static func clipboardText(_ results: [(name: String, digest: String)]) -> String {
        if results.count == 1, let only = results.first { return only.digest }
        return results.map { "\($0.digest)  \($0.name)" }.joined(separator: "\n")
    }

    /// 只处理普通文件：文件夹、包（.app 等）没有单一摘要；指向普通文件的符号链接按目标计算
    public static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
