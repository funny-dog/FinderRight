import Foundation

/// 文件在某一时刻的身份与状态，用来判断撤销时它是否还是当初那份、有没有被改过。
///
/// 用 `attributesOfItem` 读取：它不跟随符号链接，链接本身（哪怕指向不存在的目标）也能取到。
/// 跨卷移动等于复制，文件编号会变，所以必须在操作**完成后**、在新位置上取指纹。
public struct FileFingerprint: Equatable {
    public let fileNumber: UInt64
    public let device: Int
    public let isDirectory: Bool
    public let modificationDate: Date?
    /// 只对普通文件有意义；文件夹为 nil
    public let size: UInt64?

    public init(fileNumber: UInt64, device: Int, isDirectory: Bool, modificationDate: Date?, size: UInt64?) {
        self.fileNumber = fileNumber
        self.device = device
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.size = size
    }

    /// 不存在或读不到属性时返回 nil
    public static func capture(_ url: URL) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value,
              let device = (attrs[.systemNumber] as? NSNumber)?.intValue else { return nil }
        let isDirectory = (attrs[.type] as? FileAttributeType) == .typeDirectory
        return FileFingerprint(
            fileNumber: number, device: device, isDirectory: isDirectory,
            modificationDate: attrs[.modificationDate] as? Date,
            size: isDirectory ? nil : (attrs[.size] as? NSNumber)?.uint64Value)
    }

    /// 编号、设备、类型、修改时间一致才算同一份未改动的项目；普通文件另比大小。
    /// 文件夹只看顶层修改时间（增删直接子项会改变它），不深查内部：撤销只会把它移走或进废纸篓，可以恢复。
    public func matches(_ other: FileFingerprint) -> Bool {
        fileNumber == other.fileNumber && device == other.device && isDirectory == other.isDirectory
            && modificationDate == other.modificationDate && size == other.size
    }

    /// 只比编号与设备：是不是同一个项目，不管内容改没改。
    /// 用来区分「被移走 / 删掉后原路径换成了别的项目」与「还在原处只是被改过」
    public func isSameItem(as other: FileFingerprint) -> Bool {
        fileNumber == other.fileNumber && device == other.device
    }
}

/// 操作完成时访达「编辑 → 撤销」项的样子。之后访达每做一次可撤销操作，标题都会变；
/// 撤销后又回到原来的标题。⌘Z 时与它比较，即可判断 FinderRight 的操作是不是最近的那次。
public struct FinderUndoSnapshot: Equatable {
    public let title: String
    public let enabled: Bool

    public init(title: String, enabled: Bool) {
        self.title = title
        self.enabled = enabled
    }
}

/// FinderRight 最近一次可撤销操作的完整记录（只存内存）。
public struct UndoRecord: Equatable {

    public enum Kind: String, Codable {
        case move, copy, cut, paste, createFile, compress, decompress
    }

    public struct Item: Equatable {
        /// 操作后项目所在位置
        public let current: URL
        /// 操作前的位置；只有移动类（move / paste）有，撤销时移回这里
        public let original: URL?
        /// 操作完成时在 current 上取的指纹
        public let fingerprint: FileFingerprint

        public init(current: URL, original: URL?, fingerprint: FileFingerprint) {
            self.current = current
            self.original = original
            self.fingerprint = fingerprint
        }
    }

    public let kind: Kind
    /// 显示用名称：移动 / 复制 / 粘贴为目标文件夹名，新建 / 压缩 / 解压为产物名，剪切为空
    public let name: String
    public let items: [Item]
    /// 剪切专用：这次剪切之前的完整剪切队列，撤销时原样写回
    public let cutQueueBefore: [String]?
    /// 操作完成时读到的访达撤销项；读不到（未授权等）时为 nil，此时 ⌘Z 一律交还访达
    public let finderSnapshot: FinderUndoSnapshot?
    /// 显示用项数；剪切没有 items（不动文件），由登记方给出本次新增的项数
    public var displayCount: Int?

    public init(kind: Kind, name: String, items: [Item], cutQueueBefore: [String]?,
                finderSnapshot: FinderUndoSnapshot?, displayCount: Int? = nil) {
        self.kind = kind
        self.name = name
        self.items = items
        self.cutQueueBefore = cutQueueBefore
        self.finderSnapshot = finderSnapshot
        self.displayCount = displayCount
    }

    public var count: Int { displayCount ?? items.count }

    /// 撤销方式：移动类移回原处，其余（复制品、新建的文件、压缩包、解压产物）送进废纸篓
    public var restoresByMoving: Bool {
        kind == .move || kind == .paste
    }

    /// 去掉已经不在原处的项（被移进废纸篓、删除、改名或挪走）后的记录；没有可撤销的内容时返回 nil。
    /// 原处只是被改过的项保留，撤销时照常跳过并说明原因。
    ///
    /// - cutQueue: 当前剪切队列，须已剔除不存在的路径；只用于剪切记录。
    ///   剪切新增的项都已不在队列里时，撤销剪切不会再改变什么，记录作废
    /// - locate: 读取路径上项目的指纹（主 App 传 `FileFingerprint.capture`）
    public func pruningRemovedItems(cutQueue: [String],
                                    locate: (URL) -> FileFingerprint? = FileFingerprint.capture) -> UndoRecord? {
        if kind == .cut {
            let before = cutQueueBefore ?? []
            let added = cutQueue.filter { !before.contains($0) }
            guard !added.isEmpty else { return nil }
            // 之前就在队列里、后来被移走的项也不能在撤销时被写回队列
            let keptBefore = before.filter { cutQueue.contains($0) }
            return UndoRecord(kind: kind, name: name, items: items, cutQueueBefore: keptBefore,
                              finderSnapshot: finderSnapshot, displayCount: added.count)
        }
        let kept = items.filter { item in
            locate(item.current).map { $0.isSameItem(as: item.fingerprint) } ?? false
        }
        guard !kept.isEmpty else { return nil }
        guard kept.count != items.count else { return self }
        return UndoRecord(kind: kind, name: name, items: kept, cutQueueBefore: cutQueueBefore,
                          finderSnapshot: finderSnapshot, displayCount: displayCount)
    }
}
