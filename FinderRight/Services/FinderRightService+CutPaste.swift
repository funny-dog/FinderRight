import Foundation
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

// MARK: - 剪切 / 粘贴

extension FinderRightService {

    // MARK: - 剪切 / 粘贴（Lazy Cut 延迟剪切）

    /// 剪切：Lazy Cut（延迟剪切）。只记录待剪切文件路径到 cut-queue.json，
    /// 不立即移动物理文件，避免跨卷拷贝撑爆磁盘和未粘贴前文件丢失假象。
    func cutFiles(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue, !paths.isEmpty else {
            return IPCResponse(id: req.id, success: false, message: "cutFiles 参数缺失：paths")
        }

        // 收敛到 cutPasteQueue 串行队列，确保 cut-queue.json 互斥访问
        let result: (response: IPCResponse, before: [String], added: Int) = Self.cutPasteQueue.sync {
            let fileManager = FileManager.default

            // 过滤出实际存在的源文件路径
            let validPaths = paths.filter { fileManager.fileExists(atPath: $0) }
            guard !validPaths.isEmpty else {
                return (IPCResponse(id: req.id, success: false, message: L("选中的文件均不存在")), [], 0)
            }

            // 读取现有剪切队列并过滤掉外部已删除的文件
            var queue = cutQueue.read().filter { fileManager.fileExists(atPath: $0) }
            let before = queue

            // 合并并去重
            for p in validPaths {
                if !queue.contains(p) {
                    queue.append(p)
                }
            }

            do {
                try cutQueue.write(queue)
            } catch {
                return (IPCResponse(id: req.id, success: false, message: String(format: L("写入剪切队列失败：%@"), error.localizedDescription)), [], 0)
            }
            // 经服务快捷键剪切时扩展不知情，靠通知让它打上角标
            CutQueueChangeNotifier.post()
            // 剪切 / 粘贴快捷键生效时把整个队列放进剪贴板，右键剪切后按粘贴键也能交给访达移动
            FinderShortcutInterceptor.shared.mirrorCutQueue(queue)

            return (IPCResponse(id: req.id, success: true, message: "已剪切 \(validPaths.count) 个文件"),
                    before, queue.count - before.count)
        }
        // 全是已在队列里的项时没有新动作，不覆盖上一条撤销记录
        if result.added > 0 {
            registerUndo(.cut, name: "", items: [], cutQueueBefore: result.before, displayCount: result.added)
            RecentOperations.shared.record(OperationRecord(kind: .cut, subject: Self.subject(forPaths: paths),
                                                            results: paths.map { URL(fileURLWithPath: $0) },
                                                            location: paths.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent() }))
        } else if !result.response.success {
            RecentOperations.shared.record(OperationRecord(kind: .cut, subject: Self.subject(forPaths: paths),
                                                            failure: result.response.message))
        }
        return result.response
    }

    /// 取消剪切：清空剪切队列。
    ///
    /// 连续剪切决策上保留「累加 / 合并」语义（不改成 Windows 的替换语义），
    /// 因此需要一个显式入口让用户清空队列、让角标消失。
    /// 注意：只能取消尚未被粘贴取走的队列。已经被 takeCutQueue() 取走、正在移动的文件
    /// 无法撤回，但代次自增会让这批任务结束后不再把失败路径归还回队列（取消必须赢）。
    func cancelCut(_ req: IPCRequest) -> IPCResponse {
        // 与剪切/粘贴共用串行队列，避免与正在执行中的粘贴互踩 cut-queue.json
        let response = Self.cutPasteQueue.sync {
            Self.cutCancelGeneration += 1
            cutQueue.clear()
            CutQueueChangeNotifier.post()
            return IPCResponse(id: req.id, success: true, message: "已取消剪切")
        }
        // 剪切已被取消或已被 ⌘V 交给访达移动，剪切记录作废
        UndoCenter.shared.invalidate(kind: .cut)
        return response
    }

    static func pendingCutPaths() -> [String] {
        cutPasteQueue.sync { CutQueueStore().read() }
    }

    /// 菜单栏入口与 IPC 剪切/粘贴共用短事务，避免快照过期后移除在途项目。
    static func removePendingCutPath(_ path: String) throws {
        try cutPasteQueue.sync {
            let remaining = try CutQueueStore().remove(path)
            UndoCenter.shared.revalidate { $0.pruningRemovedItems(cutQueue: remaining) }
            CutQueueChangeNotifier.post()
            FinderShortcutInterceptor.shared.refreshCutQueueMirror(remaining)
        }
        scheduleRemovalCheck()
    }

    /// 在 cutPasteQueue 短事务中一次性取走当前剪切队列，并记录取走时的取消代次
    private func takeCutQueue() throws -> (id: UUID, paths: [String], generation: Int)? {
        try Self.cutPasteQueue.sync {
            guard let batch = try cutQueue.take() else { return nil }
            // 队列已被取走：通知扩展清掉源文件上的剪切角标
            CutQueueChangeNotifier.post()
            // 剪切在取走这一刻就被粘贴用掉：移动途中不能再「撤销剪切」，粘贴完成后登记的是粘贴记录
            UndoCenter.shared.invalidate(kind: .cut)
            return (batch.id, batch.paths, Self.cutCancelGeneration)
        }
    }

    func pasteFiles(_ req: IPCRequest) -> IPCResponse {
        guard let destPath = req.payload["destination"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "pasteFiles 参数缺失：destination")
        }
        let destDir = URL(fileURLWithPath: destPath)

        let taken: (id: UUID, paths: [String], generation: Int)
        do {
            guard let batch = try takeCutQueue() else {
                return IPCResponse(id: req.id, success: false, message: L("剪切队列为空，请先剪切文件"))
            }
            taken = batch
        } catch {
            return IPCResponse(id: req.id, success: false, message: String(format: L("保存粘贴恢复记录失败：%@"), error.localizedDescription))
        }

        // 异步派发到独立 pasteQueue 工作队列，物理移动不阻塞 cutPasteQueue 队列
        Self.backgroundJobs.run(on: Self.pasteQueue) { [weak self] in
            self?.performPaste(batchID: taken.id, sourcePaths: taken.paths, destDir: destDir, generation: taken.generation)
        }

        return IPCResponse(id: req.id, success: true, message: "已受理粘贴请求，正在后台移动文件")
    }

    /// 结算本批粘贴：归还失败路径和清理记录都在剪切队列的短事务内完成。
    /// 取消代次变化时只清理本批；写回失败则保留记录，供下次启动恢复。
    private func finishPaste(batchID: UUID, failedPaths: [String], generation: Int) {
        Self.cutPasteQueue.sync {
            do {
                let retryPaths = generation == Self.cutCancelGeneration ? failedPaths : []
                try cutQueue.finish(batchID, retrying: retryPaths)
                if !retryPaths.isEmpty {
                    CutQueueChangeNotifier.post()
                    Self.scheduleRemovalCheck()
                }
            } catch {
                serviceLog("粘贴结算失败，保留本批恢复记录: \(error.localizedDescription)")
            }
        }
    }

    private func performPaste(batchID: UUID, sourcePaths: [String], destDir: URL, generation: Int) {
        let fileManager = FileManager.default
        var firstError: String?
        var pastedPaths: [URL] = []
        var pastedPairs: [(current: URL, original: URL?)] = []
        var failedPaths: [String] = []

        for sourcePath in sourcePaths {
            // 防御性校验：cut-queue.json 是普通文件，可能被其他进程直接改写；
            // 剪切时虽已校验过白名单，粘贴执行前必须对队列内容再校验一次。
            guard isPathAllowed(sourcePath, role: .source) else {
                serviceLog("粘贴源路径越界被拦截: \(sourcePath)")
                continue
            }
            let sourceURL = URL(fileURLWithPath: sourcePath)

            // 若源文件已被外部删除或不存在，则跳过且不作为待重试项保留在队列中
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }

            // 粘贴目标目录与源文件所在目录相同 → 跳过该文件（视为无操作），不生成副本，并从队列剔除
            if sourceURL.deletingLastPathComponent().path == destDir.path {
                continue
            }

            // 目标已存在则自动重命名避免冲突（与新建文件共用 UniqueName 规则：name 1.ext、name 2.ext…）
            let destURL = UniqueName.fileURL(baseName: sourceURL.deletingPathExtension().lastPathComponent,
                                             ext: sourceURL.pathExtension,
                                             in: destDir)

            do {
                try fileManager.moveItem(at: sourceURL, to: destURL)
                pastedPaths.append(destURL)
                pastedPairs.append((destURL, sourceURL))
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
                failedPaths.append(sourcePath)
            }
        }

        finishPaste(batchID: batchID, failedPaths: failedPaths, generation: generation)

        if !pastedPaths.isEmpty {
            registerUndo(.paste, name: destDir.lastPathComponent, items: pastedPairs)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting(pastedPaths)
            }
        }

        let subject = Self.subject(forPaths: sourcePaths)
        if let err = firstError {
            serviceLog("pasteFiles completed with error: \(err)")
            RecentOperations.shared.record(OperationRecord(
                kind: .paste, subject: subject,
                failure: String(format: L("%d 项未能移动：%@"), failedPaths.count, err),
                results: pastedPaths, location: destDir))
        } else {
            serviceLog("pasteFiles succeeded: moved \(pastedPaths.count) items to \(destDir.path)")
            // 全部被跳过（源已不存在、或粘贴回原目录）时没有可报告的结果
            if !pastedPaths.isEmpty {
                RecentOperations.shared.record(OperationRecord(kind: .paste, subject: subject, results: pastedPaths, location: destDir))
            }
        }
    }

    /// 主 App 启动时归还上次崩溃残留的 in-flight 队列。
    ///
    /// 粘贴开始时队列会被原子改名为 in-flight 标记；若主 App 在移动过程中被杀（崩溃、强退、
    /// 断电），标记会残留在磁盘上，这里把其中的源文件并回队列，避免用户丢失剪切状态。
    /// 只保留仍存在的源文件：已经移动成功的路径不再回到队列。
    static func recoverInflightCutQueue() {
        do {
            let restored = try CutQueueStore().recover(existingOnly: true)
            if !restored.isEmpty {
                CutQueueChangeNotifier.post()
                NSLog("[FinderRightService] 已恢复中断粘贴的剪切队列: \(restored.count) 条")
            }
        } catch {
            NSLog("[FinderRightService] 剪切队列恢复失败，保留恢复记录: \(error)")
        }
        // 上次退出后剪切队列里的文件可能已被删除或移进废纸篓
        scheduleRemovalCheck()
    }

    // MARK: - 跟进被外部移走的项

    /// 核对专用串行队列，FSEvents 回调也在这里执行
    private static let removalQueue = DispatchQueue(label: "com.finderright.app.removal", qos: .utility)

    /// 监视剪切队列与撤销记录涉及的文件夹
    private static let removalWatcher = DirectoryWatcher(queue: removalQueue) { reconcileRemovedItems() }

    /// 剪切队列或撤销记录变化后调用：马上核对一次，并改为监视它们现在涉及的文件夹
    static func scheduleRemovalCheck() {
        removalQueue.async { reconcileRemovedItems() }
    }

    /// 剪切队列与撤销记录里的项被移进废纸篓、删除、改名或挪走后，把它们剔除。
    /// 否则角标、「粘贴（已剪切 N 项）」与「撤销…」菜单都还在，点了才发现什么也做不了。
    /// 只能在 removalQueue 上执行
    private static func reconcileRemovedItems() {
        let fileManager = FileManager.default
        let store = CutQueueStore()
        let queue: [String] = cutPasteQueue.sync {
            let stored = store.read()
            var queue = stored
            let existing = stored.filter { fileManager.fileExists(atPath: $0) }
            if existing != stored {
                do {
                    try store.write(existing)
                    queue = existing
                    CutQueueChangeNotifier.post()
                    FinderShortcutInterceptor.shared.refreshCutQueueMirror(existing)
                    NSLog("[FinderRightService] 剪切队列剔除已不存在的项: \(stored.count - existing.count) 项")
                } catch {
                    NSLog("[FinderRightService] 剪切队列剔除失败: \(error.localizedDescription)")
                }
            }
            // 必须与读写剪切队列在同一个事务里：剪切总是先写队列再登记记录，
            // 这样修订剪切记录时读到的队列一定包含它新增的项，不会误判为「已全部移走」
            if UndoCenter.shared.revalidate({ $0.pruningRemovedItems(cutQueue: queue) }) {
                NSLog("[FinderRightService] 撤销记录已按现有文件修订: \(UndoCenter.shared.current.map { "\($0.kind.rawValue) \($0.count)" } ?? "已作废")")
            }
            return queue
        }

        var directories = Set(queue.map { ($0 as NSString).deletingLastPathComponent })
        for item in UndoCenter.shared.current?.items ?? [] {
            directories.insert(item.current.deletingLastPathComponent().path)
        }
        removalWatcher.watch(directories)
    }
}
