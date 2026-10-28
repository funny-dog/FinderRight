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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
        static let hiddenNewFileTemplates = "hiddenNewFileTemplates"
        static let removedNewFileTemplates = "removedNewFileTemplates"
        static let appLanguage = "appLanguage"
        static let shortcuts = "shortcuts"
        static let badgeOwnershipReclaim = "badgeOwnershipReclaim"
        static let copyPathFormat = "copyPathFormat"
        static let copyFileNameFormat = "copyFileNameFormat"
        static let menuOrder = "menuOrder"
        static let favoriteDirectories = "favoriteDirectories"
        static let favoriteSortByRecent = "favoriteSortByRecent"
        static let favoriteLastUsed = "favoriteLastUsed"
        static let appTheme = "appTheme"
        static let copyFileContentMaxSizeKB = "copyFileContentMaxSizeKB"
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

    func save() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: store, format: .xml, options: 0) else { return }
        try? data.write(to: configFileURL, options: .atomic)
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

    // MARK: - Reset

    /// 重置所有配置为默认值
    public func resetToDefaults() {
        lock.lock()
        defer { lock.unlock() }
        store = [:]
        save()
    }
}

// MARK: - 快捷键模型

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
