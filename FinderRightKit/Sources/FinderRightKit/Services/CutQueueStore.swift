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
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

    /// 用户取消剪切：清空待剪切队列，并作废所有批次及旧版本的恢复记录。
    public func clear() {
        let fm = FileManager.default
        try? fm.removeItem(at: queueURL)
        for url in (try? inflightFiles()) ?? [] {
            try? fm.removeItem(at: url)
        }
    }

    /// 原子领取本批队列。改名失败时保留待剪切队列，拒绝开始无恢复保障的移动。
    public func take() throws -> (id: UUID, paths: [String])? {
        let paths = read()
        guard !paths.isEmpty else { return nil }
        let id = UUID()
        try FileManager.default.moveItem(at: queueURL, to: inflightURL(for: id))
        return (id, paths)
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
        let files = try inflightFiles()
        guard !files.isEmpty else { return read() }
        var merged = read()
        var recoveredFiles: [URL] = []
        for url in files {
            let paths: [String]
            do {
                paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
            } catch {
                NSLog("[CutQueueStore] 无法读取恢复记录，保留文件 %@: %@", url.lastPathComponent, error.localizedDescription)
                continue
            }
            recoveredFiles.append(url)
            for p in paths where !merged.contains(p) {
                merged.append(p)
            }
        }
        guard !recoveredFiles.isEmpty else { return read() }
        if existingOnly {
            merged = merged.filter { FileManager.default.fileExists(atPath: $0) }
        }
        try write(merged)
        for url in recoveredFiles {
            try FileManager.default.removeItem(at: url)
        }
        return merged
    }

    private func inflightFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { url in
                let name = url.lastPathComponent
                if name == Self.inflightFileName { return true }
                guard name.hasPrefix(Self.batchPrefix), name.hasSuffix(".json") else { return false }
                return UUID(uuidString: String(name.dropFirst(Self.batchPrefix.count).dropLast(5))) != nil
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
