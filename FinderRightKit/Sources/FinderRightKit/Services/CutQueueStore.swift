import Foundation

/// 剪切队列的文件存储（`cut-queue.json`）。
///
/// 放在 Kit 的原因：FinderSync 扩展与主 App 必须对同一份队列文件使用同一套路径与原子替换
/// 规则（扩展据此判断「粘贴 (已剪切 N 项)」与角标，主 App 负责写入与消费）。这里全部是纯文件
/// 操作，不依赖 AppKit / FinderSync，因此可以在无 Finder 环境的单元测试里覆盖。
///
/// 涉及两个文件：
///   - `cut-queue.json`           待粘贴的剪切队列
///   - `cut-queue.inflight.json`  粘贴执行期间的占用标记。`take()` 用原子改名产生，
///                                移动结束由 `finish()` 删除；若主 App 在移动中途被杀，
///                                标记会残留，下次启动由 `recover()` 归还，避免剪切状态丢失。
public struct CutQueueStore {

    public static let queueFileName = "cut-queue.json"
    public static let inflightFileName = "cut-queue.inflight.json"

    public let directory: URL

    public init(directory: URL = IPCBridge.rootDirectory) {
        self.directory = directory
    }

    public var queueURL: URL { directory.appendingPathComponent(Self.queueFileName) }
    public var inflightURL: URL { directory.appendingPathComponent(Self.inflightFileName) }

    // MARK: - 读

    /// 读取队列中的源文件路径。文件不存在、内容损坏或为空数组都返回 `[]`。
    public func read() -> [String] {
        guard let data = try? Data(contentsOf: queueURL),
              let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return paths
    }

    // MARK: - 写

    /// 原子写入队列。空列表等价于清空（删除文件，避免留下空数组文件让扩展误判为「有队列」）。
    public func write(_ paths: [String]) throws {
        guard !paths.isEmpty else {
            clear()
            return
        }
        let data = try JSONSerialization.data(withJSONObject: paths)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: queueURL, options: .atomic)
    }

    /// 与已有队列去重合并后写回：保留已有顺序，新路径追加到尾部。返回合并后的队列。
    @discardableResult
    public func appendUnique(_ paths: [String]) -> [String] {
        guard !paths.isEmpty else { return read() }
        var merged = read()
        for p in paths where !merged.contains(p) {
            merged.append(p)
        }
        try? write(merged)
        return merged
    }

    /// 清空队列，并一并作废 in-flight 标记（「取消剪切」语义：取消必须赢）
    public func clear() {
        let fm = FileManager.default
        try? fm.removeItem(at: queueURL)
        try? fm.removeItem(at: inflightURL)
    }

    // MARK: - 粘贴占用

    /// 取走当前队列：原子改名为 in-flight 标记后返回其中的路径；队列为空返回 `nil`。
    ///
    /// 改名失败时（例如目录权限异常）退回「读取 + 删除」的旧语义，宁可牺牲崩溃恢复，
    /// 也要保证同一份队列不会被两次粘贴重复移动。
    public func take() -> [String]? {
        let paths = read()
        guard !paths.isEmpty else { return nil }

        let fm = FileManager.default
        try? fm.removeItem(at: inflightURL)
        do {
            try fm.moveItem(at: queueURL, to: inflightURL)
        } catch {
            try? fm.removeItem(at: queueURL)
        }
        return paths
    }

    /// 粘贴流程结束（成功或失败路径都已归还）后调用：删除 in-flight 标记。
    public func finish() {
        try? FileManager.default.removeItem(at: inflightURL)
    }

    /// 崩溃恢复：把残留的 in-flight 路径并回队列并删除标记。
    /// - Parameter existingOnly: 只保留仍存在于磁盘上的源文件（已移动成功的路径不再回队列）
    /// - Returns: 恢复后的队列内容
    @discardableResult
    public func recover(existingOnly: Bool = true) -> [String] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: inflightURL.path) else { return read() }

        let inflight = (try? Data(contentsOf: inflightURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []

        var merged = read()
        for p in inflight where !merged.contains(p) {
            merged.append(p)
        }
        if existingOnly {
            merged = merged.filter { fm.fileExists(atPath: $0) }
        }

        try? write(merged)
        fm.removeItemIfExists(at: inflightURL)
        return merged
    }
}

private extension FileManager {
    /// `removeItem` 在文件不存在时会抛错，这里收敛成幂等删除
    func removeItemIfExists(at url: URL) {
        guard fileExists(atPath: url.path) else { return }
        try? removeItem(at: url)
    }
}
