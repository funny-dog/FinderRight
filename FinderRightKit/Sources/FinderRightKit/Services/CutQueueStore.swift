import Foundation

/// 剪切队列的文件存储，主 App 串行修改，FinderSync 扩展只读取待剪切队列。
/// `cut-queue.json` 是待粘贴队列；每批粘贴原子改名为独立的
/// `cut-queue.inflight.<UUID>.json`，完成时只清理本批，崩溃后合并恢复。
public struct CutQueueStore {

    public static let queueFileName = "cut-queue.json"
    /// 旧版本留下的恢复记录，启动恢复与取消剪切仍须处理。
    public static let inflightFileName = "cut-queue.inflight.json"
    private static let batchPrefix = "cut-queue.inflight."

    public let directory: URL

    public init(directory: URL = IPCBridge.rootDirectory) {
        self.directory = directory
    }

    public var queueURL: URL { directory.appendingPathComponent(Self.queueFileName) }
    public var inflightURL: URL { directory.appendingPathComponent(Self.inflightFileName) }

    public struct RecoveryConflict: Equatable {
        public let source: String
        public let destination: String

        public init(source: String, destination: String) {
            self.source = source
            self.destination = destination
        }
    }

    public struct RecoveryResult {
        public let restored: [String]
        public let conflicts: [RecoveryConflict]
    }

    private enum InflightPhase: String, Codable {
        case pending, moving, completed
    }

    private struct InflightItem: Codable {
        let source: String
        var destination: String?
        var phase: InflightPhase
    }

    private struct InflightBatch: Codable {
        var items: [InflightItem]
    }

    private func inflightURL(for id: UUID) -> URL {
        directory.appendingPathComponent(Self.batchPrefix + id.uuidString + ".json")
    }

    /// 文件不存在、内容损坏或为空数组都返回 `[]`。
    public func read() -> [String] {
        guard let data = try? Data(contentsOf: queueURL),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
    }

    /// 原子写入待剪切队列。空列表只清空待剪切项，不影响在途粘贴。
    public func write(_ paths: [String]) throws {
        guard !paths.isEmpty else {
            if FileManager.default.fileExists(atPath: queueURL.path) {
                try FileManager.default.removeItem(at: queueURL)
            }
            return
        }
        let data = try JSONEncoder().encode(paths)
        try PrivateStorage.ensurePrivateDirectory(directory)
        try data.write(to: queueURL, options: .atomic)
    }

    /// 保留已有顺序，新路径去重追加到尾部；写回失败必须传播，避免丢掉恢复记录。
    @discardableResult
    public func appendUnique(_ paths: [String]) throws -> [String] {
        guard !paths.isEmpty else { return read() }
        var merged = read()
        for p in paths where !merged.contains(p) {
            merged.append(p)
        }
        try write(merged)
        return merged
    }

    public enum RemovalError: Error {
        case pasteInProgress
    }

    /// 调用方须与 take/finish 共用串行队列；在途时拒绝修改，保留完整的失败恢复记录。
    @discardableResult
    public func remove(_ path: String) throws -> [String] {
        guard try inflightFiles().isEmpty else { throw RemovalError.pasteInProgress }
        let remaining = read().filter { $0 != path }
        try write(remaining)
        return remaining
    }

    /// 用户取消剪切：清空待剪切队列，并作废所有批次及旧版本的恢复记录。
    /// 仅把“文件已经不存在”视为成功，其余删除错误向上传递。
    public func clear() throws {
        let fm = FileManager.default
        try Self.removeIfExists(queueURL, fileManager: fm)
        for url in try inflightFiles() {
            try Self.removeIfExists(url, fileManager: fm)
        }
    }

    private static func removeIfExists(_ url: URL, fileManager: FileManager) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            if !isMissingFile(error) { throw error }
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    /// 原子领取本批队列。改名失败时保留待剪切队列，拒绝开始无恢复保障的移动。
    public func take() throws -> (id: UUID, paths: [String])? {
        let paths = read()
        guard !paths.isEmpty else { return nil }
        let id = UUID()
        try FileManager.default.moveItem(at: queueURL, to: inflightURL(for: id))
        return (id, paths)
    }

    /// 移动前记录预定目标。旧版记录仍是路径数组，第一次更新时升级为逐项批次。
    /// 文件已因取消剪切而删除时不重建批次，保持「取消不能撤回已取走粘贴」的现有语义。
    public func recordDestination(batchID: UUID, source: String, destination: String) throws {
        let url = inflightURL(for: batchID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var batch = try readBatch(from: url)
        guard let index = batch.items.firstIndex(where: { $0.source == source }) else { return }
        batch.items[index].destination = destination
        batch.items[index].phase = .moving
        try writeBatch(batch, to: url)
    }

    public func recordCompletion(batchID: UUID, source: String) throws {
        let url = inflightURL(for: batchID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var batch = try readBatch(from: url)
        guard let index = batch.items.firstIndex(where: { $0.source == source }) else { return }
        batch.items[index].phase = .completed
        try writeBatch(batch, to: url)
    }

    /// 先归还失败路径，再清理本批记录。已被取消的批次不能重新恢复剪切状态。
    public func finish(_ id: UUID, retrying paths: [String] = []) throws {
        let url = inflightURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try appendUnique(paths)
        try FileManager.default.removeItem(at: url)
    }

    /// 合并新旧恢复记录；先成功写回队列，再删除记录。已经移动的源路径不再恢复。
    @discardableResult
    public func recover(existingOnly: Bool = true) throws -> [String] {
        try recoverWithConflicts(existingOnly: existingOnly).restored
    }

    /// 源与预定目标同时存在时保留双方并报告冲突，不再把源入队后复制成新名字。
    public func recoverWithConflicts(existingOnly: Bool = true) throws -> RecoveryResult {
        let files = try inflightFiles()
        guard !files.isEmpty else { return RecoveryResult(restored: read(), conflicts: []) }
        let fileManager = FileManager.default
        var merged = read()
        var conflicts: [RecoveryConflict] = []
        var recoveredFiles: [URL] = []
        for url in files {
            let batch: InflightBatch
            do {
                batch = try readBatch(from: url)
            } catch {
                NSLog("[CutQueueStore] 无法读取恢复记录，保留文件 %@: %@", url.lastPathComponent, error.localizedDescription)
                continue
            }
            recoveredFiles.append(url)
            for item in batch.items where item.phase != .completed {
                let sourceExists = fileManager.fileExists(atPath: item.source)
                if existingOnly && !sourceExists { continue }
                if sourceExists, let destination = item.destination,
                   fileManager.fileExists(atPath: destination) {
                    merged.removeAll { $0 == item.source }
                    conflicts.append(RecoveryConflict(source: item.source, destination: destination))
                    continue
                }
                if !merged.contains(item.source) {
                    merged.append(item.source)
                }
            }
        }
        guard !recoveredFiles.isEmpty else {
            return RecoveryResult(restored: read(), conflicts: [])
        }
        if existingOnly {
            merged = merged.filter { fileManager.fileExists(atPath: $0) }
        }
        try write(merged)
        for url in recoveredFiles {
            try FileManager.default.removeItem(at: url)
        }
        return RecoveryResult(restored: merged, conflicts: conflicts)
    }

    private func readBatch(from url: URL) throws -> InflightBatch {
        let data = try Data(contentsOf: url)
        if let batch = try? JSONDecoder().decode(InflightBatch.self, from: data) {
            return batch
        }
        let paths = try JSONDecoder().decode([String].self, from: data)
        return InflightBatch(items: paths.map { InflightItem(source: $0, destination: nil, phase: .pending) })
    }

    private func writeBatch(_ batch: InflightBatch, to url: URL) throws {
        let data = try JSONEncoder().encode(batch)
        try PrivateStorage.ensurePrivateDirectory(directory)
        try data.write(to: url, options: .atomic)
        PrivateStorage.restrictFile(url)
    }

    private func inflightFiles() throws -> [URL] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            if Self.isMissingFile(error) { return [] }
            throw error
        }
        return files
            .filter { url in
                let name = url.lastPathComponent
                if name == Self.inflightFileName { return true }
                guard name.hasPrefix(Self.batchPrefix), name.hasSuffix(".json") else { return false }
                return UUID(uuidString: String(name.dropFirst(Self.batchPrefix.count).dropLast(5))) != nil
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
