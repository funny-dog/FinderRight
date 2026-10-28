import Foundation

/// 更新包的校验和来源
public enum UpdateChecksum: Equatable, Sendable {
    /// Releases API 直接给出的 SHA-256：随检查更新的响应一起拿到，安装时无需再发请求
    case digest(String)
    /// 回退：发布里同名的 .sha256 文件（旧发布没有 digest 字段时使用）
    case file(URL)
}

/// 自动更新检查与安装的状态
public enum UpdateCheckStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, releaseURL: URL, downloadURL: URL?, checksum: UpdateChecksum? = nil)
    case downloading(progress: Double)
    case installing
    case failed(String)

    /// 检查、下载或安装正在进行
    public var isInProgress: Bool {
        switch self {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
}

/// 带可读描述的更新错误，供 Result 传递
public struct UpdateError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlUrl: String
    let assets: [GitHubReleaseAsset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadUrl: String
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case digest
    }
}

/// 自动更新纯逻辑（发布解析、地址映射、重试回退决策及下载超时决策）
public enum UpdatePolicy {
    public static let repoOwner = "funny-dog"
    public static let repoName = "FinderRight"
    public static let websiteOrigin = "https://finderright.erhuerhu.dpdns.org"
    public static let defaultReleaseAPI = URL(string: "https://api.github.com/repos/funny-dog/FinderRight/releases/latest")!

    /// 版本标签正则表达式（形如 v1.2.3）
    private static let tagRegex = "^v[0-9]+\\.[0-9]+\\.[0-9]+$"

    /// 双向映射仅限固定版本 ZIP 及其校验和；不允许任意 URL、查询串或 latest。
    public static func alternateAssetURL(for url: URL) -> URL? {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let tag: String
        let name: String
        let destination: String
        if url.host == "github.com", parts.count == 6,
           Array(parts.prefix(4)) == [repoOwner, repoName, "releases", "download"] {
            tag = parts[4]
            name = parts[5]
            destination = websiteOrigin + "/download"
        } else if url.host == URL(string: websiteOrigin)!.host, parts.count == 3, parts[0] == "download" {
            tag = parts[1]
            name = parts[2]
            destination = "https://github.com/\(repoOwner)/\(repoName)/releases/download"
        } else { return nil }
        guard tag.range(of: tagRegex, options: .regularExpression) != nil,
              name == "FinderRight-\(tag).zip" || name == "FinderRight-\(tag).zip.sha256" else { return nil }
        return URL(string: "\(destination)/\(tag)/\(name)")
    }

    /// 在允许回退时推导备用源 URL
    public static func fallbackAssetURL(for url: URL, allowFallback: Bool) -> URL? {
        guard allowFallback else { return nil }
        return alternateAssetURL(for: url)
    }

    /// 根据 Release 数据解析更新状态（纯逻辑）
    /// - Parameters:
    ///   - data: 接口返回的 JSON 数据
    ///   - viaWebsite: 是否来自官网镜像源
    ///   - currentVersion: 当前应用版本号（例如 "1.0"）
    /// - Returns: 计算后的更新状态（.updateAvailable 或 .upToDate）
    public static func releaseStatus(from data: Data, viaWebsite: Bool, currentVersion: String) throws -> UpdateCheckStatus {
        guard let release = try? JSONDecoder().decode(GitHubReleaseResponse.self, from: data) else {
            throw UpdateError("解析版本信息失败")
        }
        guard release.tagName.range(of: tagRegex, options: .regularExpression) != nil else {
            throw UpdateError("解析版本信息失败")
        }
        let tag = release.tagName
        let releaseURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/tag/\(tag)")!
        let name = "FinderRight-\(tag).zip"
        let githubZIP = URL(string: "https://github.com/\(repoOwner)/\(repoName)/releases/download/\(tag)/\(name)")!
        var downloadURL: URL?
        var checksum: UpdateChecksum?
        // 只接受本仓库、固定版本、精确同名的资产，备用源不重新查询 latest。
        if let assets = release.assets,
           let zip = assets.first(where: { $0.name == name && $0.browserDownloadUrl == githubZIP.absoluteString }) {
            if let hash = UpdateIntegrity.parseAssetDigest(zip.digest) {
                checksum = .digest(hash)
            } else if let sha = assets.first(where: {
                $0.name == name + ".sha256" && $0.browserDownloadUrl == githubZIP.absoluteString + ".sha256"
            }), let shaURL = URL(string: sha.browserDownloadUrl) {
                checksum = .file(viaWebsite ? alternateAssetURL(for: shaURL)! : shaURL)
            }
            if checksum != nil {
                downloadURL = viaWebsite ? alternateAssetURL(for: githubZIP)! : githubZIP
            }
        }
        return VersionComparator.compareVersions(tag, currentVersion) == .orderedDescending
            ? .updateAvailable(version: tag, releaseURL: releaseURL, downloadURL: downloadURL, checksum: checksum)
            : .upToDate
    }

    /// 检查更新的两路响应仲裁决策结果
    public enum CheckArbitrationDecision: Equatable {
        /// 检查已决出最终状态，应终止其他任务并更新状态
        /// recordSuccessDate: 是否应更新 lastCheckedDate
        case finish(status: UpdateCheckStatus, recordSuccessDate: Bool)
        /// 尚未决出最终状态，继续等待其余请求，并更新 fallback 暂存
        case waitForRemaining(fallback: UpdateCheckStatus?)
    }

    /// 评估单路检查返回后的仲裁纯决策
    /// - Parameters:
    ///   - result: 本次请求的结果
    ///   - currentFallback: 当前暂存的 fallback 状态
    ///   - remaining: 剩余尚未返回的请求数（包含本次已被扣减后的剩余数）
    /// - Returns: 仲裁决策结果
    public static func arbitrateCheck(
        result: Result<UpdateCheckStatus, Error>,
        currentFallback: UpdateCheckStatus?,
        remaining: Int
    ) -> CheckArbitrationDecision {
        switch result {
        case .success(let value):
            if case .updateAvailable(_, _, .some, .some) = value {
                return .finish(status: value, recordSuccessDate: true)
            } else {
                let updatedFallback: UpdateCheckStatus
                switch (currentFallback, value) {
                case (.updateAvailable(let saved, _, _, _), .updateAvailable(let incoming, _, _, _)):
                    updatedFallback = VersionComparator.compareVersions(incoming, saved) == .orderedDescending ? value : currentFallback!
                case (.updateAvailable, .upToDate):
                    updatedFallback = currentFallback!
                default:
                    updatedFallback = value
                }
                if remaining == 0 {
                    return .finish(status: updatedFallback, recordSuccessDate: true)
                } else {
                    return .waitForRemaining(fallback: updatedFallback)
                }
            }
        case .failure(let error):
            if remaining == 0 {
                if let fallback = currentFallback {
                    return .finish(status: fallback, recordSuccessDate: true)
                } else {
                    return .finish(status: .failed(error.localizedDescription), recordSuccessDate: false)
                }
            } else {
                return .waitForRemaining(fallback: currentFallback)
            }
        }
    }

    /// 判断是否应该复用缓存的更新状态（纯逻辑）
    /// - Parameters:
    ///   - currentStatus: 当前状态
    ///   - lastCheckedDate: 上次检查时间
    ///   - now: 当前时间
    ///   - force: 是否强制检查
    ///   - maxAge: 缓存有效期（默认 600 秒）
    public static func shouldReuseCachedStatus(
        currentStatus: UpdateCheckStatus,
        lastCheckedDate: Date?,
        now: Date = Date(),
        force: Bool,
        maxAge: TimeInterval = 600
    ) -> Bool {
        if force { return false }
        guard let last = lastCheckedDate, now.timeIntervalSince(last) < maxAge else { return false }
        switch currentStatus {
        case .upToDate, .updateAvailable:
            return true
        default:
            return false
        }
    }

    /// 构造更新检查的 HTTP 请求
    public static func makeCheckRequest(for url: URL, timeoutInterval: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutInterval)
        request.setValue("FinderRight-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        return request
    }
}

/// 下载超时与传输停滞的纯逻辑状态机
public struct DownloadTimeoutTracker: Sendable {
    public let firstByteTimeout: TimeInterval
    public let stallTimeout: TimeInterval
    private(set) public var isCompleted: Bool = false

    public init(firstByteTimeout: TimeInterval, stallTimeout: TimeInterval) {
        self.firstByteTimeout = firstByteTimeout
        self.stallTimeout = stallTimeout
    }

    /// 初始启动时决定的首字节等待超时时长
    public func initialTimeout() -> TimeInterval {
        firstByteTimeout
    }

    /// 收到数据时的决策结果
    public struct DataProgressDecision: Equatable {
        /// 是否需要重置定时器，若需要则附带新的停滞超时时长
        public let resetTimeoutInterval: TimeInterval?
        /// 进度（0.0 ~ 1.0），若预期大小未知则为 nil
        public let progress: Double?
    }

    /// 收到下载数据块时的纯决策
    public mutating func handleDataWritten(bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpected: Int64) -> DataProgressDecision? {
        guard !isCompleted else { return nil }
        let progress: Double?
        if totalBytesExpected > 0 {
            progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpected), 0.0), 1.0)
        } else {
            progress = nil
        }
        return DataProgressDecision(resetTimeoutInterval: stallTimeout, progress: progress)
    }

    /// 标记任务结束（返回 true 表示首次完成应处理结果并执行回调）
    public mutating func handleFinished() -> Bool {
        guard !isCompleted else { return false }
        isCompleted = true
        return true
    }
}
