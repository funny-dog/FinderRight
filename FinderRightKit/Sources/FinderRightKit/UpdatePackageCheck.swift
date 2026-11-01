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
    public static func validate(appAt appURL: URL, expectation: Expectation) throws {
        let expected = trimmingLeadingV(expectation.expectedVersion)
        let current = trimmingLeadingV(expectation.currentVersion)

        var versions: [(owner: String, version: String, build: String, system: String)] = []
        for path in bundlePaths {
            let bundle = path.isEmpty ? appURL : appURL.appendingPathComponent(path)
            let plist = bundle.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let version = dict["CFBundleShortVersionString"] as? String, !version.isEmpty,
                  let build = dict["CFBundleVersion"] as? String, !build.isEmpty else {
                throw Failure.inconsistentBundles(details: "\(path.isEmpty ? "FinderRight" : path) 缺少版本信息")
            }
            let system = dict["LSMinimumSystemVersion"] as? String ?? ""
            versions.append((path.isEmpty ? "FinderRight" : (path as NSString).lastPathComponent,
                             trimmingLeadingV(version), build, system))
        }

        // 1. 核对主程序版本与预期版本
        let mainVersion = versions[0].version
        guard mainVersion == expected else {
            throw Failure.versionMismatch(expected: expected, actual: mainVersion)
        }

        // 2. 核对各扩展版本是否与预期（主程序）版本一致；若有不一致，明确指出具体组件
        if let mismatched = versions.dropFirst().first(where: { $0.version != expected }) {
            let details = "\(mismatched.owner) 版本 \(mismatched.version)（预期 \(expected)）"
            throw Failure.inconsistentBundles(details: details)
        }

        // 3. 构建号一致性核对
        let mainBuild = versions[0].build
        guard versions.allSatisfy({ $0.build == mainBuild }) else {
            let details = versions.map { "\($0.owner) 构建号（\($0.build)）" }.joined(separator: "、")
            throw Failure.inconsistentBundles(details: details)
        }

        // 4. 版本是否高于当前版本
        guard VersionComparator.compareVersions(expected, current) == .orderedDescending else {
            throw Failure.notNewer(version: expected, current: current)
        }

        // 5. 最低系统要求
        for entry in versions where !entry.system.isEmpty {
            guard !version(expectation.operatingSystemVersion, isAtLeast: entry.system) else { continue }
            throw Failure.unsupportedSystem(required: entry.system, current: expectation.operatingSystemVersion)
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
}
