import Foundation

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
        static let clipboardEnabled = "clipboardEnabled"
        static let clipboardHistoryLimit = "clipboardHistoryLimit"
        static let clipboardWindowPinned = "clipboardWindowPinned"
        static let clipboardShowDetails = "clipboardShowDetails"
        static let screenshotEnabled = "screenshotEnabled"
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
                lastLoadedMtime = nil
                return
            }
            store = dict
            lastLoadedMtime = mtime
            return
        }

        store = [:]
        lastLoadedMtime = nil
    }

    /// 原子写回磁盘；若磁盘已有文件但损坏无法解析，中止覆盖以免丢失原配置。
    func save() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try PrivateStorage.ensurePrivateDirectory(configFileURL.deletingLastPathComponent())
            if FileManager.default.fileExists(atPath: configFileURL.path) {
                let data = try Data(contentsOf: configFileURL)
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                guard plist is [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            }
            try writeStore(store)
        } catch {
            let error = error as NSError
            NSLog("[SharedConfig] 配置写事务失败（%@:%ld）；保留内存修改", error.domain, error.code)
        }
    }

    /// 调用方必须已持有进程内锁。
    private func writeStore(_ dict: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: configFileURL, options: .atomic)
        PrivateStorage.restrictFile(configFileURL)
        store = dict
        if let attrs = try? FileManager.default.attributesOfItem(atPath: configFileURL.path),
           let mtime = attrs[.modificationDate] as? Date {
            lastLoadedMtime = mtime
        }
    }

    /// 重新从磁盘加载配置。
    ///
    /// 单例在各进程内独立缓存，扩展进程需要在读取前调用此方法，
    /// 才能拿到主 App 设置界面刚写入磁盘的最新值（开关 / 终端 / 编辑器 / 快捷键）。
    public func reload() {
        load()
    }

    // MARK: - Clipboard

    /// 是否开启轻量剪贴板历史（默认开启）
    public var clipboardEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.clipboardEnabled] as? Bool ?? true
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.clipboardEnabled] = newValue
            save()
        }
    }

    /// 剪贴板历史最大记录条数（默认 5 条，支持 5 / 10 / 15 / 20）
    public var clipboardHistoryLimit: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            let raw = store[Keys.clipboardHistoryLimit] as? Int ?? ClipboardHistoryLimitPreset.defaultLimit
            return ClipboardHistoryLimitPreset.normalize(raw)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.clipboardHistoryLimit] = ClipboardHistoryLimitPreset.normalize(newValue)
            save()
        }
    }

    /// 剪贴板面板是否固定（默认不固定：复制或拖动成功后自动关闭）
    public var clipboardWindowPinned: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.clipboardWindowPinned] as? Bool ?? false
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.clipboardWindowPinned] = newValue
            save()
        }
    }

    /// 剪贴板面板是否展开右侧详情（默认关闭）
    public var clipboardShowDetails: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.clipboardShowDetails] as? Bool ?? false
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.clipboardShowDetails] = newValue
            save()
        }
    }

    // MARK: - Screenshot

    /// 是否开启轻量截图入口（默认关闭）
    public var screenshotEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.screenshotEnabled] as? Bool ?? false
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.screenshotEnabled] = newValue
            save()
        }
    }

    // MARK: - Reset

    /// 重置所有配置为默认值
    public func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        do {
            try PrivateStorage.ensurePrivateDirectory(configFileURL.deletingLastPathComponent())
            try writeStore([:])
        } catch {
            let error = error as NSError
            NSLog("[SharedConfig] 配置重置失败（%@:%ld）", error.domain, error.code)
        }
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
