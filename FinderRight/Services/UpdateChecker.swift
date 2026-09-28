import Foundation
import AppKit

public enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, releaseURL: URL)
    case failed(String)
}

public final class UpdateChecker {
    public static let shared = UpdateChecker()

    private let repoOwner = "funny-dog"
    private let repoName = "FinderRight"
    private(set) public var currentStatus: UpdateCheckStatus = .idle
    private var lastCheckedDate: Date?

    private init() {}

    /// 当前本地版本号（例如 "1.1.4"）
    public var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// 当前本地构建版本号（例如 "6"）
    public var currentBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    /// 执行更新检查
    /// - Parameters:
    ///   - force: 是否强制刷新（默认若 10 分钟内检查过，则复用结果）
    ///   - completion: 检查完成后的主线程回调
    public func check(force: Bool = false, completion: @escaping (UpdateCheckStatus) -> Void) {
        if !force, let last = lastCheckedDate, Date().timeIntervalSince(last) < 600, currentStatus != .idle {
            completion(currentStatus)
            return
        }

        currentStatus = .checking
        completion(.checking)

        guard let apiURL = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            let status = UpdateCheckStatus.failed("无效的请求地址")
            self.currentStatus = status
            completion(status)
            return
        }

        var request = URLRequest(url: apiURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("FinderRight-App", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    let status = UpdateCheckStatus.failed(error.localizedDescription)
                    self.currentStatus = status
                    self.lastCheckedDate = Date()
                    completion(status)
                }
                return
            }

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                DispatchQueue.main.async {
                    let msg = httpResp.statusCode == 403 ? "GitHub 请求超限，请稍后再试" : "检查失败 (\(httpResp.statusCode))"
                    let status = UpdateCheckStatus.failed(msg)
                    self.currentStatus = status
                    self.lastCheckedDate = Date()
                    completion(status)
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    let status = UpdateCheckStatus.failed("未接收到数据")
                    self.currentStatus = status
                    self.lastCheckedDate = Date()
                    completion(status)
                }
                return
            }

            do {
                let release = try JSONDecoder().decode(GitHubReleaseResponse.self, from: data)
                let remoteTag = release.tagName
                let isNewer = UpdateChecker.compareVersions(remoteTag, self.currentAppVersion) == .orderedDescending

                let fallbackURL = URL(string: "https://github.com/\(self.repoOwner)/\(self.repoName)/releases/latest")!
                let releaseURL = URL(string: release.htmlUrl) ?? fallbackURL

                DispatchQueue.main.async {
                    let status: UpdateCheckStatus
                    if isNewer {
                        status = .updateAvailable(version: remoteTag, releaseURL: releaseURL)
                    } else {
                        status = .upToDate
                    }
                    self.currentStatus = status
                    self.lastCheckedDate = Date()
                    completion(status)
                }
            } catch {
                DispatchQueue.main.async {
                    let status = UpdateCheckStatus.failed("解析版本信息失败")
                    self.currentStatus = status
                    self.lastCheckedDate = Date()
                    completion(status)
                }
            }
        }

        task.resume()
    }

    /// 比较两个版本字符串（例如 "v1.1.5" vs "1.1.4"）
    /// 返回 .orderedDescending 表示 v1 > v2
    public static func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        let parts1 = clean1.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        let parts2 = clean2.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }

        let maxCount = max(parts1.count, parts2.count)
        for i in 0..<maxCount {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return .orderedAscending }
            if p1 > p2 { return .orderedDescending }
        }
        return .orderedSame
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
    }
}
