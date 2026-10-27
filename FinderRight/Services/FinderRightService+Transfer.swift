import Foundation
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

// MARK: - 移动到 / 复制到常用目录

extension FinderRightService {

    // MARK: - 移动到 / 复制到常用目录

    /// 移动 / 复制专用串行队列：同一时刻只做一批，避免并发移动同一批文件
    static let transferQueue = DispatchQueue(label: "com.finderright.app.transfer", qos: .userInitiated)

    /// 把选中项移动或复制到常用目录。
    /// items / destination 已由 handle() 的路径白名单校验；这里再要求 destination 必须是设置里的常用目录之一，
    /// 使这条 IPC 只能把文件送往用户亲自添加过的目录
    func transferItems(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, !items.isEmpty,
              let destination = req.payload["destination"]?.stringValue,
              let modeRaw = req.payload["mode"]?.stringValue,
              let mode = FileTransferCheck.Mode(rawValue: modeRaw) else {
            return IPCResponse(id: req.id, success: false, message: "transferItems 参数缺失")
        }
        SharedConfig.shared.reload()
        guard SharedConfig.shared.favoriteDirectories.contains(destination) else {
            serviceLog("目标不在常用目录列表中，已拒绝: \(destination)")
            return IPCResponse(id: req.id, success: false, message: L("目标不是常用目录"))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination, isDirectory: &isDir), isDir.boolValue else {
            let subject = Self.subject(forPaths: items)
            RecentOperations.shared.record(OperationRecord(
                kind: mode == .move ? .move : .copy, subject: subject,
                failure: String(format: L("常用目录不存在：%@"), destination), location: URL(fileURLWithPath: destination)))
            return IPCResponse(id: req.id, success: false, message: L("常用目录不存在"))
        }

        // 受理即算一次使用：右键菜单、服务菜单与设置页按最近使用排序时据此排在前面
        SharedConfig.shared.markFavoriteUsed(destination)
        Self.backgroundJobs.run(on: Self.transferQueue) { [weak self] in
            self?.performTransfer(sourcePaths: items, destDir: URL(fileURLWithPath: destination), mode: mode)
        }
        return IPCResponse(id: req.id, success: true, message: "已受理，正在后台处理")
    }

    private func performTransfer(sourcePaths: [String], destDir: URL, mode: FileTransferCheck.Mode) {
        let fileManager = FileManager.default
        let destPath = destDir.resolvingSymlinksInPath().path
        var done: [URL] = []
        var transferred: [(current: URL, original: URL?)] = []
        var failed = 0
        var firstError: String?

        for sourcePath in sourcePaths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            guard fileManager.fileExists(atPath: sourcePath) else { continue }
            switch FileTransferCheck.check(source: sourceURL.resolvingSymlinksInPath().path,
                                           destinationDirectory: destPath, mode: mode) {
            case .alreadyInDestination:
                continue
            case .destinationInsideSource:
                failed += 1
                if firstError == nil { firstError = L("不能放进它自身内部") }
                continue
            case .ok:
                break
            }
            // 重名时自动编号，与新建文件 / 粘贴共用 UniqueName 规则
            let destURL = UniqueName.fileURL(baseName: sourceURL.deletingPathExtension().lastPathComponent,
                                             ext: sourceURL.pathExtension, in: destDir)
            do {
                if mode == .move {
                    try fileManager.moveItem(at: sourceURL, to: destURL)
                } else {
                    // APFS 上 copyItem 为克隆，大文件也几乎瞬间完成
                    try fileManager.copyItem(at: sourceURL, to: destURL)
                }
                done.append(destURL)
                transferred.append((destURL, mode == .move ? sourceURL : nil))
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        if !done.isEmpty {
            registerUndo(mode == .move ? .move : .copy, name: destDir.lastPathComponent, items: transferred)
        }

        let subject = Self.subject(forPaths: sourcePaths)
        let kind: OperationRecord.Kind = mode == .move ? .move : .copy
        if let firstError {
            let format = mode == .move ? L("%d 项未能移动：%@") : L("%d 项未能复制：%@")
            serviceLog("transferItems(\(mode.rawValue)) completed with \(failed) failure(s): \(firstError)")
            RecentOperations.shared.record(OperationRecord(
                kind: kind, subject: subject, failure: String(format: format, failed, firstError), results: done, location: destDir))
        } else if !done.isEmpty {
            serviceLog("transferItems(\(mode.rawValue)) succeeded: \(done.count) item(s) to \(destDir.path)")
            RecentOperations.shared.record(OperationRecord(kind: kind, subject: subject, results: done, location: destDir))
        }
    }
}
