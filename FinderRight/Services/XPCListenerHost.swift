import Foundation
import AppKit
import FinderRightKit

/// 主 App 端的 IPC 监听宿主。
///
/// 责任：
///   1. 启动时确保 IPC 目录存在
///   2. 当主 App 收到自定义 URL `finderright://execute?id=<uuid>` 时，路由到这里的 handle(id:)
///   3. 从 request 文件读 IPCRequest → 调用 FinderRightService → 写 response 文件
///
/// 我们不主动监听目录，而是依赖扩展先写文件、再用 URL scheme 唤醒主 App。
/// 这避免了不必要的 fswatch 后台开销，并保证"请求顺序"严格。
final class IPCWatcher {

    static let shared = IPCWatcher()
    private init() {}

    private let service = FinderRightService()
    private let queue = DispatchQueue(label: "com.finderright.app.ipc", qos: .userInitiated)

    func start() {
        do {
            try IPCBridge.ensureDirectory()
            cleanupOrphanFiles()
            // 上次运行若在粘贴移动途中被杀，这里把残留的 in-flight 剪切队列归还给用户
            FinderRightService.recoverInflightCutQueue()
            // 上次角标归属抢回若在 ignore 与 use 之间被杀，这里把其他扩展恢复为启用
            BadgeOwnershipManager.shared.recoverIfNeeded()
            NSLog("[IPCWatcher] ready, ipc dir = \(IPCBridge.pendingDir.path)")
        } catch {
            NSLog("[IPCWatcher] failed to create ipc dir: \(error)")
        }
    }

    /// 扫描 pendingDir，删除修改时间超过 10 分钟的残留 *.req.json 和 *.resp.json 孤儿文件
    private func cleanupOrphanFiles() {
        let fm = FileManager.default
        let pending = IPCBridge.pendingDir
        guard let files = try? fm.contentsOfDirectory(atPath: pending.path) else { return }
        let now = Date()
        for file in files {
            guard file.hasSuffix(".req.json") || file.hasSuffix(".resp.json") else { continue }
            let fileURL = pending.appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
               let mtime = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(mtime) > 600 {
                try? fm.removeItem(at: fileURL)
                NSLog("[IPCWatcher] 清理孤儿文件: \(file)")
            }
        }
    }

    /// 主 App 收到 URL scheme 触发后，调用此方法
    /// URL 形如：finderright://execute?id=<uuid>
    func handle(url: URL) {
        guard url.scheme == IPCBridge.urlScheme else {
            NSLog("[IPCWatcher] unexpected url scheme: \(url)")
            return
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = comps.queryItems?.first(where: { $0.name == "id" })?.value else {
            NSLog("[IPCWatcher] url missing id: \(url)")
            return
        }
        // id 必须严格是 UUID：它会被直接拼进文件路径，未校验的 id（如 "../"）
        // 会导致路径穿越——主 App 会读取/删除任意 *.req.json、写出任意 *.resp.json。
        guard UUID(uuidString: id) != nil else {
            NSLog("[IPCWatcher] reject non-UUID id: \(id)")
            return
        }
        NSLog("[IPCWatcher] received request id=\(id)")
        queue.async { [weak self] in
            self?.processRequest(id: id)
        }
    }

    private func processRequest(id: String) {
        let reqURL = IPCBridge.requestFile(id: id)
        let respURL = IPCBridge.responseFile(id: id)

        do {
            let data = try Data(contentsOf: reqURL)
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)
            NSLog("[IPCWatcher] decoded request action=\(request.action)")

            let response = service.handle(request)

            let respData = try JSONEncoder().encode(response)
            try respData.write(to: respURL, options: .atomic)
            NSLog("[IPCWatcher] wrote response id=\(id) success=\(response.success)")

            // 清掉 request 文件（response 由扩展读完后删除）
            try? FileManager.default.removeItem(at: reqURL)
        } catch {
            NSLog("[IPCWatcher] processRequest error id=\(id): \(error)")
            // 即使出错也写一个 response，避免扩展死等
            let failed = IPCResponse(id: id, success: false, message: "主 App 处理失败: \(error.localizedDescription)")
            if let data = try? JSONEncoder().encode(failed) {
                try? data.write(to: respURL, options: .atomic)
            }
        }
    }
}
