import Foundation
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

// MARK: - 撤销

extension FinderRightService {

    // MARK: - 撤销上一次操作

    /// 登记一次可撤销的操作。指纹在操作完成后、在新位置上取；取不到的项丢弃，
    /// 全部丢弃时（剪切除外，它不动文件）不登记，旧记录保持不变
    func registerUndo(_ kind: UndoRecord.Kind, name: String, items: [(current: URL, original: URL?)],
                              cutQueueBefore: [String]? = nil, displayCount: Int? = nil) {
        let recorded = items.compactMap { pair in
            FileFingerprint.capture(pair.current).map {
                UndoRecord.Item(current: pair.current, original: pair.original, fingerprint: $0)
            }
        }
        guard kind == .cut || !recorded.isEmpty else { return }
        let snapshot = FinderUndoMenu.snapshot()
        UndoCenter.shared.register(UndoRecord(kind: kind, name: name, items: recorded,
                                              cutQueueBefore: cutQueueBefore, finderSnapshot: snapshot),
                                   displayCount: displayCount)
        serviceLog("undo registered: \(kind.rawValue) items=\(recorded.count) finder=\(snapshot.map { "\($0.title)/\($0.enabled)" } ?? "nil")")
        Self.scheduleRemovalCheck()
    }

    /// 撤销 FinderRight 记录的上一次操作。来源：⌘Z 拦截、扩展右键菜单、菜单栏。
    /// IPC 立即返回「已受理」，文件移动或送废纸篓在 transferQueue 上执行，结果用提示告知
    func undoLast(_ req: IPCRequest) -> IPCResponse {
        guard let record = UndoCenter.shared.beginUndo() else {
            ClipboardToast.show(message: L("没有可撤销的操作"), style: .failure)
            return IPCResponse(id: req.id, success: false, message: L("没有可撤销的操作"))
        }
        Self.backgroundJobs.run(on: Self.transferQueue) {
            self.performUndo(record)
            // 只清「撤销中」标记：撤销期间别的队列登记的新记录照常保留
            UndoCenter.shared.endUndo()
        }
        return IPCResponse(id: req.id, success: true, message: "已受理撤销，正在后台处理")
    }

    private func performUndo(_ record: UndoRecord) {
        let outcome: UndoOutcome
        if record.kind == .cut {
            outcome = restoreCutQueue(record.cutQueueBefore ?? [])
        } else {
            // 撤销粘贴只把文件移回原处，不放回剪切队列：与 ⌘V 交给访达移动后由访达撤销的结果一致
            outcome = UndoExecutor.run(record, trash: { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) })
        }

        let action = UndoText.actionDescription(kind: record.kind, count: record.count, name: record.name, localize: L)
        let message = UndoText.feedback(for: record, outcome: outcome, localize: L)
        ClipboardToast.show(message: message, style: Self.toastStyle(outcome.status))
        RecentOperations.shared.record(OperationRecord(
            kind: .undo, subject: action,
            failure: outcome.skipped.isEmpty ? nil : message,
            results: outcome.undone))
        serviceLog("undo \(record.kind.rawValue): undone=\(outcome.undone.count) skipped=\(outcome.skipped.count)")
    }

    /// 撤销剪切：把剪切队列原样写回这次剪切之前的内容
    private func restoreCutQueue(_ before: [String]) -> UndoOutcome {
        Self.cutPasteQueue.sync {
            do {
                try cutQueue.write(before)
            } catch {
                return UndoOutcome(skipped: [.init(name: L("剪切队列"), reason: .failed(error.localizedDescription))])
            }
            CutQueueChangeNotifier.post()
            FinderShortcutInterceptor.shared.mirrorCutQueue(before)
            // 写回的队列里可能有剪切之后才被移走的项，交给核对剔除，并改为监视写回后的这些文件夹
            Self.scheduleRemovalCheck()
            return UndoOutcome()
        }
    }

    private static func toastStyle(_ status: UndoOutcome.Status) -> ClipboardToast.Style {
        switch status {
        case .success: return .success
        case .partial: return .partial
        case .failure: return .failure
        }
    }
}
