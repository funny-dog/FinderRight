import Foundation
import AppKit
import CryptoKit
import FinderRightKit

// 真实更新器、隔离偏好和模拟网络；只使用无效更新包，不会替换或重启应用。
enum FinderRightService {
    static let backgroundJobs = BackgroundJobs()
    static let jobGate = BackgroundJobs.Gate()
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

    /// 测试里「检查到的新版本」：比当前运行版本高，安装核对才会放行
    static let checkedVersion = "9999.0.0"

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
        func wait(_ label: String = "更新状态", timeout: TimeInterval = 3, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { pump() }
            precondition(condition(), "等待\(label)超时")
        }
        func availableURL(_ checker: UpdateChecker) -> URL? {
            if case .updateAvailable(_, _, let url, _) = checker.currentStatus { return url }
            return nil
        }
        func isAvailable(_ checker: UpdateChecker) -> Bool {
            if case .updateAvailable = checker.currentStatus { return true }
            return false
        }
        func isInstallable(_ checker: UpdateChecker) -> Bool {
            if case .updateAvailable(_, _, .some, .some) = checker.currentStatus { return true }
            return false
        }
        func isFailed(_ checker: UpdateChecker) -> Bool {
            if case .failed = checker.currentStatus { return true }
            return false
        }

        /// 与 ci.sh 的类型检查对齐：退出等待策略、静默更新标记与「因更新而退出」必须分开
        func exitPolicyTest() {
            precondition(!ExitWaitPolicy.waitsForBackgroundJobs(isUpdating: false, isAutomaticInstall: true),
                         "普通退出不因自动安装标记而无限等待")
            precondition(ExitWaitPolicy.waitsForBackgroundJobs(isUpdating: true, isAutomaticInstall: false),
                         "手动点击更新同样要等文件任务完成")
            precondition(ExitWaitPolicy.waitsForBackgroundJobs(isUpdating: true, isAutomaticInstall: true),
                         "自动更新同样要等文件任务完成")
            print("✓ 退出等待只取决于是否因更新交接，手动与自动一致")
        }

        // 两个检查实例的补充窗口都设为 80ms，避免测试真的等 800ms
        func scenario(_ name: String, window: TimeInterval = 0.08, _ body: (UpdateChecker, UserDefaults) -> Void) {
            let suite = "FinderRight.AutomaticUpdateTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ReleaseProtocol.self]
            let session = URLSession(configuration: config)
            let checker = UpdateChecker(defaults: defaults, checkSession: session, downloadConfiguration: config,
                                        firstByteTimeout: 0.1, stallTimeout: 0.1, supplementalWindow: window)
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

        exitPolicyTest()

        // 合法 ZIP 必须能全量解出并通过安装前校验：按目录名挑选条目的解压方式
        // 会漏掉主程序（目录条目常带尾斜杠，且匹配目录名不会展开整棵树），普通更新会全部失败
        do {
            let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fr-valid-zip-\(UUID().uuidString)", isDirectory: true)
            let staging = root.appendingPathComponent("FinderRight.app", isDirectory: true)
            for bundle in ["", "Contents/PlugIns/FinderRightSync.appex",
                           "Contents/PlugIns/FinderRightPreview.appex",
                           "Contents/PlugIns/FinderRightMarkdown.appex"] {
                let bundleRoot = bundle.isEmpty ? staging : staging.appendingPathComponent(bundle, isDirectory: true)
                let contents = bundleRoot.appendingPathComponent("Contents", isDirectory: true)
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                let plist: [String: Any] = [
                    "CFBundleShortVersionString": "9999.0.0",
                    "CFBundleVersion": "1",
                    "LSMinimumSystemVersion": "13.0",
                ]
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
            }
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("Contents/MacOS", isDirectory: true), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: staging.appendingPathComponent("Contents/MacOS/FinderRight"))
            let zipURL = root.appendingPathComponent("update.zip")
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.arguments = ["-q", "-r", "-X", zipURL.path, "FinderRight.app"]
            zip.currentDirectoryURL = root
            try zip.run()
            zip.waitUntilExit()
            precondition(zip.terminationStatus == 0, "测试夹具 ZIP 打包失败")

            let outDir = root.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let appURL = try UpdateChecker.extractUpdatePackage(from: zipURL, into: outDir)
            let mainPlist = appURL.appendingPathComponent("Contents/Info.plist")
            let mainBinary = appURL.appendingPathComponent("Contents/MacOS/FinderRight")
            precondition(FileManager.default.fileExists(atPath: mainPlist.path), "主程序 Info.plist 应被解出")
            precondition(FileManager.default.fileExists(atPath: mainBinary.path), "主程序可执行文件应被解出")
            // 解出的包能通过安装前校验，才证明「合法 ZIP → 安装校验」整段链路可用
            try UpdatePackageCheck.validate(
                appAt: appURL,
                expectation: .init(expectedVersion: "v9999.0.0", currentVersion: "1.0.0", operatingSystemVersion: "13.6.1"),
                signature: .adHoc, currentSignature: .adHoc)
            try? FileManager.default.removeItem(at: root)
            print("✓ 合法 ZIP 全量解出并通过安装校验（含主程序与四个 bundle）")
        } catch {
            preconditionFailure("合法 ZIP 解压测试失败: \(error)")
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
            precondition(!checker.isAutomaticInstall && !checker.isInstallingUpdate)
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
        scenario("一路快速返回最新、另一路挂起：补充窗口结束后完成并取消剩余请求") { checker, _ in
            holdBoth()
            var completions = 0
            let start = Date()
            checker.check(force: true) { if $0 != .checking { completions += 1 } }
            wait { ReleaseProtocol.pending.count == 2 }
            ReleaseProtocol.pending.first { $0.request.url == websiteAPI }!.respond(data: ReleaseProtocol.release(tag: "v0.0.0"))
            pump()
            precondition(checker.currentStatus == .checking && completions == 0, "窗口内不能立刻结束")
            wait(timeout: 2) { checker.currentStatus == .upToDate }
            let elapsed = Date().timeIntervalSince(start)
            precondition(completions == 1, "只完成一次")
            precondition(elapsed >= 0.08 && elapsed < 1.5, "应在补充窗口后尽快结束，实际 \(elapsed)")
            wait { ReleaseProtocol.cancelled.contains(UpdateChecker.releaseAPI) }
            let requests = ReleaseProtocol.requests.count
            checker.check { _ in }
            pump()
            precondition(ReleaseProtocol.requests.count == requests, "结论未过期时复用")
        }
        for (fast, slow) in [(websiteAPI, UpdateChecker.releaseAPI), (UpdateChecker.releaseAPI, websiteAPI)] {
            scenario("窗口内另一源返回新版时优先采用新版：\(slow.host!)") { checker, _ in
                holdBoth()
                checker.check(force: true) { _ in }
                wait { ReleaseProtocol.pending.count == 2 }
                ReleaseProtocol.pending.first { $0.request.url == fast }!.respond(data: ReleaseProtocol.release(tag: "v0.0.0"))
                pump(0.01)
                ReleaseProtocol.withChecksum = true
                ReleaseProtocol.pending.first { $0.request.url == slow }!.respond()
                let expected = slow == websiteAPI ? ReleaseProtocol.websiteZIP : ReleaseProtocol.githubZIP
                wait { availableURL(checker) == expected }
                if case .updateAvailable(let version, _, _, _) = checker.currentStatus {
                    precondition(version == "v9999.0.0")
                } else { preconditionFailure("应为新版本") }
            }
        }
        scenario("窗口内另一源只有旧版本时沿用已有结论") { checker, _ in
            holdBoth()
            checker.check(force: true) { _ in }
            wait { ReleaseProtocol.pending.count == 2 }
            ReleaseProtocol.pending.first { $0.request.url == websiteAPI }!.respond(data: ReleaseProtocol.release(tag: "v0.0.0"))
            pump(0.01)
            ReleaseProtocol.withChecksum = true
            ReleaseProtocol.pending.first { $0.request.url == UpdateChecker.releaseAPI }!
                .respond(data: ReleaseProtocol.release(tag: "v0.0.0"))
            wait { checker.currentStatus == .upToDate }
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
        scenario("缺少校验信息的版本提示不会被补充窗口覆盖") { checker, _ in
            holdBoth()
            checker.check(force: true) { _ in }
            wait { ReleaseProtocol.pending.count == 2 }
            ReleaseProtocol.pending.first { $0.request.url == websiteAPI }!.respond()
            wait(timeout: 2) { isAvailable(checker) }
            guard case .updateAvailable(_, _, nil, nil) = checker.currentStatus else { preconditionFailure("应保留缺少下载地址的版本提示") }
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
        scenario("两路都挂起时补充窗口不会报告最新，等各自超时后正常失败") { checker, _ in
            holdBoth()
            checker.check(force: true) { _ in }
            wait { ReleaseProtocol.pending.count == 2 }
            pump(0.3)
            precondition(checker.currentStatus == .checking, "没有有效结果时计时器不能结束检查")
            ReleaseProtocol.pending[0].respond(code: 500)
            pump()
            precondition(checker.currentStatus == .checking, "只有失败也不能当作最新")
            ReleaseProtocol.pending[1].respond(code: 500)
            wait { isFailed(checker) }
        }
        scenario("两路都失败时报告失败，不误报最新") { checker, _ in
            ReleaseProtocol.replies[UpdateChecker.releaseAPI.absoluteString] = .failure
            ReleaseProtocol.replies[websiteAPI.absoluteString] = .failure
            var completions = 0
            checker.check(force: true) { if $0 != .checking { completions += 1 } }
            wait { isFailed(checker) }
            precondition(completions == 1 && checker.currentStatus != .upToDate)
        }
        scenario("迟到响应、重复点击不会重复回调或覆盖结论") { checker, _ in
            ReleaseProtocol.withChecksum = true
            holdBoth()
            var completions = 0
            checker.check(force: true) { if $0 != .checking { completions += 1 } }
            wait { ReleaseProtocol.pending.count == 2 }
            let late = ReleaseProtocol.pending[1]
            ReleaseProtocol.pending[0].respond()
            wait { isAvailable(checker) }
            // 检查进行中再点一次：直接拿到进行中的状态，不会重复发请求
            checker.check(force: true) { _ in }
            precondition(ReleaseProtocol.requests.count == 2)
            let status = checker.currentStatus
            late.respond(data: ReleaseProtocol.release(tag: "v9999.0.1"))
            pump(0.2)
            precondition(checker.currentStatus == status && completions == 1, "迟到响应不能覆盖最终结果")
        }
        scenario("成功后强制检查失败，普通检查仍可立即重试") { checker, _ in
            ReleaseProtocol.withChecksum = true
            checker.check(force: true) { _ in }
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
        scenario("强制检查只回调一次进行中与一次最终结果，不重放缓存结论") { checker, _ in
            // 新实例是 .idle：先发一次真实请求拿到完整结论，关闭自动安装后不进入下载
            ReleaseProtocol.withChecksum = true
            let suite = "FinderRight.AboutPage.\(UUID().uuidString)"
            let stored = UserDefaults(suiteName: suite)!
            stored.set(false, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates(using: stored)
            checker.check(force: true) { _ in }
            wait("可安装的新版本") { isInstallable(checker) }
            checker.configureAutomaticUpdates(using: stored)
            let cached = checker.currentStatus
            let checkedAt = checker.lastCheckedDate
            precondition(checkedAt != nil)
            // 再次强制检查：旧结论由界面读取缓存状态展示，检查回调只有 .checking 与一次最终结果，
            // 不重放缓存结论（否则菜单栏会把重放结果当最终结论重复弹窗）
            holdBoth()
            var checkingCount = 0
            var finals: [UpdateCheckStatus] = []
            checker.check(force: true) { status in
                if status == .checking {
                    checkingCount += 1
                    return
                }
                finals.append(status)
            }
            wait { ReleaseProtocol.pending.count == 2 }
            pump()
            precondition(finals.isEmpty && checkingCount == 1,
                         "发起时只能回调一次进行中，不得先重放旧结论：finals=\(finals) checking=\(checkingCount)")
            precondition(checker.currentStatus == .checking)
            ReleaseProtocol.pending[0].respond()
            wait(timeout: 2) { !finals.isEmpty }
            pump()
            precondition(finals.count == 1 && checkingCount == 1, "最终结果只回调一次：finals=\(finals)")
            if case .updateAvailable = finals[0] {} else { preconditionFailure("最终结果应是新版本：\(finals[0])") }
            precondition(checker.lastCheckedDate! > checkedAt!, "检查成功后更新检查时间")
            // 结论未过期时再次检查直接复用缓存：只有一个最终回调，不发请求
            let requests = ReleaseProtocol.requests.count
            var cachedCallbacks: [UpdateCheckStatus] = []
            checker.check { status in cachedCallbacks.append(status) }
            pump()
            precondition(cachedCallbacks == [cached], "未过期结论应原样复用：\(cachedCallbacks)")
            precondition(ReleaseProtocol.requests.count == requests, "复用缓存不应发请求")
        }

        // P2 集成用例：旧缓存（upToDate）+ 开启自动更新 + 网络返回新版 → 应触发自动安装
        // 此前后台刷新丢弃 completion（notify: { _ in }），导致 checkAutomatically 拿不到新结果
        scenario("旧缓存 + 开启自动更新 + 网络返回新版：后台刷新仍触发自动安装") { checker, defaults in
            // 1. 先做一次真实检查（网络返回无新版），拿到 upToDate 结论，然后把时间倒退到 30 分钟前
            //    （模拟"用户半小时前手动检查过未发现新版，现在开启自动更新"的场景）
            let upToDateData = ReleaseProtocol.release(tag: "v0.0.0")
            ReleaseProtocol.replies[UpdateChecker.releaseAPI.absoluteString] = .response(200, upToDateData)
            ReleaseProtocol.replies[websiteAPI.absoluteString] = .response(200, upToDateData)
            checker.check(force: true) { _ in }
            wait("第一次检查完成") { checker.currentStatus == .upToDate }
            checker.setLastCheckedDateForTesting(Date().addingTimeInterval(-30 * 60))

            // 2. 网络此后有新版（清空旧回复，允许返回默认新版）；开启自动更新触发 checkAutomatically
            ReleaseProtocol.replies = [:]
            ReleaseProtocol.withChecksum = true
            holdBoth()
            defaults.set(true, forKey: UpdateChecker.automaticUpdatesKey)
            checker.configureAutomaticUpdates()

            // 3. checkAutomatically 走 waitsForResult 路径：先回调旧结论，再发后台刷新请求
            wait("后台刷新请求到达") { ReleaseProtocol.pending.count == 2 }

            // 4. 网络返回新版
            ReleaseProtocol.pending[0].respond()

            // 5. 后台刷新的结果必须传给 checkAutomatically 的 completion，触发自动安装；
            //    修复前丢弃 completion 时，新版发现了也不会安装，直到下一轮定时检查
            wait("自动更新被触发", timeout: 5) { checker.isAutomaticInstall || isFailed(checker) }
            precondition(checker.isAutomaticInstall || isFailed(checker),
                         "后台刷新发现新版后应触发自动安装，status=\(checker.currentStatus)")
        }

        scenario("缺少校验和不安装；重复偏好通知不重复检查") { checker, defaults in
            checker.setLastCheckedDateForTesting(nil)
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
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: nil, version: ReleaseProtocol.checkedVersion) { _ in
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
                precondition(downloads == expected && !checker.isAutomaticInstall && !checker.isInstallingUpdate)
            }
        }
        scenario("首选源无首字节时切换备用源") { checker, _ in
            ReleaseProtocol.replies[ReleaseProtocol.websiteZIP.absoluteString] = .hold
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.websiteZIP, checksum: .digest(ReleaseProtocol.hash),
                                            version: ReleaseProtocol.checkedVersion) { _ in }
            wait { isFailed(checker) }
            precondition(ReleaseProtocol.requests == [ReleaseProtocol.websiteZIP, ReleaseProtocol.githubZIP])
        }
        scenario("旧发布校验和文件失败切换同版本；校验和仍先于ZIP") { checker, _ in
            ReleaseProtocol.withChecksumFile = true
            ReleaseProtocol.replies[UpdateChecker.releaseAPI.absoluteString] = .hold
            checker.check(force: true) { _ in }
            wait { isAvailable(checker) }
            guard case .updateAvailable(let version, _, let download?, let checksum?) = checker.currentStatus else { preconditionFailure() }
            let githubSHA = URL(string: ReleaseProtocol.githubZIP.absoluteString + ".sha256")!
            let websiteSHA = URL(string: ReleaseProtocol.websiteZIP.absoluteString + ".sha256")!
            ReleaseProtocol.replies[githubSHA.absoluteString] = .response(200, Data("\(ReleaseProtocol.hash)  FinderRight-v9999.0.0.zip".utf8))
            checker.startDownloadAndInstall(downloadURL: download, checksum: checksum, version: version) { _ in }
            wait { isFailed(checker) }
            let assets = ReleaseProtocol.requests.filter { $0.path.contains(".zip") }
            precondition(assets == [websiteSHA, githubSHA, ReleaseProtocol.websiteZIP, ReleaseProtocol.githubZIP])
        }
        for code in [404, 503] {
            scenario("HTTP错误页触发备用下载：\(code)") { checker, _ in
                ReleaseProtocol.replies[ReleaseProtocol.githubZIP.absoluteString] = .response(code, Data("error page".utf8))
                checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: .digest(ReleaseProtocol.hash),
                                                version: ReleaseProtocol.checkedVersion) { _ in }
                wait { isFailed(checker) }
                precondition(ReleaseProtocol.requests == [ReleaseProtocol.githubZIP, ReleaseProtocol.websiteZIP])
                if case .failed(let message) = checker.currentStatus { precondition(message.hasPrefix("下载失败:")) }
            }
        }
        scenario("下载内容哈希不匹配时拒装，不切换或降低校验要求") { checker, _ in
            ReleaseProtocol.replies[ReleaseProtocol.githubZIP.absoluteString] = .response(200, Data("corrupt zip".utf8))
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: .digest(ReleaseProtocol.hash),
                                            version: ReleaseProtocol.checkedVersion) { _ in }
            wait { isFailed(checker) }
            precondition(checker.currentStatus == .failed("更新包校验失败: SHA256 不匹配"))
            precondition(ReleaseProtocol.requests == [ReleaseProtocol.githubZIP])
            precondition(!checker.isInstallingUpdate, "校验失败不能进入替换流程")
        }
        scenario("跨块更新包摘要匹配后才进入解压，损坏归档不会替换应用") { checker, _ in
            let bytes = Data(repeating: 0x61, count: (3 << 20) + 7)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            ReleaseProtocol.replies[ReleaseProtocol.githubZIP.absoluteString] = .response(200, bytes)
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: .digest(hash),
                                            version: ReleaseProtocol.checkedVersion) { _ in }
            wait { isFailed(checker) }
            precondition(checker.currentStatus == .failed("安装失败: 解压更新包失败"))
            precondition(ReleaseProtocol.requests == [ReleaseProtocol.githubZIP])
            precondition(!checker.isInstallingUpdate, "解压失败不能交接安装")
        }
        scenario("安装包版本与检查到的版本不符时拒装，不退出应用") { checker, _ in
            let bytes = Data(repeating: 0x61, count: 1024)
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            ReleaseProtocol.replies[ReleaseProtocol.githubZIP.absoluteString] = .response(200, bytes)
            checker.startDownloadAndInstall(downloadURL: ReleaseProtocol.githubZIP, checksum: .digest(hash),
                                            version: "9999.0.1") { _ in }
            wait { isFailed(checker) }
            guard case .failed(let message) = checker.currentStatus else { preconditionFailure() }
            precondition(message.hasPrefix("安装失败:"), "应报告安装失败: \(message)")
            precondition(!checker.isInstallingUpdate)
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
