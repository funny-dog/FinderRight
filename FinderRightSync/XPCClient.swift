import Foundation
import AppKit
import FinderRightKit
import os.log

/// FinderSync 扩展端的 IPC 客户端。
///
/// 工作流：
///   1. 把 IPCRequest JSON 写到 `~/Library/Application Support/FinderRight/ipc/<uuid>.req.json`
///   2. 用 NSWorkspace.open(URL("finderright://execute?id=<uuid>")) 唤醒主 App
///   3. 轮询 `<uuid>.resp.json` 出现
///   4. 读 response、删除 response 文件、返回结果
///
/// 为什么轮询而不是 fswatch：扩展生命周期短，每次操作完就结束，简单轮询 + 短 timeout 足够。
final class IPCClient {

    static let shared = IPCClient()
    private init() {}

    private let log = OSLog(subsystem: "com.finderright.app.sync", category: "IPCClient")

    /// 同步调用：写 request、唤醒主 App、等 response、返回结果
    /// - Parameter timeout: 总超时（秒）
    func call(action: String,
              payload: [String: AnyJSON],
              timeout: TimeInterval = 10) -> (success: Bool, message: String?) {

        let id = UUID().uuidString
        let req = IPCRequest(id: id, action: action, payload: payload)
        let reqURL = IPCBridge.requestFile(id: id)
        let respURL = IPCBridge.responseFile(id: id)

        // 1. 写 request
        do {
            try IPCBridge.ensureDirectory()
            let data = try JSONEncoder().encode(req)
            try data.write(to: reqURL, options: .atomic)
        } catch {
            os_log("IPC write request failed: %{public}@", log: log, type: .error, error.localizedDescription)
            return (false, "IPC 写请求失败: \(error.localizedDescription)")
        }

        // 2. 唤醒主 App（activates=false：不把 FinderRight 提到前台，Finder 保持焦点）
        guard let url = URL(string: "\(IPCBridge.urlScheme)://execute?id=\(id)") else {
            return (false, "IPC URL 构造失败")
        }
        let openCfg = NSWorkspace.OpenConfiguration()
        openCfg.activates = false
        openCfg.hides = true
        // 定向投递给「包含本扩展的那个主 App」：直接 open(url) 时由 LaunchServices 自选
        // finderright:// 的处理者，挂载着的 DMG、下载目录里的旧版本都可能接走请求
        if let appURL = IPCBridge.containingAppURL(forExtensionAt: Bundle.main.bundleURL) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: openCfg) { [log] _, error in
                guard let error else { return }
                os_log("定向唤醒主 App 失败，退回 URL 方式: %{public}@", log: log, type: .error, error.localizedDescription)
                NSWorkspace.shared.open(url, configuration: openCfg, completionHandler: nil)
            }
        } else {
            NSWorkspace.shared.open(url, configuration: openCfg, completionHandler: nil)
        }

        // 3. 轮询等待 response（自适应递增间隔：初始 2ms 瞬时捕获极速请求，后退避至 30ms 保障低开销）
        let deadline = Date().addingTimeInterval(timeout)
        var pollInterval: TimeInterval = 0.002
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: respURL.path) {
                // 4. 读取并清理
                if let data = try? Data(contentsOf: respURL),
                   let resp = try? JSONDecoder().decode(IPCResponse.self, from: data) {
                    try? FileManager.default.removeItem(at: respURL)
                    return (resp.success, resp.message)
                } else {
                    try? FileManager.default.removeItem(at: respURL)
                    return (false, "response 解析失败")
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
            if pollInterval < 0.03 {
                pollInterval = min(pollInterval * 2, 0.03)
            }
        }

        // 超时——把残留的 request 清掉
        try? FileManager.default.removeItem(at: reqURL)
        return (false, "IPC 超时 (\(timeout)s)")
    }

    /// 异步调用：派发到后台并发队列执行，避免阻塞 Finder 扩展的主交互线程
    func callAsync(action: String,
                   payload: [String: AnyJSON],
                   timeout: TimeInterval = 10,
                   completion: (((success: Bool, message: String?)) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let res = self.call(action: action, payload: payload, timeout: timeout)
            completion?(res)
        }
    }
}
