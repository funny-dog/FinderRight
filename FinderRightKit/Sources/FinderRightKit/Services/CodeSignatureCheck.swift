import Foundation
import Security
import CryptoKit

/// 代码签名校验工具（基于 Security 框架）。
///
/// 两处安全决策依赖它：
/// - 自动更新：新版本必须与当前运行版本由同一张证书签发（见 UpdateIntegrity.signingRequirements）；
/// - IPC 来源：只受理本 App 内嵌的 FinderSync 扩展发来的 finderright:// 请求。
public enum CodeSignatureCheck {

    /// 磁盘上的代码（.app / .appex / 可执行文件）的签名规则（designated requirement）文本；
    /// 未签名或无法读取时返回 nil
    public static func designatedRequirement(ofCodeAt url: URL) -> String? {
        guard let code = staticCode(at: url) else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    /// 磁盘上的代码签名完好（含嵌套代码与全部架构），且满足给定的签名规则
    public static func codeAt(_ url: URL, satisfies requirementText: String) -> Bool {
        guard let code = staticCode(at: url) else { return false }
        var requirement: SecRequirement?
        // requirement 为 nil 时 Check 函数只验签名完好、不验是谁签的，必须解包后再用，保证失败即拒绝
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// 叶子证书的 SHA-1 指纹（大写十六进制，40 位）；ad-hoc 签名没有证书，返回 nil。
    /// 用 SHA-1 是因为 codesign 的 `certificate leaf = H"…"` 规则本身就以 SHA-1 表示证书
    public static func leafCertificateSHA1(ofCodeAt url: URL) -> String? {
        guard let code = staticCode(at: url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as NSDictionary?)?[kSecCodeInfoCertificates] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    /// 由 audit token 标识的运行中进程，是否满足磁盘上 bundleURL 处代码自己的签名规则。
    ///
    /// ad-hoc 签名时规则是 cdhash，证书签名时是「标识 + 证书指纹」，两种情况都能准确认出
    /// 「正在运行的就是磁盘上这份代码」，无需预先写死任何指纹。
    public static func process(auditToken: Data, satisfiesDesignatedRequirementOf bundleURL: URL) -> Bool {
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &guest) == errSecSuccess, let guest,
              let onDisk = staticCode(at: bundleURL) else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(onDisk, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(guest, [], requirement) == errSecSuccess
    }

    private static func staticCode(at url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess else { return nil }
        return code
    }
}
