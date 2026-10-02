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

extension UpdateIntegrity {
    /// 新版本主 App 与扩展必须满足的签名规则：与当前运行版本由同一张证书签发，且 bundle 标识不变。
    ///
    /// 只有当前版本是证书签名时才能使用（ad-hoc 签名没有证书可比对，见 CodeSignatureCheck.leafCertificateSHA1）。
    public static func signingRequirements(leafCertificateSHA1 leaf: String) -> (app: String, appex: String) {
        ("identifier \"\(IPCBridge.mainAppBundleIdentifier)\" and certificate leaf = H\"\(leaf)\"",
         "identifier \"\(IPCBridge.extensionBundleIdentifier)\" and certificate leaf = H\"\(leaf)\"")
    }
}
