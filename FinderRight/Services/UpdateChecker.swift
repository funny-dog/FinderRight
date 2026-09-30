import Foundation
import AppKit
import CryptoKit
import FinderRightKit

public enum UpdateCheckStatus: Equatable {
    case idle
    case checking
    case upToDate
    case updateAvailable(version: String, releaseURL: URL, downloadURL: URL?, sha256URL: URL? = nil)
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
                    completion(status)
                }
                return
            }

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode != 200 {
                DispatchQueue.main.async {
                    let msg = httpResp.statusCode == 403 ? "GitHub 请求超限，请稍后再试" : "检查失败 (\(httpResp.statusCode))"
                    let status = UpdateCheckStatus.failed(msg)
                    self.currentStatus = status
                    completion(status)
                }
                return
            }

            guard let data = data else {
                DispatchQueue.main.async {
                    let status = UpdateCheckStatus.failed("未接收到数据")
                    self.currentStatus = status
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

                // 寻找用于自动安装的 ZIP 安装包下载链接及可选的 SHA256 校验文件
                var downloadURL: URL?
                var sha256URL: URL?
                if let assets = release.assets {
                    if let zipAsset = assets.first(where: { $0.name.hasSuffix(".zip") }) {
                        downloadURL = URL(string: zipAsset.browserDownloadUrl)
                        let expectedShaName = zipAsset.name + ".sha256"
                        if let shaAsset = assets.first(where: { $0.name == expectedShaName || $0.name.hasSuffix(".zip.sha256") }) {
                            sha256URL = URL(string: shaAsset.browserDownloadUrl)
                        }
                    }
                }

                DispatchQueue.main.async {
                    let status: UpdateCheckStatus
                    if isNewer {
                        status = .updateAvailable(version: remoteTag, releaseURL: releaseURL, downloadURL: downloadURL, sha256URL: sha256URL)
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
                    completion(status)
                }
            }
        }

        task.resume()
    }

    /// 开始下载并自动安装更新
    public func startDownloadAndInstall(downloadURL: URL, sha256URL: URL? = nil, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
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
                    self.verifyAndInstall(zipLocation: zipLocation, sha256URL: sha256URL, statusHandler: statusHandler)

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

    private func verifyAndInstall(zipLocation: URL, sha256URL: URL?, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        if let sha256URL = sha256URL {
            var shaReq = URLRequest(url: sha256URL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            shaReq.setValue("FinderRight-App", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: shaReq) { [weak self] data, _, error in
                guard let self = self else { return }
                if let error = error {
                    DispatchQueue.main.async {
                        let failed = UpdateCheckStatus.failed("校验和下载失败: \(error.localizedDescription)")
                        self.currentStatus = failed
                        statusHandler(failed)
                    }
                    return
                }

                guard let data = data,
                      let shaText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let expectedHash = shaText.components(separatedBy: .whitespaces).first?.lowercased(),
                      !expectedHash.isEmpty else {
                    DispatchQueue.main.async {
                        let failed = UpdateCheckStatus.failed("无法解析校验和文件")
                        self.currentStatus = failed
                        statusHandler(failed)
                    }
                    return
                }

                do {
                    let zipData = try Data(contentsOf: zipLocation)
                    let actualHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                    if actualHash != expectedHash {
                        DispatchQueue.main.async {
                            let failed = UpdateCheckStatus.failed("更新包校验失败: SHA256 不匹配")
                            self.currentStatus = failed
                            statusHandler(failed)
                        }
                        return
                    }
                } catch {
                    DispatchQueue.main.async {
                        let failed = UpdateCheckStatus.failed("计算更新包哈希失败: \(error.localizedDescription)")
                        self.currentStatus = failed
                        statusHandler(failed)
                    }
                    return
                }

                self.proceedToInstall(zipLocation: zipLocation, statusHandler: statusHandler)
            }.resume()
        } else {
            // TODO: v1.2.0 起强制要求校验和
            NSLog("[UpdateChecker] 警告: 未找到 .sha256 校验和文件，跳过校验 (向后兼容)")
            proceedToInstall(zipLocation: zipLocation, statusHandler: statusHandler)
        }
    }

    private func proceedToInstall(zipLocation: URL, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        let status = UpdateCheckStatus.installing
        self.currentStatus = status
        DispatchQueue.main.async {
            statusHandler(status)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
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

            // 检查目标路径及其父目录的写权限
            let targetDir = targetAppURL.deletingLastPathComponent()
            let isTargetWritable = fileManager.isWritableFile(atPath: targetAppURL.path)
            let isParentWritable = fileManager.isWritableFile(atPath: targetDir.path)
            if (fileManager.fileExists(atPath: targetAppURL.path) && !isTargetWritable) || !isParentWritable {
                let errMsg = "无权限写入 \(targetAppURL.path)，请手动下载安装"
                DispatchQueue.main.async {
                    if let releaseURL = URL(string: "https://github.com/\(self.repoOwner)/\(self.repoName)/releases/latest") {
                        NSWorkspace.shared.open(releaseURL)
                    }
                }
                throw NSError(domain: "UpdateChecker", code: 3, userInfo: [NSLocalizedDescriptionKey: errMsg])
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

            TARGET="\(targetAppURL.path)"
            TARGET_DIR="$(dirname "$TARGET")"
            NEW_APP="$TARGET_DIR/FinderRight.new.app"
            OLD_APP="$TARGET_DIR/FinderRight.old.app"
            ERROR_LOG="$HOME/Library/Application Support/FinderRight/last-update-error.txt"

            /bin/mkdir -p "$(dirname "$ERROR_LOG")"

            # 清理历史可能残留的临时文件
            /bin/rm -rf "$NEW_APP" "$OLD_APP"

            # 1. 先复制到同目录临时位置
            if ! /bin/cp -R "\(newAppURL.path)" "$NEW_APP"; then
                echo "复制新版本到临时目录失败" > "$ERROR_LOG"
                /bin/rm -rf "$NEW_APP"
                # 主进程此刻已 terminate，不重新拉起用户的 App 就凭空消失；旧版仍在 $TARGET 原位
                /usr/bin/open "$TARGET" 2>/dev/null || true
                exit 1
            fi

            # 2. 成功后 mv 旧 App 到备份位置
            if ! /bin/mv "$TARGET" "$OLD_APP"; then
                echo "备份旧版本失败" > "$ERROR_LOG"
                /bin/rm -rf "$NEW_APP"
                /usr/bin/open "$TARGET" 2>/dev/null || true
                exit 1
            fi

            # 3. mv 新的到位
            if ! /bin/mv "$NEW_APP" "$TARGET"; then
                echo "移动新版本到目标目录失败，已回滚旧版本" > "$ERROR_LOG"
                # 若移动失败则将旧 App 回滚到位
                /bin/mv "$OLD_APP" "$TARGET"
                /bin/rm -rf "$NEW_APP"
                /usr/bin/open "$TARGET" 2>/dev/null || true
                exit 1
            fi

            # 4. 成功后清理 .old 备份
            /bin/rm -rf "$OLD_APP"

            # 确保清除隔离属性并刷新注册
            /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" 2>/dev/null || true

            # 重新打开新版
            # 先结束仍在运行的旧版 FinderSync 扩展进程：App 包已被替换，
            # 残留的旧扩展进程仍指向已删除的旧包，需由系统按新包重新拉起
            /usr/bin/killall FinderRightSync 2>/dev/null || true
            /usr/bin/open "$TARGET"

            # 清理下载解压临时文件
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
        VersionComparator.compareVersions(v1, v2)
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
