import Foundation
import AppKit
import FinderRightKit

public final class UpdateChecker: NSObject {
    public static let shared = UpdateChecker()

    private let repoOwner = UpdatePolicy.repoOwner
    private let repoName = UpdatePolicy.repoName
    static let websiteOrigin = UpdatePolicy.websiteOrigin
    static let releaseAPI = UpdatePolicy.defaultReleaseAPI
    /// 状态变化后在主线程发出：菜单栏和关于页可能各自发起检查或更新，靠它保持显示一致
    public static let statusDidChangeNotification = Notification.Name("com.finderright.updateStatusDidChange")

    /// 状态、自动安装标记与回调统一在主线程维护；哈希、解压、验签等耗时工作放在后台，回来时切回主线程
    private(set) public var currentStatus: UpdateCheckStatus = .idle {
        didSet {
            guard currentStatus != oldValue else { return }
            NotificationCenter.default.post(name: Self.statusDidChangeNotification, object: self)
        }
    }
    private(set) var lastCheckedDate: Date?
    static let automaticUpdatesKey = "automaticallyCheckAndInstallUpdates"
    private let defaults: UserDefaults
    private let checkSession: URLSession
    private let downloadConfiguration: URLSessionConfiguration
    private let firstByteTimeout: TimeInterval
    private let stallTimeout: TimeInterval
    private let supplementalWindow: TimeInterval
    public typealias SupplementalScheduler = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void
    private let supplementalScheduler: SupplementalScheduler
    private var checkTasks: [URLSessionDataTask] = []
    private var cancelSupplementalTimer: (() -> Void)?
    private var checkGeneration = 0
    private var automaticUpdateTimer: Timer?
    private var automaticUpdateGeneration = 0
    /// 这次安装是不是定时触发的静默更新；与「是否因更新而退出」是两件事
    private(set) var isAutomaticInstall = false
    /// 已开始替换安装：此后进程只会因更新而退出，退出前同样要等在途文件任务
    private(set) var isInstallingUpdate = false

    private var activeDownloadSession: URLSession?
    private var downloadDelegate: UpdateDownloadDelegate?

    init(defaults: UserDefaults = .standard, checkSession: URLSession = .shared,
         downloadConfiguration: URLSessionConfiguration = .default,
         firstByteTimeout: TimeInterval = 3, stallTimeout: TimeInterval = 10,
         supplementalWindow: TimeInterval = UpdatePolicy.supplementalCheckWindow,
         supplementalScheduler: @escaping SupplementalScheduler = { delay, action in
             let item = DispatchWorkItem(block: action)
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
             return { item.cancel() }
         }) {
        self.defaults = defaults
        self.checkSession = checkSession
        self.downloadConfiguration = downloadConfiguration
        self.firstByteTimeout = firstByteTimeout
        self.stallTimeout = stallTimeout
        self.supplementalWindow = supplementalWindow
        self.supplementalScheduler = supplementalScheduler
        super.init()
    }

    /// 启动和偏好变更时调用；关闭后不再发起更新，已开始的安装流程继续完成。
    func configureAutomaticUpdates() {
        configureAutomaticUpdates(using: defaults)
    }

    /// 用指定偏好源配置自动更新（测试里用隔离的 UserDefaults，避免 .standard 残留影响）
    func configureAutomaticUpdates(using source: UserDefaults) {
        guard source.bool(forKey: Self.automaticUpdatesKey) else {
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
        check(automatic: true) { [weak self] status in
            guard let self, self.automaticUpdateGeneration == generation,
                  self.defaults.bool(forKey: Self.automaticUpdatesKey),
                  case .updateAvailable(_, _, .some, .some) = status else { return }
            self.installAutomaticUpdateWhenIdle(status, generation: generation)
        }
    }

    private func installAutomaticUpdateWhenIdle(_ status: UpdateCheckStatus, generation: Int) {
        guard defaults.bool(forKey: Self.automaticUpdatesKey), automaticUpdateGeneration == generation,
              currentStatus == status,
              case .updateAvailable(let version, _, let downloadURL?, let checksum?) = status else { return }
        guard FinderRightService.backgroundJobs.isIdle else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.installAutomaticUpdateWhenIdle(status, generation: generation)
            }
            return
        }
        startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum, version: version, automatically: true) { status in
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

    /// 两路检查已完成、不会再有回调：主动检查或结果已经过时
    /// 执行更新检查
    /// - Parameters:
    ///   - force: 是否强制刷新（默认十分钟内检查过则复用结果）
    ///   - automatic: 定时触发的静默检查
    ///   - completion: 主线程回调；只回调进行中状态与一次最终结果，不重放缓存结论——
    ///     旧结论的展示由界面读取缓存状态完成，否则菜单栏会把重放结果当最终结论重复弹窗
    public func check(force: Bool = false, automatic: Bool = false, completion: @escaping (UpdateCheckStatus) -> Void) {
        // 已有检查、下载或安装在进行时不再发起：避免重复请求，也避免把下载进度覆盖成「检查中」
        if currentStatus.isInProgress {
            completion(currentStatus)
            return
        }
        let policy = UpdatePolicy.requestPolicy(force: force, automatic: automatic, currentStatus: currentStatus,
                                                lastCheckedDate: lastCheckedDate)
        guard policy.force else {
            // 结论不旧就直接用；定时检查再在后台静默刷新
            completion(currentStatus)
            if policy.waitsForResult {
                // 后台刷新仍把最终结果交给调用方（例如 checkAutomatically 的自动安装回调）；
                // 这里不能再重复回调 completion（页面已用上面的缓存结论展示），
                // 但自动安装依赖拿到真正的最终状态，所以把 completion 传给 startCheck，
                // 由它在拿到新网络结果后回调一次。
                DispatchQueue.main.async { [weak self] in self?.startCheck(notify: completion) }
            }
            return
        }
        startCheck(notify: completion)
    }

    private func startCheck(notify: @escaping (UpdateCheckStatus) -> Void) {
        cancelSupplementalWindow()
        checkTasks.forEach { $0.cancel() }
        checkTasks.removeAll()
        checkGeneration += 1
        let generation = checkGeneration

        currentStatus = .checking
        notify(.checking)

        let sources = [Self.releaseAPI, URL(string: Self.websiteOrigin + "/update/latest.json")!]
        var remaining = sources.count
        var finished = false
        var fallback: UpdateCheckStatus?

        func finish(_ status: UpdateCheckStatus, recordSuccessDate: Bool) {
            guard !finished else { return }
            finished = true
            cancelSupplementalWindow()
            checkTasks.forEach { $0.cancel() }
            checkTasks.removeAll()
            if recordSuccessDate { lastCheckedDate = Date() }
            currentStatus = status
            notify(status)
        }

        // 首个「没有可安装新版」的结论之后，给另一渠道 800 毫秒补充窗口；
        // 窗口内先到的新版优先，窗口结束用已有结论收尾，两路都没有效结果则继续等各自超时。
        func scheduleSupplementalWindow() {
            guard cancelSupplementalTimer == nil, !finished, remaining > 0 else { return }
            cancelSupplementalTimer = supplementalScheduler(supplementalWindow) { [weak self] in
                guard let self, !finished, self.checkGeneration == generation else { return }
                self.cancelSupplementalTimer = nil
                switch UpdatePolicy.concludeSupplementalWindow(fallback: fallback) {
                case .finish(let status, let recordSuccessDate):
                    finish(status, recordSuccessDate: recordSuccessDate)
                case .waitForRemaining:
                    break
                }
            }
        }

        checkTasks = sources.map { source in
            let request = UpdatePolicy.makeCheckRequest(for: source)
            return checkSession.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    guard let self, !finished, self.checkGeneration == generation else { return }
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
                    // 结果可安装就直接完成；否则把 fallback 交给仲裁，由补充等待窗口决定何时收尾
                    switch UpdatePolicy.arbitrateCheck(result: result, currentFallback: fallback, remaining: remaining) {
                    case .finish(let status, let recordSuccessDate):
                        finish(status, recordSuccessDate: recordSuccessDate)
                    case .waitForRemaining(let newFallback):
                        fallback = newFallback
                        if remaining > 0 { scheduleSupplementalWindow() }
                    }
                }
            }
        }
        checkTasks.forEach { $0.resume() }
    }

    private func cancelSupplementalWindow() {
        cancelSupplementalTimer?()
        cancelSupplementalTimer = nil
    }

    /// 开始下载并自动安装更新
    /// - Parameter version: 检查更新时得到的版本，会一路带到安装前的核对
    public func startDownloadAndInstall(downloadURL: URL, checksum: UpdateChecksum?, version: String,
                                        automatically: Bool = false,
                                        statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        guard !currentStatus.isInProgress else { return }
        isAutomaticInstall = automatically

        // 安装会替换整个 App 并以原有的完全磁盘访问 / 辅助功能权限重启，未经校验的包一律拒装；
        // 先判定再进入下载状态，缺校验和时不会留下一个假的「下载中 0%」
        guard let checksum else {
            NSLog("[UpdateChecker] 拒绝安装：发布中缺少校验和")
            fail(NSLocalizedString("更新包缺少校验和文件，已取消自动安装，请前往发布页手动下载", comment: "update error"), statusHandler: statusHandler)
            return
        }

        let updateStatus = UpdateCheckStatus.downloading(progress: 0.0)
        currentStatus = updateStatus
        statusHandler(updateStatus)

        switch checksum {
        case .digest(let hash):
            downloadPackage(downloadURL: downloadURL, expectedHash: hash, version: version, statusHandler: statusHandler)
        case .file(let sha256URL):
            // 先拿校验和再下 ZIP：校验和拿不到就不必下载，也不会白白丢掉一个已下好的包
            fetchChecksum(from: sha256URL) { [weak self] result in
                guard let self = self else { return }
                switch result {
                case .success(let hash):
                    self.downloadPackage(downloadURL: downloadURL, expectedHash: hash, version: version, statusHandler: statusHandler)
                case .failure(let error):
                    self.fail(error.localizedDescription, statusHandler: statusHandler)
                }
            }
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

    private func downloadPackage(downloadURL: URL, expectedHash: String, version: String, allowFallback: Bool = true,
                                 statusHandler: @escaping (UpdateCheckStatus) -> Void) {
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
                    self.verifyAndInstall(zipLocation: zipLocation, expectedHash: expectedHash,
                                          version: version, statusHandler: statusHandler)

                case .failure(let error):
                    if let alternate = UpdatePolicy.fallbackAssetURL(for: downloadURL, allowFallback: allowFallback) {
                        self.downloadPackage(downloadURL: alternate, expectedHash: expectedHash, version: version,
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

    private func verifyAndInstall(zipLocation: URL, expectedHash: String, version: String,
                                  statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        // 哈希放到后台算，不占主线程
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let actualHash = try FileHasher.hexDigest(reading: zipLocation, algorithm: .sha256)
                guard actualHash == expectedHash else {
                    try? FileManager.default.removeItem(at: zipLocation.deletingLastPathComponent())
                    DispatchQueue.main.async { self.fail("更新包校验失败: SHA256 不匹配", statusHandler: statusHandler) }
                    return
                }
            } catch {
                DispatchQueue.main.async { self.fail("计算更新包哈希失败: \(error.localizedDescription)", statusHandler: statusHandler) }
                return
            }

            self.proceedToInstall(zipLocation: zipLocation, version: version, statusHandler: statusHandler)
        }
    }

    /// 在主线程调用：记录并上报失败状态
    private func fail(_ message: String, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        isAutomaticInstall = false
        isInstallingUpdate = false
        let failed = UpdateCheckStatus.failed(message)
        currentStatus = failed
        statusHandler(failed)
    }

    private func proceedToInstall(zipLocation: URL, version: String, statusHandler: @escaping (UpdateCheckStatus) -> Void) {
        // 状态与通知只在主线程维护：这里从哈希校验的后台队列进入，切回主线程再发布安装状态
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let status = UpdateCheckStatus.installing
            self.currentStatus = status
            statusHandler(status)
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            self.performInstallAndRelaunch(zipURL: zipLocation, version: version) { installError in
                if let installError = installError {
                    DispatchQueue.main.async {
                        self.fail("安装失败: \(installError.localizedDescription)", statusHandler: statusHandler)
                    }
                }
            }
        }
    }

    /// 解压更新包，返回解压出的 App 位置；只认顶层 FinderRight.app，损坏或不完整的包按失败处理
    static func extractUpdatePackage(from zipURL: URL, into baseDir: URL) throws -> URL {
        let extractDir = baseDir.appendingPathComponent("FinderRight.app", isDirectory: true)
        let unzipProc = Process()
        unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzipProc.arguments = ["-q", "-o", zipURL.path, "-d", baseDir.path]
        try unzipProc.run()
        unzipProc.waitUntilExit()
        guard unzipProc.terminationStatus == 0, FileManager.default.fileExists(atPath: extractDir.path) else {
            throw NSError(domain: "UpdateChecker", code: 1, userInfo: [NSLocalizedDescriptionKey: "解压更新包失败"])
        }
        return extractDir
    }

    /// 解压并核对安装包，然后编写替换脚本并退出当前进程；能提前做的事都在退出前做完
    private func performInstallAndRelaunch(zipURL: URL, version: String, completion: @escaping (Error?) -> Void) {
        let fileManager = FileManager.default
        let baseDir = zipURL.deletingLastPathComponent()

        func cleanupAndFail(_ error: Error) {
            try? fileManager.removeItem(at: baseDir)
            completion(error)
        }

        do {
            // 1. 解压：发布包顶层是 FinderRight.app/，全量解出后再逐项校验。
            //    不要按文件名挑选条目——ZIP 里目录条目常带尾斜杠，按名字匹配会漏掉主程序
            let extractDir = try Self.extractUpdatePackage(from: zipURL, into: baseDir)

            // 2. 验签：集中签名策略（有效性、标识、嵌套代码、同证书约束，读取失败即拒装）
            try UpdateIntegrity.verifyUpdateSignatures(candidateApp: extractDir, currentApp: Bundle.main.bundleURL)

            // 3. 版本、四个 bundle 的一致性、系统要求：检查到的版本必须一路对得上
            let expectation = UpdatePackageCheck.Expectation(expectedVersion: version, currentVersion: currentAppVersion,
                                                             operatingSystemVersion: Self.operatingSystemVersionString())
            try UpdatePackageCheck.validate(appAt: extractDir, expectation: expectation)

            // 4. 确定目标路径：优先当前运行路径；若非 /Applications 且 /Applications 存在，则覆盖 /Applications
            var targetAppURL = Bundle.main.bundleURL
            if !targetAppURL.path.hasPrefix("/Applications") && fileManager.fileExists(atPath: "/Applications/FinderRight.app") {
                targetAppURL = URL(fileURLWithPath: "/Applications/FinderRight.app")
            }
            guard !targetAppURL.isSameFileLayout(as: extractDir) else {
                cleanupAndFail(NSError(domain: "UpdateChecker", code: 5, userInfo: [NSLocalizedDescriptionKey: "更新包与目标位置冲突"]))
                return
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
                cleanupAndFail(NSError(domain: "UpdateChecker", code: 3, userInfo: [NSLocalizedDescriptionKey: errMsg]))
                return
            }

            // 5. 清除解压产物的隔离属性（Quarantine）
            let xattrProc = Process()
            xattrProc.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattrProc.arguments = ["-dr", "com.apple.quarantine", extractDir.path]
            try? xattrProc.run()
            xattrProc.waitUntilExit()

            // 6. 生成替换脚本，动态值一律走位置参数，不拼进脚本文本
            let scriptURL = baseDir.appendingPathComponent("relaunch.sh")
            try Self.relaunchScript().write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            // 7. 运行独立脚本；安装已交接，此后进程只因更新而退出
            let relaunchProc = Process()
            relaunchProc.executableURL = URL(fileURLWithPath: "/bin/bash")
            relaunchProc.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                                      targetAppURL.path, extractDir.path,
                                      UpdatePackageCheck.trimmingLeadingV(version),
                                      isAutomaticInstall ? "auto" : "manual"]
            relaunchProc.environment = relaunchEnvironment(targetDirectory: targetDir.path)
            do {
                try relaunchProc.run()
            } catch {
                cleanupAndFail(error)
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.isInstallingUpdate = true
                ApplicationTermination.request()
            }
        } catch {
            cleanupAndFail(error)
        }
    }

    /// 替换脚本要展示的失败文案（已本地化）与重启参数，全部经环境变量传入，不拼进脚本
    func relaunchEnvironment(targetDirectory: String) -> [String: String] {
        func text(_ key: String) -> String {
            NSLocalizedString(key, comment: "update error")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["FR_COPY_FAILED"] = text("复制新版本到临时目录失败")
        environment["FR_BACKUP_FAILED"] = text("备份旧版本失败")
        environment["FR_MOVE_FAILED_ROLLED_BACK"] = text("移动新版本到目标目录失败，已回滚旧版本")
        environment["FR_MOVE_FAILED_STUCK"] = String(format: text("移动新版本到目标目录失败，回滚旧版本也失败，旧版本保留在 %@/FinderRight.old.app"), targetDirectory)
        environment["FR_LAUNCH_FAILED"] = text("新版启动失败")
        environment["FR_LAUNCH_FAILED_ROLLED_BACK"] = text("新版启动失败，已恢复旧版本")
        environment["FR_LAUNCH_FAILED_KEPT_BACKUP"] = String(format: text("新版启动失败，旧版本备份保留在 %@/FinderRight.old.app"), targetDirectory)
        environment["FR_VERSION_MISMATCH"] = text("更新包缺少版本信息，已放弃替换，原版本保持不变")
        environment["FR_VERSION_MISMATCH_DETAIL"] = text("更新包版本与检查到的版本不一致，已放弃替换，原版本保持不变")
        environment["FR_UPDATE_SUSPENDED"] = String(format: text("上次更新尚未完成确认，本次更新已暂停；旧版本备份保留在 %@/FinderRight.old.app，打开 FinderRight 完成确认后会自动清理"), targetDirectory)
        environment["FR_LAUNCH_ARG"] = isAutomaticInstall ? LaunchPresentation.backgroundArgument : LaunchPresentation.showSettingsArgument
        return environment
    }

    /// 仅测试与集成脚本使用：把上次检查时间设为指定值，模拟「结论已过期」
    func setLastCheckedDateForTesting(_ date: Date?) {
        lastCheckedDate = date
    }

    /// 当前系统版本字符串（如 "13.6.1"）
    static func operatingSystemVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// 替换脚本：$1 旧进程 PID，$2 目标 App，$3 新版本 App，$4 预期版本，$5 auto/manual。
    ///
    /// 失败文案先本地化再通过环境变量传入——脚本在 App 退出后独立运行，无法调用 NSLocalizedString，
    /// 写进 last-update-error.txt 的内容会由下次启动的 checkLastUpdateError 原样展示。
    /// 脚本不删除旧版备份：由新版启动后经 `ApplicationSupport/FinderRight/update-pending.plist` 回执确认，
    /// 见 `UpdateInstallReceipt`。任何一步失败都尽量恢复旧版，并把真实结果写进错误文件。
    static func relaunchScript() -> String {
        """
        #!/bin/bash
        # 用法：relaunch.sh <旧进程 PID> <目标 App> <新版本 App> <预期版本> <auto|manual>
        set -u
        # 失败文案由 App 先本地化，经环境变量传入；脚本独立运行时调不到 NSLocalizedString
        COPY_FAILED="${FR_COPY_FAILED:-Failed to copy the new version to a temporary location}"
        BACKUP_FAILED="${FR_BACKUP_FAILED:-Failed to back up the old version}"
        MOVE_FAILED_ROLLED_BACK="${FR_MOVE_FAILED_ROLLED_BACK:-Failed to move the new version into place; the old version was restored}"
        MOVE_FAILED_STUCK="${FR_MOVE_FAILED_STUCK:-Failed to move the new version into place; restoring the old version also failed}"
        LAUNCH_FAILED="${FR_LAUNCH_FAILED:-The new version failed to launch}"
        LAUNCH_FAILED_ROLLED_BACK="${FR_LAUNCH_FAILED_ROLLED_BACK:-The new version failed to launch; the old version was restored}"
        LAUNCH_FAILED_KEPT_BACKUP="${FR_LAUNCH_FAILED_KEPT_BACKUP:-The new version failed to launch; the backup of the old version was kept}"
        VERSION_MISMATCH="${FR_VERSION_MISMATCH:-The update package has no version; the current version is unchanged}"
        VERSION_MISMATCH_DETAIL="${FR_VERSION_MISMATCH_DETAIL:-The update package version does not match the expected version; the current version is unchanged}"
        UPDATE_SUSPENDED="${FR_UPDATE_SUSPENDED:-update suspended: the previous update has not been confirmed yet}"
        PID="$1"
        TARGET="$2"
        NEW_APP="$3"
        EXPECTED="$4"
        LAUNCH_MODE="$5"
        TARGET_DIR="$(dirname "$TARGET")"
        OLD_APP="$TARGET_DIR/FinderRight.old.app"
        NEW_STAGE="$TARGET_DIR/FinderRight.new.app"
        FAILED_APP="$TARGET_DIR/FinderRight.failed.app"
        BASE_DIR="$(dirname "$NEW_APP")"
        STATE_DIR="$HOME/Library/Application Support/FinderRight"
        ERROR_LOG="$STATE_DIR/last-update-error.txt"
        RECEIPT="$STATE_DIR/update-pending.plist"
        # lsregister 不在 PATH：生产环境退回系统绝对路径；测试经 PATH 提供替身，避免触碰真实注册表
        LSREGISTER="$(command -v lsregister 2>/dev/null || true)"
        if [ -z "$LSREGISTER" ]; then
            LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        fi

        mkdir -p "$STATE_DIR"

        finish() {
            rm -rf "$BASE_DIR"
        }

        fail() {
            echo "$1" > "$ERROR_LOG"
            echo "[relaunch.sh] $1" >&2
        }

        launch_old() {
            open -g -a "$TARGET" >/dev/null 2>&1 || true
        }

        while kill -0 "$PID" 2>/dev/null; do
            sleep 0.2
        done

        # 上一轮的暂存与失败副本只属于上一轮，直接清掉；未确认的旧版备份不能动
        rm -rf "$NEW_STAGE" "$FAILED_APP"

        # 回执还在、备份已经不在：回执唯一的职责是保护备份，这时它已无事可做，清掉过期回执
        if [ -f "$RECEIPT" ] && [ ! -d "$OLD_APP" ]; then
            rm -f "$RECEIPT"
        fi

        # 上次失败的回滚把目标留空、备份还在：先把旧版放回目标位置，再继续本次安装
        if [ ! -d "$TARGET" ] && [ -d "$OLD_APP" ]; then
            mv "$OLD_APP" "$TARGET" || true
        fi

        # 仍有未确认的旧版备份：mv 到已存在的目录会把当前 App 嵌套进去、破坏恢复布局，
        # 所以停止本次安装。打开一次新版完成确认（自动清备份）或手动删除备份后即可重试
        if [ -d "$OLD_APP" ]; then
            fail "${UPDATE_SUSPENDED:-update suspended}"
            launch_old
            finish
            exit 1
        fi

        # 先核对解压出的版本与检查到的版本：不对就不进入替换，绝不让旧版离开原位
        ACTUAL="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$NEW_APP/Contents/Info.plist" 2>/dev/null)"
        if [ -z "$ACTUAL" ] || [ "$ACTUAL" != "$EXPECTED" ]; then
            if [ -n "$ACTUAL" ]; then
                fail "${VERSION_MISMATCH_DETAIL:-update package version mismatch}: $ACTUAL != $EXPECTED"
            else
                fail "${VERSION_MISMATCH:-update package has no version}"
            fi
            rm -rf "$NEW_STAGE"
            launch_old
            finish
            exit 1
        fi

        if ! cp -R "$NEW_APP" "$NEW_STAGE"; then
            fail "${COPY_FAILED:-copy failed}"
            rm -rf "$NEW_STAGE"
            launch_old
            finish
            exit 1
        fi

        if [ -d "$TARGET" ] && ! mv "$TARGET" "$OLD_APP"; then
            # 目标被挪走后备份才失败：旧版还在备份位，先放回目标再报告，不能把用户留在空位上
            if [ ! -d "$TARGET" ] && [ -d "$OLD_APP" ]; then
                mv "$OLD_APP" "$TARGET" || true
            fi
            fail "${BACKUP_FAILED:-backup failed}"
            rm -rf "$NEW_STAGE"
            launch_old
            finish
            exit 1
        fi

        # 只有 mv 明确失败才算失败：mv 成功时暂存位置本来就该消失
        if ! mv "$NEW_STAGE" "$TARGET"; then
            if [ ! -d "$OLD_APP" ] || mv "$OLD_APP" "$TARGET"; then
                fail "${MOVE_FAILED_ROLLED_BACK:-move failed; old version restored}"
            else
                fail "${MOVE_FAILED_STUCK:-move failed; old version kept as FinderRight.old.app}"
            fi
            rm -rf "$NEW_STAGE"
            launch_old
            finish
            exit 1
        fi

        xattr -dr com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true
        "$LSREGISTER" -f "$TARGET" >/dev/null 2>&1 || true
        rm -f "$ERROR_LOG"

        # 旧版备份保留到新版完成初始化并回执；回执由新版启动时删除
        # 用 plutil 结构化写入，避免路径含 & 或 < 时破坏 XML 格式
        if plutil -create xml1 "$RECEIPT" \
            && plutil -insert version -string "$EXPECTED" "$RECEIPT" \
            && plutil -insert backup -string "$OLD_APP" "$RECEIPT" \
            && plutil -insert installedAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RECEIPT"; then
            :
        else
            # 回执写入失败：记录但不中止，清掉损坏的回执继续启动新版；
            # 备份只能手动清理，下一次更新遇到旧备份会停止并提示
            rm -f "$RECEIPT"
            echo "[relaunch.sh] warning: failed to write receipt, backup must be cleaned manually" >&2
        fi

        # 先结束仍在运行的旧版 FinderSync 扩展进程：App 包已被替换，需由系统按新包重新拉起
        killall FinderRightSync >/dev/null 2>&1 || true
        if [ "$LAUNCH_MODE" = "auto" ]; then
            launch=(-g -a)
        else
            launch=(-a)
        fi
        if ! open "${launch[@]}" "$TARGET" --args "${FR_LAUNCH_ARG:-}"; then
            # 启动命令明确失败：目标位置是刚换上来的新版，要先挪开才能把旧版放回原位；
            # 恢复不成时如实说明新版在哪、旧版备份在哪，回执一并作废
            rm -f "$RECEIPT"
            if [ -d "$TARGET" ] && ! mv "$TARGET" "$FAILED_APP"; then
                fail "${LAUNCH_FAILED:-new version failed to launch}"
            elif [ -d "$OLD_APP" ] && mv "$OLD_APP" "$TARGET"; then
                fail "${LAUNCH_FAILED_ROLLED_BACK:-new version failed to launch; old version restored}"
            elif [ -d "$OLD_APP" ]; then
                fail "${LAUNCH_FAILED_KEPT_BACKUP:-new version failed to launch; old version backup kept}"
            else
                fail "${LAUNCH_FAILED:-new version failed to launch}"
            fi
            launch_old
            finish
            exit 1
        fi

        finish
        exit 0
        """
    }
}

private extension URL {
    /// 两个路径互为父子或相同（同一条替换链上不能既当源又当目标）
    func isSameFileLayout(as other: URL) -> Bool {
        let a = standardizedFileURL.path
        let b = other.standardizedFileURL.path
        return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
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
