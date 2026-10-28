import Foundation
import AppKit
import CryptoKit
import FinderRightKit

public final class UpdateChecker: NSObject {
    public static let shared = UpdateChecker()

    private let repoOwner = UpdatePolicy.repoOwner
    private let repoName = UpdatePolicy.repoName
    static let websiteOrigin = UpdatePolicy.websiteOrigin
    static let releaseAPI = UpdatePolicy.defaultReleaseAPI
    /// 状态变化后在主线程发出：菜单栏和关于页可能各自发起检查或更新，靠它保持显示一致
    public static let statusDidChangeNotification = Notification.Name("com.finderright.updateStatusDidChange")

    private(set) public var currentStatus: UpdateCheckStatus = .idle {
        didSet {
            guard currentStatus != oldValue else { return }
            // 部分状态在后台线程写入，通知统一回到主线程发出
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
            }
        }
    }
    private var lastCheckedDate: Date?
    static let automaticUpdatesKey = "automaticallyCheckAndInstallUpdates"
    private let defaults: UserDefaults
    private let checkSession: URLSession
    private let downloadConfiguration: URLSessionConfiguration
    private let firstByteTimeout: TimeInterval
    private let stallTimeout: TimeInterval
    private var checkTasks: [URLSessionDataTask] = []
    private var automaticUpdateTimer: Timer?
    private var automaticUpdateGeneration = 0
    private(set) var isAutomaticInstall = false

    private var activeDownloadSession: URLSession?
    private var downloadDelegate: UpdateDownloadDelegate?

    init(defaults: UserDefaults = .standard, checkSession: URLSession = .shared,
         downloadConfiguration: URLSessionConfiguration = .default,
         firstByteTimeout: TimeInterval = 3, stallTimeout: TimeInterval = 10) {
        self.defaults = defaults
        self.checkSession = checkSession
        self.downloadConfiguration = downloadConfiguration
        self.firstByteTimeout = firstByteTimeout
        self.stallTimeout = stallTimeout
        super.init()
    }

    /// 启动和偏好变更时调用；关闭后不再发起更新，已开始的安装流程继续完成。
    func configureAutomaticUpdates() {
        guard defaults.bool(forKey: Self.automaticUpdatesKey) else {
            if automaticUpdateTimer != nil { automaticUpdateGeneration += 1 }
            automaticUpdateTimer?.invalidate()
            automaticUpdateTimer = nil
            return
        }
        guard automaticUpdateTimer == nil else { return }
        automaticUpdateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.checkAutomatically()
        }
        // 避免在 UserDefaults 的同步通知中重入更新检查。
        DispatchQueue.main.async { [weak self] in self?.checkAutomatically() }
    }

    private func checkAutomatically() {
        guard defaults.bool(forKey: Self.automaticUpdatesKey), !currentStatus.isInProgress else { return }
        let generation = automaticUpdateGeneration
        check(force: true) { [weak self] status in
            guard let self, self.automaticUpdateGeneration == generation,
                  self.defaults.bool(forKey: Self.automaticUpdatesKey),
                  case .updateAvailable(_, _, .some, .some) = status else { return }
            self.installAutomaticUpdateWhenIdle(status, generation: generation)
        }
    }

    private func installAutomaticUpdateWhenIdle(_ status: UpdateCheckStatus, generation: Int) {
        guard defaults.bool(forKey: Self.automaticUpdatesKey), automaticUpdateGeneration == generation,
              currentStatus == status,
              case .updateAvailable(_, _, let downloadURL?, let checksum?) = status else { return }
        guard FinderRightService.backgroundJobs.isIdle else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.installAutomaticUpdateWhenIdle(status, generation: generation)
            }
            return
        }
        startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum, automatically: true) { status in
            if case .failed(let message) = status { NSLog("[UpdateChecker] 自动更新失败：%@", message) }
        }
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
        // 已有检查、下载或安装在进行时不再发起：避免重复请求，也避免把下载进度覆盖成「检查中」
        if currentStatus.isInProgress {
            completion(currentStatus)
            return
        }
        if UpdatePolicy.shouldReuseCachedStatus(currentStatus: currentStatus, lastCheckedDate: lastCheckedDate, force: force) {
            completion(currentStatus)
            return
        }

        currentStatus = .checking
        completion(.checking)

        let sources = [Self.releaseAPI, URL(string: Self.websiteOrigin + "/update/latest.json")!]
        // 可安装的新版本立即生效；旧缓存或缺少校验信息的响应等待另一渠道，再作为回退。
        var remaining = sources.count
        var finished = false
        var fallback: UpdateCheckStatus?
        checkTasks = sources.map { source in
            let request = UpdatePolicy.makeCheckRequest(for: source)
            return checkSession.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self, !finished else { return }
                    let result: Result<UpdateCheckStatus, Error>
                    do {
                        if let error { throw error }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                            throw UpdateError(code == 403 ? NSLocalizedString("更新请求超限，请稍后再试", comment: "update error") : "检查失败 (\(code))")
                        }
                        guard let data else { throw UpdateError("未接收到数据") }
                        result = .success(try UpdatePolicy.releaseStatus(from: data, viaWebsite: source != Self.releaseAPI, currentVersion: self.currentAppVersion))
                    } catch {
                        result = .failure(error)
                    }
                    remaining -= 1
                    let decision = UpdatePolicy.arbitrateCheck(result: result, currentFallback: fallback, remaining: remaining)
                    switch decision {
                    case .finish(let status, let recordSuccessDate):
                        finished = true
                        if recordSuccessDate {
                            self.lastCheckedDate = Date()
                        }
                        self.checkTasks.forEach { $0.cancel() }
                        self.checkTasks.removeAll()
                        self.currentStatus = status
                        completion(status)
                    case .waitForRemaining(let newFallback):
                        fallback = newFallback
                    }
                }
            }
        }
        checkTasks.forEach { $0.resume() }
    }

    /// 双向映射仅限固定版本 ZIP 及其校验和；不允许任意 URL、查询串或 latest。
    static func alternateAssetURL(for url: URL) -> URL? {
        UpdatePolicy.alternateAssetURL(for: url)
    }

    /// 开始下载并自动安装更新
    public func startDownloadAndInstall(downloadURL: URL, checksum: UpdateChecksum?, automatically: Bool = false,
                                        statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        guard !currentStatus.isInProgress else { return }
        isAutomaticInstall = automatically
        let updateStatus = UpdateCheckStatus.downloading(progress: 0.0)
        self.currentStatus = updateStatus
        statusHandler(updateStatus)

        // 安装会替换整个 App 并以原有的完全磁盘访问 / 辅助功能权限重启，未经校验的包一律拒装
        switch checksum {
        case .digest(let hash):
            downloadPackage(downloadURL: downloadURL, expectedHash: hash, statusHandler: statusHandler)
        case .file(let sha256URL):
            // 先拿校验和再下 ZIP：校验和拿不到就不必下载，也不会白白丢掉一个已下好的包
            fetchChecksum(from: sha256URL) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let hash):
                    self.downloadPackage(downloadURL: downloadURL, expectedHash: hash, statusHandler: statusHandler)
                case .failure(let error):
                    self.fail(error.localizedDescription, statusHandler: statusHandler)
                }
            }
        case nil:
            NSLog("[UpdateChecker] 拒绝安装：发布中缺少校验和")
            fail(NSLocalizedString("更新包缺少校验和文件，已取消自动安装，请前往发布页手动下载", comment: "update error"), statusHandler: statusHandler)
        }
    }

    /// 拉取固定版本的校验和，失败后切换同一文件的备用源；回调在主线程。
    private func fetchChecksum(from url: URL, allowFallback: Bool = true, completion: @escaping (Result<String, Error>) -> Void) {
        var shaReq = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        shaReq.setValue("FinderRight-App", forHTTPHeaderField: "User-Agent")
        checkSession.dataTask(with: shaReq) { [weak self] data, response, error in
            let result: Result<String, Error>
            if let error = error {
                result = .failure(UpdateError("校验和下载失败: \(error.localizedDescription)"))
            } else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(UpdateError("校验和下载失败 (HTTP \(http.statusCode))"))
            } else if let data = data,
                      let text = String(data: data, encoding: .utf8),
                      let hash = UpdateIntegrity.parseChecksum(text) {
                result = .success(hash)
            } else {
                result = .failure(UpdateError("无法解析校验和文件"))
            }

            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .failure = result, let alternate = UpdatePolicy.fallbackAssetURL(for: url, allowFallback: allowFallback) {
                    self.fetchChecksum(from: alternate, allowFallback: false, completion: completion)
                    return
                }
                completion(result)
            }
        }.resume()
    }

    private func downloadPackage(downloadURL: URL, expectedHash: String, allowFallback: Bool = true, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        let delegate = UpdateDownloadDelegate(
            onProgress: { [weak self] progress in
                guard let self = self else { return }
                let status = UpdateCheckStatus.downloading(progress: progress)
                self.currentStatus = status
                statusHandler(status)
            },
            onFinish: { [weak self] result in
                guard let self = self else { return }
                self.activeDownloadSession?.invalidateAndCancel()
                self.activeDownloadSession = nil
                self.downloadDelegate = nil
                switch result {
                case .success(let zipLocation):
                    self.verifyAndInstall(zipLocation: zipLocation, expectedHash: expectedHash, statusHandler: statusHandler)

                case .failure(let error):
                    if let alternate = UpdatePolicy.fallbackAssetURL(for: downloadURL, allowFallback: allowFallback) {
                        self.downloadPackage(downloadURL: alternate, expectedHash: expectedHash,
                                             allowFallback: false, statusHandler: statusHandler)
                        return
                    }
                    self.fail("下载失败: \(error.localizedDescription)", statusHandler: statusHandler)
                }
            }
        )

        self.downloadDelegate = delegate
        let session = URLSession(configuration: downloadConfiguration, delegate: delegate, delegateQueue: OperationQueue.main)
        self.activeDownloadSession = session

        var request = URLRequest(url: downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: stallTimeout)
        request.setValue("FinderRight-App", forHTTPHeaderField: "User-Agent")
        let downloadTask = session.downloadTask(with: request)
        delegate.watch(downloadTask, firstByteTimeout: firstByteTimeout, stallTimeout: stallTimeout)
        downloadTask.resume()
    }

    private func verifyAndInstall(zipLocation: URL, expectedHash: String, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        // 哈希放到后台算，不占主线程
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let zipData = try Data(contentsOf: zipLocation)
                let actualHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
                guard actualHash == expectedHash else {
                    try? FileManager.default.removeItem(at: zipLocation.deletingLastPathComponent())
                    DispatchQueue.main.async { self.fail("更新包校验失败: SHA256 不匹配", statusHandler: statusHandler) }
                    return
                }
            } catch {
                DispatchQueue.main.async { self.fail("计算更新包哈希失败: \(error.localizedDescription)", statusHandler: statusHandler) }
                return
            }

            self.proceedToInstall(zipLocation: zipLocation, statusHandler: statusHandler)
        }
    }

    /// 在主线程调用：记录并上报失败状态
    private func fail(_ message: String, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        isAutomaticInstall = false
        let failed = UpdateCheckStatus.failed(message)
        currentStatus = failed
        statusHandler(failed)
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
                        self.fail("安装失败: \(installError.localizedDescription)", statusHandler: statusHandler)
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

            // 2.5 验签：新版本（主 App 与扩展）必须与当前运行版本由同一张证书签发、标识不变。
            //     SHA-256 只能证明下载没损坏；发布渠道本身被冒用时，只有签名能挡住。
            //     当前版本若是 ad-hoc 签名（过渡期，没有证书可比对），只能依赖前面的 SHA-256 校验。
            if let leaf = CodeSignatureCheck.leafCertificateSHA1(ofCodeAt: Bundle.main.bundleURL) {
                let required = UpdateIntegrity.signingRequirements(leafCertificateSHA1: leaf)
                let newAppex = newAppURL.appendingPathComponent("Contents/PlugIns/FinderRightSync.appex")
                guard CodeSignatureCheck.codeAt(newAppURL, satisfies: required.app),
                      CodeSignatureCheck.codeAt(newAppex, satisfies: required.appex) else {
                    throw NSError(domain: "UpdateChecker", code: 4, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("更新包的签名与当前版本不一致，已拒绝安装", comment: "update error")])
                }
            } else {
                NSLog("[UpdateChecker] 当前版本为 ad-hoc 签名，无证书可比对，仅依赖 SHA-256 校验")
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
                    if !self.isAutomaticInstall, let releaseURL = URL(string: "https://github.com/\(self.repoOwner)/\(self.repoName)/releases/latest") {
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
            // 失败文案先本地化再注入脚本：relaunch.sh 在 App 退出后独立运行，无法调用
            // NSLocalizedString，写进 last-update-error.txt 的内容会由下次启动的
            // checkLastUpdateError 弹窗原样展示，所以这里必须已经本地化。
            // 注意：这三条译文不能含 " $ ` \ 等 shell 元字符（会破坏脚本）。
            let errCopyFailed = NSLocalizedString("复制新版本到临时目录失败", comment: "update error")
            let errBackupFailed = NSLocalizedString("备份旧版本失败", comment: "update error")
            let errMoveFailed = NSLocalizedString("移动新版本到目标目录失败，已回滚旧版本", comment: "update error")
            let relaunchArgument = isAutomaticInstall ? LaunchPresentation.backgroundArgument : LaunchPresentation.showSettingsArgument
            let openOptions = isAutomaticInstall ? "-g -a" : "-a"
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
                echo "\(errCopyFailed)" > "$ERROR_LOG"
                /bin/rm -rf "$NEW_APP"
                # 主进程此刻已 terminate，不重新拉起用户的 App 就凭空消失；旧版仍在 $TARGET 原位
                /usr/bin/open "$TARGET" 2>/dev/null || true
                exit 1
            fi

            # 2. 成功后 mv 旧 App 到备份位置
            if ! /bin/mv "$TARGET" "$OLD_APP"; then
                echo "\(errBackupFailed)" > "$ERROR_LOG"
                /bin/rm -rf "$NEW_APP"
                /usr/bin/open "$TARGET" 2>/dev/null || true
                exit 1
            fi

            # 3. mv 新的到位
            if ! /bin/mv "$NEW_APP" "$TARGET"; then
                echo "\(errMoveFailed)" > "$ERROR_LOG"
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
            /usr/bin/open \(openOptions) "$TARGET" --args \(relaunchArgument)

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

final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private let onFinish: (Result<URL, Error>) -> Void
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private var tracker: DownloadTimeoutTracker
    private var timeout: DispatchWorkItem?

    init(onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void,
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { interval, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
         }) {
        self.tracker = DownloadTimeoutTracker(firstByteTimeout: 3, stallTimeout: 10)
        self.onProgress = onProgress
        self.onFinish = onFinish
        self.schedule = schedule
        super.init()
    }

    func watch(_ task: URLSessionDownloadTask, firstByteTimeout: TimeInterval, stallTimeout: TimeInterval) {
        self.tracker = DownloadTimeoutTracker(firstByteTimeout: firstByteTimeout, stallTimeout: stallTimeout)
        scheduleTimeout(for: task, after: tracker.initialTimeout())
    }

    private func scheduleTimeout(for task: URLSessionDownloadTask, after interval: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self, weak task] in
            guard let self, !self.tracker.isCompleted else { return }
            task?.cancel()
            self.finish(.failure(URLError(.timedOut)))
        }
        timeout = work
        schedule(interval, work)
    }

    private func finish(_ result: Result<URL, Error>) {
        guard tracker.handleFinished() else { return }
        timeout?.cancel()
        timeout = nil
        onFinish(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let decision = tracker.handleDataWritten(bytesWritten: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite) else { return }
        if let resetInterval = decision.resetTimeoutInterval {
            scheduleTimeout(for: downloadTask, after: resetInterval)
        }
        if let progress = decision.progress {
            onProgress(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !tracker.isCompleted else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = tempDir.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
