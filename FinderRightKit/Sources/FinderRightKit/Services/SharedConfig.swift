import Foundation
import AppKit
import Darwin

// MARK: - 文件模板

/// 自定义文件模板
public struct FileTemplate: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var fileExtension: String
    public var content: String

    public init(id: String = UUID().uuidString, name: String, fileExtension: String, content: String) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension
        self.content = content
    }
}

// MARK: - 文件共享配置管理（无需 App Group）

/// 基于文件的共享配置管理器，存储在 ~/Library/Application Support/FinderRight/settings.plist
/// 替代 App Group UserDefaults，避免需要开发者账号和 Provisioning Profile
public final class SharedConfig {

    /// 共享配置文件路径。
    ///
    /// 复用 `IPCBridge.rootDirectory`（真实 home 下的硬编码路径），绕过沙箱重定向。
    /// 若用 `FileManager` 的 `.applicationSupportDirectory`，沙箱化的 FinderSync 扩展
    /// 会被重定向到沙箱容器内的私有目录，从而读不到主 App（非沙箱）写入的配置。
    public static let sharedFileURL: URL = {
        let dir = IPCBridge.rootDirectory
        try? PrivateStorage.ensurePrivateDirectory(dir)
        return dir.appendingPathComponent("settings.plist")
    }()

    /// 单例
    public static let shared = SharedConfig()

    let lock = NSRecursiveLock()
    let configFileURL: URL

    var store: [String: Any] = [:]
    /// 最近一次从磁盘读取或成功写入的完整快照，用于识别本实例真正改过的键。
    private var baselineStore: [String: Any] = [:]
    private var lastLoadedMtime: Date?

    enum Keys {
        static let enabledActions = "enabledActions"
        static let developerToolsEnabled = "developerToolsEnabled"
        static let developerMenuOrder = "developerMenuOrder"
        static let developerCommands = "developerCommands"
        static let menuIconStyle = "menuIconStyle"
        static let preferredTerminal = "preferredTerminal"
        static let selectedTerminals = "selectedTerminals"
        static let terminalOrder = "terminalOrder"
        static let preferredEditor = "preferredEditor"
        static let editorOrder = "editorOrder"
        static let customEditors = "customEditors"
        static let hiddenEditors = "hiddenEditors"
        static let customFileTemplates = "customFileTemplates"
        static let newFileOrder = "newFileOrder"
        static let newFileFromClipboard = "newFileFromClipboard"
        static let clipboardTextFileExtension = "clipboardTextFileExtension"
        static let clipboardImageFileExtension = "clipboardImageFileExtension"
        static let hiddenNewFileTemplates = "hiddenNewFileTemplates"
        static let removedNewFileTemplates = "removedNewFileTemplates"
        static let appLanguage = "appLanguage"
        static let shortcuts = "shortcuts"
        static let globalOpenPathShortcut = "globalOpenPathShortcut"
        static let badgeOwnershipReclaim = "badgeOwnershipReclaim"
        static let copyPathFormat = "copyPathFormat"
        static let copyFileNameFormat = "copyFileNameFormat"
        static let menuOrder = "menuOrder"
        static let favoriteDirectories = "favoriteDirectories"
        static let favoriteSortByRecent = "favoriteSortByRecent"
        static let favoriteLastUsed = "favoriteLastUsed"
        static let appTheme = "appTheme"
        static let copyFileContentMaxSizeKB = "copyFileContentMaxSizeKB"
        static let recentGitRepositories = "recentGitRepositories"
        /// 一次性迁移标记：图标风格默认值已按「老用户保持单色线条」处理过
        static let iconStyleDefaultMigrated = "iconStyleDefaultMigrated"
    }

    public init(fileURL: URL = SharedConfig.sharedFileURL) {
        self.configFileURL = fileURL
        load()
        migrateIconStyleDefaultIfNeeded()
    }

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = configFileURL
        // 检查文件修改时间，若与上次载入一致且已有缓存，则跳过重复磁盘读取与反序列化
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            if let last = lastLoadedMtime, last == mtime, !store.isEmpty {
                return
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                store = [:]
                baselineStore = [:]
                lastLoadedMtime = nil
                return
            }
            store = dict
            baselineStore = dict
            lastLoadedMtime = mtime
            return
        }

        store = [:]
        baselineStore = [:]
        lastLoadedMtime = nil
    }

    /// 在跨进程锁内重新读盘，只应用本实例相对基线修改或删除的键。
    func save() {
        lock.lock()
        defer { lock.unlock() }
        withDiskLock {
            var merged = try readDiskStore()
            let keys = Set(baselineStore.keys).union(store.keys)
            for key in keys where !Self.valuesEqual(baselineStore[key], store[key]) {
                if let value = store[key] {
                    merged[key] = value
                } else {
                    merged.removeValue(forKey: key)
                }
            }
            try writeStore(merged)
        }
    }

    /// 只合并单个键写回磁盘，供窗口位置这类「跨进程频繁写入」使用。
    func writeKeyMergingOnDisk(_ key: String, value: Any) {
        lock.lock()
        defer { lock.unlock() }
        withDiskLock {
            var dict = try readDiskStore()
            dict[key] = value
            try writeStore(dict)
        }
    }

    private func readDiskStore() throws -> [String: Any] {
        do {
            let data = try Data(contentsOf: configFileURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let dict = plist as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            return dict
        } catch {
            if Self.isMissingFile(error) { return [:] }
            throw error
        }
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError))
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    /// 调用方必须已持有进程内锁与磁盘锁。
    private func writeStore(_ dict: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: configFileURL, options: .atomic)
        PrivateStorage.restrictFile(configFileURL)
        store = dict
        baselineStore = dict
        if let attrs = try? FileManager.default.attributesOfItem(atPath: configFileURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            lastLoadedMtime = mtime
        }
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let lhs?, let rhs?):
            let left = try? PropertyListSerialization.data(fromPropertyList: ["value": lhs], format: .binary, options: 0)
            let right = try? PropertyListSerialization.data(fromPropertyList: ["value": rhs], format: .binary, options: 0)
            return left != nil && left == right
        default: return false
        }
    }

    /// NSRecursiveLock 只保护单个实例；flock 保护不同 App / 扩展进程间的读-改-写事务。
    private func withDiskLock(_ body: () throws -> Void) {
        let directory = configFileURL.deletingLastPathComponent()
        try? PrivateStorage.ensurePrivateDirectory(directory)
        let lockURL = directory.appendingPathComponent("settings.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            NSLog("[SharedConfig] 无法打开配置锁，errno=%d；保留内存修改", errno)
            return
        }
        defer { close(fd) }
        PrivateStorage.restrictFile(lockURL)
        guard flock(fd, LOCK_EX) == 0 else {
            NSLog("[SharedConfig] 无法锁定配置，errno=%d；保留内存修改", errno)
            return
        }
        defer { flock(fd, LOCK_UN) }
        do {
            try body()
        } catch {
            let error = error as NSError
            NSLog("[SharedConfig] 配置写事务失败（%@:%ld）；保留内存修改", error.domain, error.code)
        }
    }

    /// 重新从磁盘加载配置。
    ///
    /// 单例在各进程内独立缓存，扩展进程需要在读取前调用此方法，
    /// 才能拿到主 App 设置界面刚写入磁盘的最新值（开关 / 终端 / 编辑器 / 快捷键）。
    public func reload() {
        load()
    }

    // MARK: - Reset

    /// 重置所有配置为默认值
    public func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        withDiskLock {
            try writeStore([:])
        }
    }
}

// MARK: - Window Position Memory

extension SharedConfig {
    
    public struct WindowPositionInfo: Codable, Identifiable {
        public var id: String // Window type identifier
        public var screenIdentifier: String? // Screen identifier for multi-monitor support
        public var originX: Double
        public var originY: Double
        public var sizeWidth: Double
        public var sizeHeight: Double
        
        public init(id: String, screenIdentifier: String?, originX: Double, originY: Double, width: Double, height: Double) {
            self.id = id
            self.screenIdentifier = screenIdentifier
            self.originX = originX
            self.originY = originY
            self.sizeWidth = width
            self.sizeHeight = height
        }
    }
    
    private enum WindowKeys {
        static let windowPositions = "windowPositions"
    }
    
    /// 窗口位置在设置文件里的原始表示，只供本扩展做读-改-写。
    ///
    /// 不能像其他配置那样走 `store`：主 App 的窗口回调只持有启动时的缓存，
    /// 若直接写 `store` 再整体 `save()` 会把别的进程刚写入的快捷键、模板等键回滚。
    /// 因此这里每次都重新读盘，在同一把锁内合并后立即回写。
    private var windowPositionsRaw: [[String: Any]] {
        guard let data = try? Data(contentsOf: configFileURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let windows = dict[WindowKeys.windowPositions] as? [[String: Any]] else {
            return []
        }
        return windows
    }

    public private(set) var windowPositions: [WindowPositionInfo] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return windowPositionsRaw.compactMap { dict -> WindowPositionInfo? in
                guard let id = dict["id"] as? String,
                      let originX = dict["originX"] as? Double,
                      let originY = dict["originY"] as? Double,
                      let width = dict["width"] as? Double,
                      let height = dict["height"] as? Double else {
                    return nil
                }
                let screenIdentifier = dict["screenIdentifier"] as? String
                return WindowPositionInfo(
                    id: id,
                    screenIdentifier: screenIdentifier?.isEmpty == false ? screenIdentifier : nil,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            }
        }
        set {
            writeKeyMergingOnDisk(WindowKeys.windowPositions, value: Self.encode(newValue))
        }
    }

    private static func encode(_ positions: [WindowPositionInfo]) -> [[String: Any]] {
        positions.map { info -> [String: Any] in
            [
                "id": info.id,
                "screenIdentifier": info.screenIdentifier ?? "",
                "originX": info.originX,
                "originY": info.originY,
                "width": info.sizeWidth,
                "height": info.sizeHeight
            ]
        }
    }
    
    /// 保存窗口位置（简化版）
    ///
    /// 只在锁内合并「窗口位置」这一个键：先读盘取最新列表，再写回磁盘。
    /// 这样同时能保留其他进程刚写入的配置，也不会因为整份 `store` 陈旧而回滚设置。
    public func saveWindowPosition(for windowType: String, frame: NSRect) {
        lock.lock()
        defer { lock.unlock() }
        var currentPositions = windowPositionsRaw
        let record: [String: Any] = [
            "id": windowType,
            "screenIdentifier": NSScreen.screenIdentifier(containing: frame) ?? "",
            "originX": frame.origin.x,
            "originY": frame.origin.y,
            "width": frame.size.width,
            "height": frame.size.height
        ]
        if let index = currentPositions.firstIndex(where: { $0["id"] as? String == windowType }) {
            currentPositions[index] = record
        } else {
            currentPositions.append(record)
        }
        writeKeyMergingOnDisk(WindowKeys.windowPositions, value: currentPositions)
    }

    /// 恢复窗口位置
    ///
    /// 保存位置所在的屏幕已不存在（外接屏拔掉等）时返回 nil，交给调用方居中显示，
    /// 免得把窗口恢复到不可见的坐标。
    public func restoreWindowPosition(for windowType: String) -> NSRect? {
        lock.lock()
        let info = windowPositions.first { $0.id == windowType }
        lock.unlock()
        guard let info else { return nil }
        let frame = NSRect(
            origin: NSPoint(x: info.originX, y: info.originY),
            size: CGSize(width: info.sizeWidth, height: info.sizeHeight)
        )
        guard NSScreen.screenIdentifier(containing: frame) != nil else { return nil }
        return frame
    }

    /// 清除特定窗口的记忆位置
    public func clearWindowPosition(for windowType: String) {
        lock.lock()
        defer { lock.unlock() }
        var currentPositions = windowPositionsRaw
        currentPositions.removeAll { $0["id"] as? String == windowType }
        writeKeyMergingOnDisk(WindowKeys.windowPositions, value: currentPositions)
    }

    /// 清除所有窗口位置记忆
    public func clearAllWindowPositions() {
        writeKeyMergingOnDisk(WindowKeys.windowPositions, value: [[String: Any]]())
    }
}

private extension NSScreen {
    /// 用屏幕可见区域中心点判断所在屏幕。窗口跨屏时以中心点归属为准，
    /// 与 AppKit 恢复窗口时的常规判断一致。
    static func screenIdentifier(containing frame: NSRect) -> String? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return screens.first { $0.frame.contains(center) }?.localizedName
    }
}

/// 菜单项快捷键（key + 修饰键）
public struct ActionShortcut: Codable, Equatable {
    /// 单字符按键（小写），如 "x"、"v"
    public var key: String
    /// NSEvent.ModifierFlags.rawValue（只含 command/option/shift/control）
    public var modifiers: Int

    public init(key: String, modifiers: Int) {
        self.key = key
        self.modifiers = modifiers
    }
}
