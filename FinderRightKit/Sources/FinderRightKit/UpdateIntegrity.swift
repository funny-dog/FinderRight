import Foundation

/// 自动更新的完整性校验辅助（纯逻辑，便于单测）
public enum UpdateIntegrity {

    /// 解析 `shasum -a 256` 输出（形如 `<hash>  <文件名>`），只接受 64 位十六进制，返回小写哈希。
    ///
    /// 不合格式一律返回 nil：GitHub 偶尔返回 HTML 错误页，若只取首个单词，
    /// 会得到 `<!doctype` 这类"哈希"，虽然随后比对必然失败，但错误原因会被误报为"包被篡改"。
    public static func parseChecksum(_ text: String) -> String? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        // isHexDigit 也认全角数字，额外限定 ASCII
        guard token.count == 64, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return token
    }
}
