import Foundation
import CryptoKit
import FinderRightKit

// 真实更新器、隔离偏好和模拟网络；仅使用无效更新包，不会替换或重启应用。
enum FinderRightService {
    static let backgroundJobs = BackgroundJobs()
}

private final class ReleaseProtocol: URLProtocol {
    enum Reply {
        case hold
        case failure
        case response(Int, Data)
    }
    static var requests: [URL] = []
    static var cancelled: [URL] = []
    static var replies: [String: Reply] = [:]
    static var withChecksum = false
    static var withChecksumFile = false
    static var pending: [ReleaseProtocol] = []
    private var stopped = false

    static let githubZIP = URL(string: "https://github.com/funny-dog/FinderRight/releases/download/v9999.0.0/FinderRight-v9999.0.0.zip")!
    static let websiteZIP = URL(string: UpdateChecker.websiteOrigin + "/download/v9999.0.0/FinderRight-v9999.0.0.zip")!
    static let hash = String(repeating: "a", count: 64)

    static func release(tag: String = "v9999.0.0", zipURL: URL = githubZIP) -> Data {
        let digest = withChecksum ? ",\"digest\":\"sha256:\(hash)\"" : ""
        let sha = withChecksumFile ? ",{\"name\":\"FinderRight-v9999.0.0.zip.sha256\",\"browser_download_url\":\"\(githubZIP.absoluteString).sha256\"}" : ""
        return Data("""
        {"tag_name":"\(tag)","html_url":"https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
         "assets":[{"name":"FinderRight-v9999.0.0.zip","browser_download_url":"\(zipURL.absoluteString)"\(digest)}\(sha)]}
        """.utf8)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.async {
            guard !self.stopped, let url = self.request.url else { return }
            Self.requests.append(url)
            let isRelease = url == UpdateChecker.releaseAPI || url.path == "/update/latest.json"
            let reply = Self.replies[url.absoluteString] ?? (isRelease ? .response(200, Self.release()) : .failure)
            switch reply {
            case .hold: Self.pending.append(self)
            case .failure: self.client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            case .response(let code, let data): self.respond(code: code, data: data)
            }
        }
    }
    override func stopLoading() {
        DispatchQueue.main.async {
            self.stopped = true
            if let url = self.request.url { Self.cancelled.append(url) }
        }
    }
    func respond(code: Int = 200, data: Data? = nil) {
        guard !stopped else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Self.release())
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct AutomaticUpdateChecks {
    static func main() {
        let websiteAPI = URL(string: UpdateChecker.websiteOrigin + "/update/latest.json")!
        func pump(_ seconds: TimeInterval = 0.02) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { pump() }
            precondition(condition(), "等待更新状态超时")
        }
        func availableURL(_ checker: UpdateChecker) -> URL? {
            if case .updateAvailable(_, _, let url, _) = checker.currentStatus { return url }
            return nil
        }
        func isAvailable(_ checker: UpdateChecker) -> Bool {
            if case .updateAvailable = checker.currentStatus { return true }
            return false
        }
        func isFailed(_ checker: UpdateChecker) -> Bool {
            if case .failed = checker.currentStatus { return true }
            return false
        }
        func scenario(_ name: String, _ body: (UpdateChecker, UserDefaults) -> Void) {
            let suite = "FinderRight.AutomaticUpdateTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ReleaseProtocol.self]
            let session = URLSession(configuration: config)
            let checker = UpdateChecker(defaults: defaults, checkSession: session, downloadConfiguration: config,
                                        firstByteTimeout: 0.1, stallTimeout: 0.1)
            ReleaseProtocol.requests = []
            ReleaseProtocol.cancelled = []
            ReleaseProtocol.replies = [:]
            ReleaseProtocol.withChecksum = false
            ReleaseProtocol.withChecksumFile = false
            ReleaseProtocol.pending = []
            body(checker, defaults)
            defaults.set(false, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            session.invalidateAndCancel()
            pump()
            defaults.removePersistentDomain(forName: suite)
            print("✓ \(name)")
        }
        func holdBoth() {
            ReleaseProtocol.replies[UpdateChecker.releaseAPI.absoluteString] = .hold
            ReleaseProtocol.replies[websiteAPI.absoluteString] = .hold
        }

        scenario("默认关闭不请求；手动检查同时启动两路") { checker, _ in
            checker.configureAutomaticUpdates()
            pump()
            precondition(checker.currentStatus == .idle && ReleaseProtocol.requests.isEmpty)
            ReleaseProtocol.withChecksum = true
            holdBoth()
            checker.check(force: true) { _ in }
            wait { ReleaseProtocol.pending.count == 2 }
            precondition(Set(ReleaseProtocol.requests) == [UpdateChecker.releaseAPI, websiteAPI])
            ReleaseProtocol.pending[0].respond()
            wait { isAvailable(checker) }
            precondition(!checker.isAutomaticInstall)
        }
        for (winner, expected) in [(websiteAPI, ReleaseProtocol.websiteZIP), (UpdateChecker.releaseAPI, ReleaseProtocol.githubZIP)] {
            scenario("首个有效响应选择渠道并取消另一请求：\(winner.host!)") { checker, _ in
                ReleaseProtocol.withChecksum = true
                holdBoth()
                var completions = 0
                checker.check(force: true) { if $0 != .checking { completions += 1 } }
                wait { ReleaseProtocol.pending.count == 2 }
                ReleaseProtocol.pending.first { $0.request.url == winner }!.respond()
                wait { availableURL(checker) == expected }
                let loser = winner == websiteAPI ? UpdateChecker.releaseAPI : websiteAPI
                wait { ReleaseProtocol.cancelled.contains(loser) }
                precondition(completions == 1)
                checker.check { _ in }
                precondition(ReleaseProtocol.requests.count == 2)
            }
        }
        for first in [websiteAPI, UpdateChecker.releaseAPI] {
            scenario("旧版本或不完整信息不能抢先结束检查：\(first.host!)") { checker, _ in
                holdBoth()
                var completions = 0
                checker.check(force: true) { if $0 != .checking { completions += 1 } }
                wait { ReleaseProtocol.pending.count == 2 }
                ReleaseProtocol.pending.first { $0.request.url == first }!.respond(
                    data: ReleaseProtocol.release(tag: "v0.0.0"))
                pump()
                precondition(checker.currentStatus == .checking && completions == 0)
                ReleaseProtocol.withChecksum = true
                ReleaseProtocol.pending.first { $0.request.url != first }!.respond()
                wait { availableURL(checker) != nil }
                precondition(completions == 1)
            }
            scenario("缺少校验和继续等待可安装结果：\(first.host!)") { checker, _ in
                holdBoth()
                checker.check(force: true) { _ in }
                wait { ReleaseProtocol.pending.count == 2 }
                ReleaseProtocol.pending.first { $0.request.url == first }!.respond()
                pump()
                precondition(checker.currentStatus == .checking)
                ReleaseProtocol.withChecksum = true
                ReleaseProtocol.pending.first { $0.request.url != first }!.respond()
                let expected = first == websiteAPI ? ReleaseProtocol.githubZIP : ReleaseProtocol.websiteZIP
                wait { availableURL(checker) == expected }
            }
        }
        for tag in ["v0.0.0", "v9999.0.0"] {
            scenario("另一渠道失败时保留有效结果：\(tag)") { checker, _ in
                holdBoth()
                checker.check(force: true) { _ in }
                wait { ReleaseProtocol.pending.count == 2 }
                ReleaseProtocol.pending[0].respond(data: ReleaseProtocol.release(tag: tag))
                pump()
                precondition(checker.currentStatus == .checking)
                ReleaseProtocol.pending[1].respond(code: 503)
                wait { checker.currentStatus != .checking }
                precondition(tag == "v0.0.0" ? checker.currentStatus == .upToDate : isAvailable(checker))
                let requests = ReleaseProtocol.requests.count
                checker.check { _ in }
                pump()
                precondition(ReleaseProtocol.requests.count == requests)
            }
        }
        for secondTag in ["v0.0.0", "v9998.0.0", "v9999.0.1"] {
            scenario("回退保留较新的版本提示：\(secondTag)") { checker, _ in
                holdBoth()
                checker.check(force: true) { _ in }
                wait { ReleaseProtocol.pending.count == 2 }
                ReleaseProtocol.pending[0].respond()
                pump()
                ReleaseProtocol.pending[1].respond(data: ReleaseProtocol.release(tag: secondTag))
                wait { isAvailable(checker) }
                guard case .updateAvailable(let version, _, nil, nil) = checker.currentStatus else { preconditionFailure() }
                precondition(version == (secondTag == "v9999.0.1" ? secondTag : "v9999.0.0"))
            }
        }
        scenario("两路均无新版本时才确认最新") { checker, _ in
            holdBoth()
            checker.check(force: true) { _ in }
            wait { ReleaseProtocol.pending.count == 2 }
            ReleaseProtocol.pending[0].respond(data: ReleaseProtocol.release(tag: "v0.0.0"))
            pump()
            precondition(checker.currentStatus == .checking)
            ReleaseProtocol.pending[1].respond(data: ReleaseProtocol.release(tag: "v0.0.0"))
            wait { checker.currentStatus == .upToDate }
        }
        scenario("成功后强制检查失败，普通检查仍可立即重试") { checker, _ in
            ReleaseProtocol.withChecksum = true
            checker.check { _ in }
            wait { isAvailable(checker) }
            ReleaseProtocol.replies[websiteAPI.absoluteString] = .failure
            ReleaseProtocol.replies[UpdateChecker.releaseAPI.absoluteString] = .failure
            checker.check(force: true) { _ in }
            wait { isFailed(checker) }
            let requests = ReleaseProtocol.requests.count
            ReleaseProtocol.replies = [:]
            checker.check { _ in }
            wait { isAvailable(checker) }
            precondition(ReleaseProtocol.requests.count == requests + 2)
        }
        for invalid in [Data("<html>error</html>".utf8), ReleaseProtocol.release(tag: "not-a-version")] {
            scenario("无效响应不能抢赢有效响应") { checker, _ in
                ReleaseProtocol.replies[websiteAPI.absoluteString] = .hold
                ReleaseProtocol.replies[UpdateChecker.releaseAPI.absoluteString] = .response(200, invalid)
                checker.check(force: true) { _ in }
                wait { ReleaseProtocol.pending.count == 1 }
                pump()
                precondition(checker.currentStatus == .checking)
                ReleaseProtocol.pending[0].respond()
                wait { isAvailable(checker) }
            }
        }
        scenario("一路连接失败继续等待另一路；两路失败仅完成一次") { checker, _ in
            ReleaseProtocol.replies[websiteAPI.absoluteString] = .hold
            ReleaseProtocol.replies[UpdateChecker.releaseAPI.absoluteString] = .failure
            var completions = 0
            checker.check(force: true) { if $0 != .checking { completions += 1 } }
            wait { ReleaseProtocol.pending.count == 1 }
            pump()
            precondition(checker.currentStatus == .checking)
            ReleaseProtocol.pending[0].respond(code: 500)
            wait { isFailed(checker) }
            precondition(completions == 1)
        }
        scenario("缺少校验和不安装；重复偏好通知不重复检查") { checker, defaults in
            defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
            for _ in 0..<3 { checker.configureAutomaticUpdates() }
            wait { isAvailable(checker) }
            if case .updateAvailable(_, _, let download, let checksum) = checker.currentStatus {
                precondition(download == nil && checksum == nil)
            }
            precondition(ReleaseProtocol.requests.count == 2 && !checker.isAutomaticInstall)
        }
        scenario("检查中关闭自动更新；进行中拒绝重复下载") { checker, defaults in
            holdBoth()
            ReleaseProtocol.withChecksum = true
            defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            wait { ReleaseProtocol.pending.count == 2 }
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: nil) { _ in
                preconditionFailure("不应开始重复下载")
            }
            defaults.set(false, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            ReleaseProtocol.pending[0].respond()
            wait { isAvailable(checker) }
            precondition(!checker.isAutomaticInstall && ReleaseProtocol.requests.count == 2)
        }
        scenario("文件任务期间暂缓自动下载") { checker, defaults in
            let done = DispatchSemaphore(value: 0)
            FinderRightService.backgroundJobs.run(on: .global()) { done.wait() }
            ReleaseProtocol.withChecksum = true
            defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            wait { isAvailable(checker) }
            precondition(!checker.isAutomaticInstall)
            defaults.set(false, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            done.signal()
            wait { FinderRightService.backgroundJobs.isIdle }
        }
        for winner in [websiteAPI, UpdateChecker.releaseAPI] {
            scenario("自动下载失败切换同版本备用源一次：\(winner.host!)") { checker, defaults in
                ReleaseProtocol.withChecksum = true
                let loser = winner == websiteAPI ? UpdateChecker.releaseAPI : websiteAPI
                ReleaseProtocol.replies[loser.absoluteString] = .hold
                defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
                checker.configureAutomaticUpdates()
                wait { isFailed(checker) }
                let downloads = ReleaseProtocol.requests.filter { $0.path.hasSuffix(".zip") }
                let expected = winner == websiteAPI
                    ? [ReleaseProtocol.websiteZIP, ReleaseProtocol.githubZIP]
                    : [ReleaseProtocol.githubZIP, ReleaseProtocol.websiteZIP]
                precondition(downloads == expected && !checker.isAutomaticInstall)
            }
        }
        scenario("首选源无首字节时切换备用源") { checker, _ in
            ReleaseProtocol.replies[ReleaseProtocol.websiteZIP.absoluteString] = .hold
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.websiteZIP, checksum: .digest(ReleaseProtocol.hash)) { _ in }
            wait { isFailed(checker) }
            precondition(ReleaseProtocol.requests == [ReleaseProtocol.websiteZIP, ReleaseProtocol.githubZIP])
        }
        scenario("旧发布校验和文件失败切换同版本；校验和仍先于ZIP") { checker, _ in
            ReleaseProtocol.withChecksumFile = true
            ReleaseProtocol.replies[UpdateChecker.releaseAPI.absoluteString] = .hold
            checker.check(force: true) { _ in }
            wait { isAvailable(checker) }
            guard case .updateAvailable(_, _, let download?, let checksum?) = checker.currentStatus else { preconditionFailure() }
            let githubSHA = URL(string: ReleaseProtocol.githubZIP.absoluteString + ".sha256")!
            let websiteSHA = URL(string: ReleaseProtocol.websiteZIP.absoluteString + ".sha256")!
            ReleaseProtocol.replies[githubSHA.absoluteString] = .response(200, Data("\(ReleaseProtocol.hash)  FinderRight-v9999.0.0.zip".utf8))
            checker.startDownloadAndInstall(downloadURL: download, checksum: checksum) { _ in }
            wait { isFailed(checker) }
            let assets = ReleaseProtocol.requests.filter { $0.path.contains(".zip") }
            precondition(assets == [websiteSHA, githubSHA, ReleaseProtocol.websiteZIP, ReleaseProtocol.githubZIP])
        }
        for code in [404, 503] {
            scenario("HTTP错误页触发备用下载：\(code)") { checker, _ in
                ReleaseProtocol.replies[ReleaseProtocol.githubZIP.absoluteString] = .response(code, Data("error page".utf8))
                checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: .digest(ReleaseProtocol.hash)) { _ in }
                wait { isFailed(checker) }
                precondition(ReleaseProtocol.requests == [ReleaseProtocol.githubZIP, ReleaseProtocol.websiteZIP])
                if case .failed(let message) = checker.currentStatus { precondition(message.hasPrefix("下载失败:")) }
            }
        }
        scenario("下载内容哈希不匹配时拒装，不切换或降低校验要求") { checker, _ in
            ReleaseProtocol.replies[ReleaseProtocol.githubZIP.absoluteString] = .response(200, Data("corrupt zip".utf8))
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: .digest(ReleaseProtocol.hash)) { _ in }
            wait { isFailed(checker) }
            precondition(checker.currentStatus == .failed("更新包校验失败: SHA256 不匹配"))
            precondition(ReleaseProtocol.requests == [ReleaseProtocol.githubZIP])
        }
        scenario("跨块更新包摘要匹配后才进入解压，损坏归档不会替换应用") { checker, _ in
            let bytes = Data(repeating: 0x61, count: (3 << 20) + 7)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            ReleaseProtocol.replies[ReleaseProtocol.githubZIP.absoluteString] = .response(200, bytes)
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: .digest(hash)) { _ in }
            wait { isFailed(checker) }
            precondition(checker.currentStatus == .failed("安装失败: 解压更新包失败"))
            precondition(ReleaseProtocol.requests == [ReleaseProtocol.githubZIP])
        }
        scenario("其他仓库的资产不提供自动安装") { checker, _ in
            ReleaseProtocol.withChecksum = true
            let data = ReleaseProtocol.release(zipURL: URL(string: "https://example.invalid/FinderRight-v9999.0.0.zip")!)
            for api in [websiteAPI, UpdateChecker.releaseAPI] { ReleaseProtocol.replies[api.absoluteString] = .response(200, data) }
            checker.check(force: true) { _ in }
            wait { isAvailable(checker) }
            precondition(availableURL(checker) == nil)
        }
        for url in [ReleaseProtocol.githubZIP, URL(string: ReleaseProtocol.githubZIP.absoluteString + ".sha256")!] {
            let alternate = UpdateChecker.alternateAssetURL(for: url)!
            precondition(UpdateChecker.alternateAssetURL(for: alternate) == url)
        }
        for invalid in [
            "https://github.com/other/FinderRight/releases/download/v1.2.3/FinderRight-v1.2.3.zip",
            "https://github.com/funny-dog/FinderRight/releases/download/latest/FinderRight-v1.2.3.zip",
            "https://github.com/funny-dog/FinderRight/releases/download/v1.2.3/FinderRight-v1.2.4.zip",
            ReleaseProtocol.websiteZIP.absoluteString + "?url=evil",
            ReleaseProtocol.websiteZIP.absoluteString.replacingOccurrences(of: "https:", with: "http:")
        ] { precondition(UpdateChecker.alternateAssetURL(for: URL(string: invalid)!) == nil) }
        print("✓ 备用源映射拒绝跨仓库、latest、版本不匹配和任意URL")

        // 手动触发真实代理的计时任务，避免毫秒级 RunLoop 等待受 CI 调度影响。
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: ReleaseProtocol.githubZIP)
        var finishes = 0
        var timeouts: [(interval: TimeInterval, work: DispatchWorkItem)] = []
        let delegate = UpdateDownloadDelegate(onProgress: { _ in }, onFinish: { result in
            guard case .failure(let error) = result, (error as? URLError)?.code == .timedOut else {
                preconditionFailure("停滞应以超时错误结束")
            }
            finishes += 1
        }, schedule: { timeouts.append(($0, $1)) })
        delegate.watch(task, firstByteTimeout: 3, stallTimeout: 10)
        precondition(timeouts.count == 1 && timeouts[0].interval == 3)
        for i in 1...5 {
            let previous = timeouts.last!.work
            delegate.urlSession(session, downloadTask: task, didWriteData: 1, totalBytesWritten: Int64(i), totalBytesExpectedToWrite: 10)
            precondition(previous.isCancelled)
            previous.perform()
            precondition(timeouts.count == i + 1 && timeouts.last!.interval == 10)
            precondition(finishes == 0)
        }
        timeouts.last!.work.perform()
        precondition(finishes == 1)
        wait { task.state == .canceling || task.state == .completed }
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        precondition(finishes == 1)
        print("✓ 持续传输重置停滞计时；停滞后超时且取消回调不重复完成")

        session.invalidateAndCancel()
    }
}
