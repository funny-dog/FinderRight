import Foundation
import FinderRightKit

// 使用真实更新器和隔离偏好；仅替代文件任务计数器，不启动主应用。
enum FinderRightService {
    static let backgroundJobs = BackgroundJobs()
}

private final class ReleaseProtocol: URLProtocol {
    static var requests = 0
    static var responseCode = 200
    static var withChecksum = false
    static var holdResponse = false
    static var pending: ReleaseProtocol?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        DispatchQueue.main.async {
            Self.requests += 1
            if Self.holdResponse { Self.pending = self } else { self.respond() }
        }
    }
    override func stopLoading() {}

    func respond() {
        let digest = Self.withChecksum ? ",\"digest\":\"sha256:\(String(repeating: "a", count: 64))\"" : ""
        // 不支持的下载协议会本地失败，测试不会下载或替换应用。
        let data = Data("""
        {"tag_name":"v9999.0.0","html_url":"https://example.invalid/release",
         "assets":[{"name":"FinderRight.zip","browser_download_url":"unsupported-update-test://package.zip"\(digest)}]}
        """.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.responseCode,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@main
struct AutomaticUpdateChecks {
    static func main() {
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { pump() }
            precondition(condition(), "等待更新状态超时")
        }
        func scenario(_ name: String, _ body: (UpdateChecker, UserDefaults) -> Void) {
            let suite = "FinderRight.AutomaticUpdateTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ReleaseProtocol.self]
            let session = URLSession(configuration: config)
            let checker = UpdateChecker(defaults: defaults, checkSession: session)
            ReleaseProtocol.requests = 0
            ReleaseProtocol.responseCode = 200
            ReleaseProtocol.withChecksum = false
            ReleaseProtocol.holdResponse = false
            ReleaseProtocol.pending = nil
            body(checker, defaults)
            defaults.set(false, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suite)
            print("✓ \(name)")
        }
        func isAvailable(_ checker: UpdateChecker) -> Bool {
            if case .updateAvailable = checker.currentStatus { return true }
            return false
        }

        scenario("默认关闭，不请求更新；手动检查仍可用") { checker, _ in
            checker.configureAutomaticUpdates()
            pump()
            precondition(checker.currentStatus == .idle && ReleaseProtocol.requests == 0)
            checker.check(force: true) { _ in }
            wait { isAvailable(checker) }
            precondition(ReleaseProtocol.requests == 1 && !checker.isAutomaticInstall)
        }
        scenario("开启立即检查，重复偏好通知不重复请求，缺少校验和不安装") { checker, defaults in
            defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
            for _ in 0..<3 { checker.configureAutomaticUpdates() }
            wait { isAvailable(checker) }
            precondition(ReleaseProtocol.requests == 1 && !checker.isAutomaticInstall)
            if case .updateAvailable(_, _, let download, let checksum) = checker.currentStatus {
                precondition(download == nil && checksum == nil)
            }
        }
        scenario("检查中关闭开关，响应到达后不安装；进行中拒绝重复下载") { checker, defaults in
            ReleaseProtocol.holdResponse = true
            ReleaseProtocol.withChecksum = true
            defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            wait { ReleaseProtocol.pending != nil }
            checker.startDownloadAndInstall(downloadURL: URL(string: "unsupported-update-test://duplicate.zip")!, checksum: nil) { _ in
                preconditionFailure("不应开始重复下载")
            }
            precondition(checker.currentStatus == .checking)
            defaults.set(false, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            ReleaseProtocol.pending!.respond()
            wait { isAvailable(checker) }
            precondition(!checker.isAutomaticInstall)
        }
        scenario("有文件任务时暂缓自动下载，关闭开关可取消等待") { checker, defaults in
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
        scenario("可安装更新自动进入下载；失败保留错误并清除自动安装标记") { checker, defaults in
            ReleaseProtocol.withChecksum = true
            defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            wait {
                if case .failed = checker.currentStatus { return true }
                return false
            }
            if case .failed(let message) = checker.currentStatus {
                precondition(message.hasPrefix("下载失败:"))
            }
            precondition(!checker.isAutomaticInstall && ReleaseProtocol.requests == 1)
        }
        scenario("检查失败不进入安装") { checker, defaults in
            ReleaseProtocol.responseCode = 500
            defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()
            wait { checker.currentStatus == .failed("检查失败 (500)") }
            precondition(!checker.isAutomaticInstall)
        }
    }
}
