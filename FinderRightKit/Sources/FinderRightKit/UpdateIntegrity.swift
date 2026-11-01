import Foundation

/// 自动更新的完整性校验辅助（纯逻辑，便于单测）
public enum UpdateIntegrity {

    /// 解析 `shasum -a 256` 输出（形如 `<hash>  <文件名>`），只接受 64 位十六进制，返回小写哈希。
    ///
    /// 不合格式一律返回 nil：GitHub 偶尔返回 HTML 错误页，若只取首个单词，
    /// 会得到 `<!doctype` 这类"哈希"，虽然随后比对必然失败，但错误原因会被误报为"包被篡改"。
    public static func parseChecksum(_ text: String) -> String? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces).first ?? ""
        return normalizedSHA256(token)
    }

    /// 解析 GitHub Releases API 中资源的 `digest` 字段（形如 `sha256:<hash>`），返回小写哈希。
    ///
    /// 字段缺失（旧版发布没有）或算法不是 sha256 时返回 nil，调用方应回退到 .sha256 文件。
    public static func parseAssetDigest(_ digest: String?) -> String? {
        guard let digest = digest?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let prefix = "sha256:"
        guard digest.lowercased().hasPrefix(prefix) else { return nil }
        return normalizedSHA256(String(digest.dropFirst(prefix.count)))
    }

    /// 只接受 64 位 ASCII 十六进制，统一转小写
    private static func normalizedSHA256(_ token: String) -> String? {
        // isHexDigit 也认全角数字，额外限定 ASCII
        guard token.count == 64, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return token.lowercased()
    }
}

extension UpdateIntegrity {
    public enum SignatureFailure: Error, Equatable, LocalizedError {
        case candidateSignatureUnreadable
        case currentSignatureUnreadable
        case signatureMismatch

        public var errorDescription: String? {
            switch self {
            case .candidateSignatureUnreadable:
                return NSLocalizedString("无法读取更新包的代码签名，已拒绝安装", comment: "update error")
            case .currentSignatureUnreadable:
                return NSLocalizedString("无法读取当前应用的代码签名，已拒绝安装", comment: "update error")
            case .signatureMismatch:
                return NSLocalizedString("更新包的签名与当前版本不一致，已拒绝安装", comment: "update error")
            }
        }
    }

    /// 新版本主 App 与扩展必须满足的签名规则：与当前运行版本由同一张证书签发，且 bundle 标识不变。
    ///
    /// 只有当前版本是证书签名时才能使用（ad-hoc 签名没有证书可比对，见 CodeSignatureCheck.signatureStatus）。
    public static func signingRequirements(leafCertificateSHA1 leaf: String) -> (app: String, appex: String) {
        ("identifier \"\(IPCBridge.mainAppBundleIdentifier)\" and certificate leaf = H\"\(leaf)\"",
         "identifier \"\(IPCBridge.extensionBundleIdentifier)\" and certificate leaf = H\"\(leaf)\"")
    }

    /// 校验更新包签名与当前运行应用签名的兼容性与一致性。
    /// 集中处理签名策略：真正的签名有效性、标识、嵌套代码校验，以及读取失败时拒装。
    public static func verifyUpdateSignatures(candidateApp: URL, currentApp: URL) throws {
        let currentSig = CodeSignatureCheck.signatureStatus(ofCodeAt: currentApp)
        let candidateSig = CodeSignatureCheck.signatureStatus(ofCodeAt: candidateApp)

        guard currentSig != .unreadable else { throw SignatureFailure.currentSignatureUnreadable }
        guard candidateSig != .unreadable else { throw SignatureFailure.candidateSignatureUnreadable }

        if case .certificate(let leaf) = currentSig {
            let required = signingRequirements(leafCertificateSHA1: leaf)
            let syncAppex = candidateApp.appendingPathComponent("Contents/PlugIns/FinderRightSync.appex")
            guard CodeSignatureCheck.codeAt(candidateApp, satisfies: required.app),
                  CodeSignatureCheck.codeAt(syncAppex, satisfies: required.appex) else {
                throw SignatureFailure.signatureMismatch
            }
        }
    }
}
