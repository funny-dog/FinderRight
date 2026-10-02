import Foundation

/// IPC 传入的 bundle identifier 校验（防注入）：非空、不超过 128 字符，仅限字母、数字、点、横线与下划线
public enum BundleIdentifier {

    private static let allowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    public static func isValid(_ bundleId: String) -> Bool {
        guard !bundleId.isEmpty, bundleId.count <= 128 else { return false }
        return bundleId.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
