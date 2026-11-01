import Foundation

/// 解压后、替换前的安装包校验：版本、四个 bundle 的一致性、系统要求与签名状态。
///
/// 这些检查都发生在主 App 退出之前，失败时新版根本没有落盘，用户看到的错误也就是真实结果。
public enum UpdatePackageCheck {
    public enum Signature: Equatable {
        /// 证书签名的代码对应的叶子证书 SHA-1 指纹
        case certificate(leafSHA1: String)
        case adHoc
        /// 读不到签名信息（未签名或读取失败）：不能据此放行
        case unreadable
    }

    /// 更新包里的四个 bundle，各自 Info.plist 必须版本一致
    public static let bundlePaths = [
        "",
        "Contents/PlugIns/FinderRightSync.appex",
        "Contents/PlugIns/FinderRightPreview.appex",
        "Contents/PlugIns/FinderRightMarkdown.appex",
    ]

    public struct Expectation: Equatable {
        /// 检查更新时拿到的版本（形如 v1.2.3），必须一直带到安装阶段
        public let expectedVersion: String
        /// 当前运行版本
        public let currentVersion: String
        /// 当前系统版本，用于核对最低系统要求
        public let operatingSystemVersion: String

        public init(expectedVersion: String, currentVersion: String, operatingSystemVersion: String) {
            self.expectedVersion = expectedVersion
            self.currentVersion = currentVersion
            self.operatingSystemVersion = operatingSystemVersion
        }
    }

    public enum Failure: Error, Equatable, LocalizedError {
        case versionMismatch(expected: String, actual: String)
        case notNewer(version: String, current: String)
        case inconsistentBundles(details: String)
        case unsupportedSystem(required: String, current: String)
        case signatureUnreadable
        case currentSignatureUnreadable
        case signatureMismatch

        public var errorDescription: String? {
            switch self {
            case .versionMismatch(let expected, let actual):
                return "更新包版本 \(actual) 与预期版本 \(expected) 不一致，已拒绝安装"
            case .notNewer(let version, let current):
                return "更新包版本 \(version) 不高于当前版本 \(current)，已拒绝安装"
            case .inconsistentBundles(let details):
                return "更新包内各组件的版本不一致（\(details)），已拒绝安装"
            case .unsupportedSystem(let required, let current):
                return "更新包要求 macOS \(required)，当前系统为 \(current)，已拒绝安装"
            case .signatureUnreadable:
                return "无法读取更新包的签名信息，已拒绝安装"
            case .currentSignatureUnreadable:
                return "无法读取当前应用的签名信息，已拒绝安装，请重新安装 FinderRight 后再更新"
            case .signatureMismatch:
                return "更新包的签名与当前版本不一致，已拒绝安装"
            }
        }
    }

    public static func trimmingLeadingV(_ version: String) -> String {
        if version.hasPrefix("v") || version.hasPrefix("V") { return String(version.dropFirst()) }
        return version
    }

    /// 检查解压后的新版本 App 包
    /// - Parameters:
    ///   - appURL: 解压出的 FinderRight.app
    ///   - expectation: 版本与系统预期
    ///   - signature: 新包主 App 的签名状态（由调用方用 CodeSignatureCheck 读取）
    ///   - currentSignature: 当前运行版本的签名状态
    public static func validate(appAt appURL: URL, expectation: Expectation,
                                signature: Signature, currentSignature: Signature) throws {
        // 签名读取失败不能降级为「只校验 SHA-256」：候选包与当前应用任一侧读不到都拒装——
        // 否则「当前应用读取失败 → 没有证书可比对」就成了绕过同证书约束的口子
        guard signature != .unreadable else { throw Failure.signatureUnreadable }
        guard currentSignature != .unreadable else { throw Failure.currentSignatureUnreadable }

        let expected = trimmingLeadingV(expectation.expectedVersion)
        let current = trimmingLeadingV(expectation.currentVersion)

        var versions: [(owner: String, version: String, build: String, system: String)] = []
        for path in bundlePaths {
            let bundle = path.isEmpty ? appURL : appURL.appendingPathComponent(path)
            let plist = bundle.appendingPathComponent("Contents/Info.plist")
            guard let version = versionString(inPlistAt: plist, key: "CFBundleShortVersionString"),
                  let build = versionString(inPlistAt: plist, key: "CFBundleVersion") else {
                throw Failure.inconsistentBundles(details: "\(path.isEmpty ? "FinderRight" : path) 缺少版本信息")
            }
            let system = versionString(inPlistAt: plist, key: "LSMinimumSystemVersion") ?? ""
            versions.append((path.isEmpty ? "FinderRight" : (path as NSString).lastPathComponent,
                             trimmingLeadingV(version), build, system))
        }

        guard versions.allSatisfy({ $0.version == expected }) else {
            throw Failure.versionMismatch(expected: expected, actual: versions.first?.version ?? "")
        }
        guard versions.allSatisfy({ $0.version == versions[0].version && $0.build == versions[0].build }) else {
            let details = versions.map { "\($0.owner) 版本 \($0.version)（\($0.build)）" }.joined(separator: "、")
            throw Failure.inconsistentBundles(details: details)
        }
        guard VersionComparator.compareVersions(expected, current) == .orderedDescending else {
            throw Failure.notNewer(version: expected, current: current)
        }
        for entry in versions where !entry.system.isEmpty {
            guard !version(expectation.operatingSystemVersion, isAtLeast: entry.system) else { continue }
            throw Failure.unsupportedSystem(required: entry.system, current: expectation.operatingSystemVersion)
        }
        // 签名要求维持既有范围并明确收紧：当前证书签名时，新版本必须由同一张证书签发；
        // 当前是 ad-hoc（过渡期，没有证书可比对）时仍只依赖 SHA-256，但不允许借 ad-hoc 换成另一张证书的构建。
        if case .certificate(let leaf) = currentSignature {
            guard case .certificate(let newLeaf) = signature, newLeaf == leaf else {
                throw Failure.signatureMismatch
            }
        }
    }

    /// 比较点分版本，`system` 为空或无法解析时视为兼容
    public static func version(_ current: String, isAtLeast required: String) -> Bool {
        guard !required.isEmpty else { return true }
        let lhs = numericParts(current)
        let rhs = numericParts(required)
        guard !rhs.isEmpty else { return true }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return true
    }

    private static func numericParts(_ text: String) -> [Int] {
        text.split(separator: ".").map { Int($0) ?? 0 }
    }

    private static func versionString(inPlistAt url: URL, key: String) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let value = plist[key] as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
