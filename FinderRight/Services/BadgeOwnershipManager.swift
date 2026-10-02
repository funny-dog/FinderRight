import Foundation
import FinderRightKit
import os.log

/// 剪切角标归属抢回的执行端（主 App，非沙箱，可调用 pluginkit）。
///
/// 背景：同一目录被多个 Finder Sync 扩展注册时，Finder 只把 requestBadgeIdentifier 交给
/// 最先注册者。扩展判定自己丢失归属后发来 `reclaimBadgeOwnership`，这里把其他已启用的
/// Finder Sync 扩展短暂 `pluginkit -e ignore` 再 `-e use`：它们重新注册时排到我们之后，
/// 归属随即转给本扩展（2026-10-02 真机验证：Finder 不需重启，且会立即重新请求可见项角标）。
/// 设计取舍：重启范围为全部已启用的其他扩展（无法得知谁真正冲突），设置中可关闭。
///
/// 安全约束：动的是别人 App 的扩展配置，任何时刻崩溃都必须可恢复 ——
/// ignore 之前先落盘恢复标记，全部恢复并核验后才删除；主 App 启动时按标记补恢复。
final class BadgeOwnershipManager {

    static let shared = BadgeOwnershipManager()
    private init() {}

    private static let ownExtensionId = "com.finderright.app.sync"
    private static let pluginKitURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    /// ignore 与 use 之间的停留时间（与真机验证一致；过短时 Finder 可能来不及转移归属）
    private static let ignoreDuration: TimeInterval = 2

    /// 只保护 limiter；耗时的 pluginkit 调用全部在 workQueue 上，绝不占用 IPC 串行队列
    private let lock = NSLock()
    private var limiter = BadgeReclaimRateLimiter()
    private let workQueue = DispatchQueue(label: "com.finderright.app.badge-reclaim", qos: .utility)
    private let restoreStore = BadgeReclaimRestoreStore()

    // MARK: - IPC 受理（同步、毫秒级）

    func handle(_ req: IPCRequest) -> IPCResponse {
        guard let directory = req.payload["directory"]?.stringValue,
              let requester = req.payload["requester"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "\(BadgeReclaimIPC.action) 参数缺失")
        }
        let reason = req.payload["reason"]?.stringValue ?? "?"

        func reject(_ rejection: BadgeReclaimRejection, _ detail: String) -> IPCResponse {
            log("拒绝 [reason=\(reason) requester=\(requester)] \(rejection.rawValue): \(detail)")
            return IPCResponse(id: req.id, success: false, message: rejection.message(detail: detail))
        }

        guard SharedConfig.shared.badgeOwnershipReclaim else {
            return reject(.disabled, "设置已关闭")
        }

        // 收不到角标请求只有在「目录里确实有可见项」时才说明归属丢失
        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: directory)
        } catch {
            return reject(.cannotRead, "\(directory): \(error.localizedDescription)")
        }
        guard entries.contains(where: { !$0.hasPrefix(".") }) else {
            return reject(.noVisibleItems, directory)
        }

        lock.lock()
        let decision = limiter.evaluate(requester: requester, now: Date())
        lock.unlock()
        if case .reject(let detail) = decision {
            return reject(.rateLimited, detail)
        }

        log("受理 [reason=\(reason) requester=\(requester)] dir=\(directory)")
        workQueue.async { [weak self] in self?.performReclaim() }
        return IPCResponse(id: req.id, success: true, message: nil)
    }

    // MARK: - 执行（workQueue）

    private func performReclaim() {
        let start = Date()
        guard let listing = Self.pluginKit(["-m", "-p", "com.apple.FinderSync"]) else {
            log("pluginkit -m 执行失败，放弃本次抢回")
            return
        }
        let ids = FinderSyncElection.enabledBundleIds(in: listing, excluding: [Self.ownExtensionId])
        guard !ids.isEmpty else {
            log("没有其他已启用的 Finder Sync 扩展，归属丢失只可能来自 File Provider 等系统接管")
            return
        }

        // 先落盘再动手：之后任何时刻崩溃，下次启动都能按标记恢复。
        // 必须与已有标记合并：上次恢复失败的扩展此刻不是 `+`，不在 ids 里，覆盖写会让它永久停在禁用状态
        let toRestore: [String]
        do {
            toRestore = try restoreStore.merge(ids)
        } catch {
            log("恢复标记写入失败，为安全起见放弃抢回: \(error.localizedDescription)")
            return
        }

        log("重启其他 Finder Sync 扩展以取回角标归属: \(ids)")
        let leftover = toRestore.filter { !ids.contains($0) }
        if !leftover.isEmpty {
            log("并入上次未能恢复的扩展，本轮一并恢复: \(leftover)")
        }
        for id in ids {
            _ = Self.pluginKit(["-e", "ignore", "-i", id])
        }
        Thread.sleep(forTimeInterval: Self.ignoreDuration)
        restore(toRestore, context: "抢回")
        log("抢回流程结束，耗时 \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
    }

    /// 把 ids 恢复为启用并核验；未恢复的重试一次。全部恢复才删除恢复标记。
    private func restore(_ ids: [String], context: String) {
        for id in ids {
            _ = Self.pluginKit(["-e", "use", "-i", id])
        }
        var pending = notEnabled(among: ids)
        if !pending.isEmpty {
            log("[\(context)] 首次恢复后仍未启用，重试: \(pending)")
            for id in pending {
                _ = Self.pluginKit(["-e", "use", "-i", id])
            }
            pending = notEnabled(among: ids)
        }

        if pending.isEmpty {
            restoreStore.clear()
            log("[\(context)] 已恢复启用并核验: \(ids.count) 个扩展")
        } else {
            // 保留标记：下次主 App 启动继续恢复
            log("[\(context)] ⚠️ 以下扩展未能恢复启用，保留恢复标记待下次启动重试: \(pending)")
        }
    }

    /// 返回 ids 中当前不处于启用（+）状态的项；查询失败时保守地认为全部未恢复
    private func notEnabled(among ids: [String]) -> [String] {
        guard let listing = Self.pluginKit(["-m", "-p", "com.apple.FinderSync"]) else { return ids }
        let enabled = Set(FinderSyncElection.enabledBundleIds(in: listing, excluding: []))
        return ids.filter { !enabled.contains($0) }
    }

    // MARK: - 崩溃恢复

    /// 主 App 启动时调用：上次抢回若在 ignore 与 use 之间中断，把那些扩展恢复为启用
    func recoverIfNeeded() {
        let ids = restoreStore.load()
        guard !ids.isEmpty else {
            restoreStore.clear() // 清掉可能的损坏文件
            return
        }
        workQueue.async { [weak self] in
            self?.log("发现上次中断的抢回，恢复扩展启用状态: \(ids)")
            self?.restore(ids, context: "崩溃恢复")
        }
    }

    // MARK: - Helpers

    /// 同步执行 pluginkit，返回 stdout；启动失败或退出码非 0 返回 nil
    private static func pluginKit(_ arguments: [String]) -> String? {
        let proc = Process()
        let out = Pipe()
        proc.executableURL = pluginKitURL
        proc.arguments = arguments
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            os_log("pluginkit %{public}@ 启动失败: %{public}@", log: osLog, type: .error, arguments.description, error.localizedDescription)
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            os_log("pluginkit %{public}@ 退出码 %d", log: osLog, type: .error, arguments.description, proc.terminationStatus)
            return nil
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 用 os_log 的 public 格式输出：NSLog 内容在统一日志里会被脱敏为 <private>，无法用
    /// `log show --predicate 'subsystem == "com.finderright.app" AND category == "BadgeOwnership"'` 排查
    private static let osLog = OSLog(subsystem: "com.finderright.app", category: "BadgeOwnership")

    private func log(_ message: String) {
        os_log("%{public}@", log: Self.osLog, type: .default, message)
    }
}
