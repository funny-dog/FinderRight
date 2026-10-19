import Foundation

/// 给扩展看的撤销状态：只有显示菜单项所需的信息，不含任何路径。
/// 文件存在即表示「现在有可撤销的操作」。
public struct UndoMenuState: Codable, Equatable {
    public let kind: UndoRecord.Kind
    public let count: Int
    public let name: String

    public static let fileName = "undo-state.json"

    public init(kind: UndoRecord.Kind, count: Int, name: String) {
        self.kind = kind
        self.count = count
        self.name = name
    }

    public static func read(from directory: URL = IPCBridge.rootDirectory) -> UndoMenuState? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder().decode(UndoMenuState.self, from: data)
    }
}

/// 撤销快捷键在拦截回调里的去向
public enum UndoShortcutDecision: Equatable {
    /// 交给访达（FinderRight 没有可撤销的记录，或访达之后又做过可撤销的操作）
    case passThrough
    /// 吞掉按键，撤销 FinderRight 的记录
    case undo
    /// 撤销进行中：吞掉按键，不重复执行，也不能落到访达手里撤销别的东西
    case ignore
}

/// 全局唯一的撤销记录（单级撤销）。主 App 各处串行或并发调用，内部加锁。
///
/// 记录只存内存；同时把显示信息写进共享目录的 `undo-state.json`，供沙箱扩展决定是否显示撤销菜单项。
public final class UndoCenter {

    public static let shared = UndoCenter(stateDirectory: IPCBridge.rootDirectory)

    private let stateURL: URL
    private let lock = NSLock()
    private var record: UndoRecord?
    private var undoing = false

    public init(stateDirectory: URL) {
        stateURL = stateDirectory.appendingPathComponent(UndoMenuState.fileName)
    }

    /// 登记一次新操作，覆盖旧记录。displayCount 用于剪切这类没有 items 的记录
    public func register(_ record: UndoRecord, displayCount: Int? = nil) {
        var record = record
        if let displayCount { record.displayCount = displayCount }
        locked {
            self.record = record
            writeState(UndoMenuState(kind: record.kind, count: record.count, name: record.name))
        }
    }

    public var current: UndoRecord? {
        locked { record }
    }

    /// 取走记录准备撤销；没有记录或已在撤销中时返回 nil
    public func beginUndo() -> UndoRecord? {
        locked {
            guard !undoing, let taken = record else { return nil }
            undoing = true
            record = nil
            removeState()
            return taken
        }
    }

    /// 撤销结束：只清除「撤销中」标记，撤销期间登记的新记录保留
    public func endUndo() {
        locked { undoing = false }
    }

    /// 当前记录是该类型时作废（如用户主动取消剪切后，剪切记录就不该再被撤销）
    public func invalidate(kind: UndoRecord.Kind) {
        locked {
            guard record?.kind == kind else { return }
            record = nil
            removeState()
        }
    }

    /// 清空记录与状态文件。App 启动与退出时调用，避免崩溃后残留的状态文件让扩展显示无效菜单项
    public func clear() {
        locked {
            record = nil
            removeState()
        }
    }

    /// 按访达撤销项当前的样子决定 ⌘Z 归谁。任何一方的快照读不到都交还访达，绝不误吞
    public func shortcutDecision(finderSnapshot: FinderUndoSnapshot?) -> UndoShortcutDecision {
        locked {
            if undoing { return .ignore }
            guard let recorded = record?.finderSnapshot, let finderSnapshot, recorded == finderSnapshot else {
                return .passThrough
            }
            return .undo
        }
    }

    // MARK: - 私有

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func writeState(_ state: UndoMenuState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    private func removeState() {
        try? FileManager.default.removeItem(at: stateURL)
    }
}
