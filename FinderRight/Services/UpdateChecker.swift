import Foundation
import AppKit

public enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, releaseURL: URL, downloadURL: URL?)
    case downloading(progress: Double)
    case installing
    case failed(String)
}

public final class UpdateChecker: NSObject {
    public static let shared = UpdateChecker()

    private let repoOwner = "funny-dog"
    private let repoName = "FinderRight"
    private(set) public var currentStatus: UpdateCheckStatus = .idle
    private var lastCheckedDate: Date?

    private var activeDownloadSession: URLSession?
    private var downloadDelegate: UpdateDownloadDelegate?

    private override init() {
        super.init()
    }

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

                // 寻找用于自动安装的 ZIP 安装包下载链接
                var downloadURL: URL?
                if let assets = release.assets {
                    if let zipAsset = assets.first(where: { $0.name.hasSuffix(".zip") }) {
                        downloadURL = URL(string: zipAsset.browserDownloadUrl)
                    }
                }

                DispatchQueue.main.async {
                    let status: UpdateCheckStatus
                    if isNewer {
                        status = .updateAvailable(version: remoteTag, releaseURL: releaseURL, downloadURL: downloadURL)
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

    /// 开始下载并自动安装更新
    public func startDownloadAndInstall(downloadURL: URL, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        let updateStatus = UpdateCheckStatus.downloading(progress: 0.0)
        self.currentStatus = updateStatus
        statusHandler(updateStatus)

        let delegate = UpdateDownloadDelegate(
            onProgress: { [weak self] progress in
                guard let self = self else { return }
                let status = UpdateCheckStatus.downloading(progress: progress)
                self.currentStatus = status
                statusHandler(status)
            },
            onFinish: { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let zipLocation):
                    let status = UpdateCheckStatus.installing
                    self.currentStatus = status
                    statusHandler(status)

                    DispatchQueue.global(qos: .userInitiated).async {
                        self.performInstallAndRelaunch(zipURL: zipLocation) { installError in
                            if let installError = installError {
                                DispatchQueue.main.async {
                                    let failedStatus = UpdateCheckStatus.failed("安装失败: \(installError.localizedDescription)")
                                    self.currentStatus = failedStatus
                                    statusHandler(failedStatus)
                                }
                            }
                        }
                    }

                case .failure(let error):
                    let failedStatus = UpdateCheckStatus.failed("下载失败: \(error.localizedDescription)")
                    self.currentStatus = failedStatus
                    statusHandler(failedStatus)
                }
            }
        )

        self.downloadDelegate = delegate
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: OperationQueue.main)
        self.activeDownloadSession = session

        var request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("FinderRight-App", forHTTPHeaderField: "User-Agent")
        let downloadTask = session.downloadTask(with: request)
        downloadTask.resume()
    }

    /// 解压、覆盖替换当前应用并重新拉起新版
    private func performInstallAndRelaunch(zipURL: URL, completion: @escaping (Error?) -> Void) {
        let fileManager = FileManager.default
        let baseDir = zipURL.deletingLastPathComponent()
        let extractDir = baseDir.appendingPathComponent("extracted")

        do {
            try fileManager.createDirectory(at: extractDir, withIntermediateDirectories: true)

            // 1. 解压 ZIP
            let unzipProc = Process()
            unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProc.arguments = ["-q", "-o", zipURL.path, "-d", extractDir.path]
            try unzipProc.run()
            unzipProc.waitUntilExit()

            guard unzipProc.terminationStatus == 0 else {
                throw NSError(domain: "UpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压更新包失败"])
            }

            // 2. 找到解压后的 FinderRight.app
            let newAppURL = extractDir.appendingPathComponent("FinderRight.app")
            guard fileManager.fileExists(atPath: newAppURL.path) else {
                throw NSError(domain: "UpdateChecker", code: 2, userInfo: [NSLocalizedDescriptionKey: "未在更新包中找到有效的 FinderRight.app"])
            }

            // 3. 确定目标路径：优先当前运行路径；若非 /Applications 且 /Applications 存在，则覆盖 /Applications
            var targetAppURL = Bundle.main.bundleURL
            if !targetAppURL.path.hasPrefix("/Applications") && fileManager.fileExists(atPath: "/Applications/FinderRight.app") {
                targetAppURL = URL(fileURLWithPath: "/Applications/FinderRight.app")
            }

            // 4. 清除解压产物的隔离属性（Quarantine）
            let xattrProc = Process()
            xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProc.arguments = ["-dr", "com.apple.quarantine", newAppURL.path]
            try? xattrProc.run()
            xattrProc.waitUntilExit()

            // 5. 编写后台替换与重启脚本
            let pid = ProcessInfo.processInfo.processIdentifier
            let scriptContent = """
            #!/bin/bash
            # 等待原进程退出
            while /bin/kill -0 \(pid) 2>/dev/null; do
                /bin/sleep 0.2
            done

            # 覆盖更新
            /bin/rm -rf "\(targetAppURL.path)"
            /bin/cp -R "\(newAppURL.path)" "\(targetAppURL.path)"

            # 确保清除隔离属性并刷新注册
            /usr/bin/xattr -dr com.apple.quarantine "\(targetAppURL.path)" 2>/dev/null || true
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\(targetAppURL.path)"

            # 重新打开新版
            /usr/bin/open "\(targetAppURL.path)"

            # 清理临时文件
            /bin/rm -rf "\(baseDir.path)"
            """

            let scriptURL = baseDir.appendingPathComponent("relaunch.sh")
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            // 6. 运行独立脚本
            let relaunchProc = Process()
            relaunchProc.executableURL = URL(fileURLWithPath: "/bin/bash")
            relaunchProc.arguments = [scriptURL.path]
            try relaunchProc.run()

            // 7. 退出当前进程以交接
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            completion(error)
        }
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

// MARK: - 下载进度与回调代理

private final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private let onFinish: (Result<URL, Error>) -> Void

    init(onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            DispatchQueue.main.async {
                self.onProgress(min(max(progress, 0.0), 1.0))
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = tempDir.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            DispatchQueue.main.async {
                self.onFinish(.success(destination))
            }
        } catch {
            DispatchQueue.main.async {
                self.onFinish(.failure(error))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.onFinish(.failure(error))
            }
        }
    }
}

// MARK: - 数据模型

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

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }
}
