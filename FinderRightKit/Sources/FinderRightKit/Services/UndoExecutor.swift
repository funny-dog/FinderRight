import Foundation

/// 一次撤销的结果：哪些项撤销了，哪些跳过了、为什么。
public struct UndoOutcome: Equatable {

    public enum SkipReason: Equatable {
        /// 操作后的位置上已经没有它（被删除、改名或挪走）
        case missing
        /// 还在，但已被修改或替换成别的文件
        case modified
        /// 原位置已有同名项目：绝不覆盖
        case originalOccupied
        /// 原来所在的文件夹已不存在
        case originalFolderMissing
        /// 移动或送进废纸篓时出错
        case failed(String)
    }

    public struct Skip: Equatable {
        public let name: String
        public let reason: SkipReason

        public init(name: String, reason: SkipReason) {
            self.name = name
            self.reason = reason
        }
    }

    public enum Status: Equatable {
        case success, partial, failure
    }

    /// 撤销成功的项：移回后的原路径，或被送进废纸篓的项目在撤销前的路径
    public var undone: [URL]
    public var skipped: [Skip]

    public init(undone: [URL] = [], skipped: [Skip] = []) {
        self.undone = undone
        self.skipped = skipped
    }

    public var status: Status {
        if skipped.isEmpty { return .success }
        return undone.isEmpty ? .failure : .partial
    }
}

/// 按记录逐项撤销。不硬撤销：任何一项不满足条件就跳过并记下原因，其余照常处理。
public enum UndoExecutor {

    /// - trash: 送进废纸篓的实现（主 App 传 `FileManager.trashItem`，测试传临时目录）
    public static func run(_ record: UndoRecord, fileManager: FileManager = .default,
                           trash: (URL) throws -> Void) -> UndoOutcome {
        var outcome = UndoOutcome()
        for item in record.items {
            let name = item.current.lastPathComponent
            guard let now = FileFingerprint.capture(item.current) else {
                outcome.skipped.append(.init(name: name, reason: .missing))
                continue
            }
            guard now.matches(item.fingerprint) else {
                outcome.skipped.append(.init(name: name, reason: .modified))
                continue
            }
            if record.restoresByMoving, let original = item.original {
                guard directoryExists(original.deletingLastPathComponent(), fileManager: fileManager) else {
                    outcome.skipped.append(.init(name: name, reason: .originalFolderMissing))
                    continue
                }
                // 不用 fileExists：它跟随符号链接，悬空链接会被当成不存在而被覆盖
                guard (try? fileManager.attributesOfItem(atPath: original.path)) == nil else {
                    outcome.skipped.append(.init(name: name, reason: .originalOccupied))
                    continue
                }
                do {
                    try fileManager.moveItem(at: item.current, to: original)
                    outcome.undone.append(original)
                } catch {
                    outcome.skipped.append(.init(name: name, reason: .failed(error.localizedDescription)))
                }
            } else {
                do {
                    try trash(item.current)
                    outcome.undone.append(item.current)
                } catch {
                    outcome.skipped.append(.init(name: name, reason: .failed(error.localizedDescription)))
                }
            }
        }
        return outcome
    }

    private static func directoryExists(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
