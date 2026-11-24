import Foundation
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "batch rename") }

// MARK: - 批量重命名

extension FinderRightService {

    /// 执行批量重命名：登记撤销与操作历史并给出反馈。文件操作在 transferQueue 上进行，`completion` 在主线程回调
    func applyBatchRename(_ entries: [BatchRenameEntry], completion: @escaping (BatchRenameResult) -> Void) {
        let ready = entries.filter(\.isReady)
        guard Self.runGuarded(on: Self.transferQueue, work: { [weak self] in
            var allowed: [BatchRenameEntry] = []
            var denied: [(name: String, reason: String)] = []
            for entry in ready {
                let directory = entry.source.deletingLastPathComponent().path
                if Self.isPathAllowed(entry.source.path, role: .source), Self.isPathAllowed(directory, role: .destination) {
                    allowed.append(entry)
                } else {
                    denied.append((entry.source.lastPathComponent,
                                   String(format: L("路径越界：安全策略拒绝访问 %@"), entry.source.path)))
                }
            }
            var result = BatchRename.apply(allowed)
            result.failures += denied
            self?.finishBatchRename(result, total: ready.count)
            DispatchQueue.main.async { completion(result) }
        }) else {
            completion(BatchRenameResult())
            return
        }
    }

    private func finishBatchRename(_ result: BatchRenameResult, total: Int) {
        if !result.renamed.isEmpty {
            registerUndo(.rename, name: "", items: result.renamed.map { ($0.to, $0.from) }, displayCount: result.renamed.count)
        }
        let details = result.failures.map { "\($0.name)：\($0.reason)" }.joined(separator: "\n")
        RecentOperations.shared.record(OperationRecord(
            kind: .rename, subject: String(format: L("%d 个项目"), total),
            failure: result.failures.isEmpty ? nil : details,
            results: result.renamed.map(\.to),
            location: result.renamed.first?.to.deletingLastPathComponent()))
        if result.failures.isEmpty {
            ClipboardToast.show(message: String(format: L("已重命名 %d 项"), result.renamed.count), style: .success)
        } else {
            ClipboardToast.show(message: String(format: L("重命名完成 %d 项，%d 项失败"), result.renamed.count, result.failures.count), style: .failure)
        }
    }
}
