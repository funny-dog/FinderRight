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

    private let lock = NSRecursiveLock()
    private let configFileURL: URL

    private var store: [String: Any] = [:]
    private var lastLoadedMtime: Date?

    private enum Keys {
        static let enabledActions = "enabledActions"
        static let menuIconStyle = "menuIconStyle"
        static let preferredTerminal = "preferredTerminal"
        static let preferredEditor = "preferredEditor"
        static let customFileTemplates = "customFileTemplates"
        static let appLanguage = "appLanguage"
        static let shortcuts = "shortcuts"
        static let badgeOwnershipReclaim = "badgeOwnershipReclaim"
        static let copyPathFormat = "copyPathFormat"
    }

    public init(fileURL: URL = SharedConfig.sharedFileURL) {
        self.configFileURL = fileURL
        load()
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

    private func save() {
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

    // MARK: - Enabled Actions

    /// 每个 action 的开关状态，key 为 action id
    public var enabledActions: [String: Bool] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.enabledActions] as? [String: Bool] ?? [:]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.enabledActions] = newValue
            save()
        }
    }

    /// 检查指定 action 是否启用（默认为启用）
    public func isActionEnabled(_ actionId: String) -> Bool {
        return enabledActions[actionId] ?? true
    }

    /// 设置指定 action 的启用状态
    public func setActionEnabled(_ actionId: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var current = enabledActions
        current[actionId] = enabled
        enabledActions = current
    }

    // MARK: - Menu Icon Style

    /// 右键菜单图标风格（默认简洁：SF Symbols）
    public var menuIconStyle: MenuIconStyle {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let raw = store[Keys.menuIconStyle] as? String,
               let style = MenuIconStyle(rawValue: raw) {
                return style
            }
            return .modern
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.menuIconStyle] = newValue.rawValue
            save()
        }
    }

    // MARK: - Preferred Terminal

    /// 首选终端应用 bundle identifier
    public var preferredTerminal: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let saved = store[Keys.preferredTerminal] as? String, !saved.isEmpty {
                return saved
            }
            return TerminalCatalog.defaultTerminalBundleIdentifier()
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.preferredTerminal] = newValue
            save()
        }
    }

    // MARK: - Preferred Editor

    /// 首选编辑器应用 bundle identifier
    public var preferredEditor: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.preferredEditor] as? String ?? "com.microsoft.VSCode"
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.preferredEditor] = newValue
            save()
        }
    }

    // MARK: - Custom File Templates

    /// 自定义文件模板列表
    public var customFileTemplates: [FileTemplate] {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = store[Keys.customFileTemplates] as? Data else { return [] }
            return (try? JSONDecoder().decode([FileTemplate].self, from: data)) ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) {
                store[Keys.customFileTemplates] = data
                save()
            }
        }
    }

    /// 添加自定义文件模板
    public func addFileTemplate(_ template: FileTemplate) {
        lock.lock()
        defer { lock.unlock() }
        var templates = customFileTemplates
        templates.append(template)
        customFileTemplates = templates
    }

    /// 删除自定义文件模板
    public func removeFileTemplate(withId id: String) {
        lock.lock()
        defer { lock.unlock() }
        var templates = customFileTemplates
        templates.removeAll { $0.id == id }
        customFileTemplates = templates
    }


    // MARK: - App Language

    /// 界面语言："system"（默认，跟随系统）/ "zh-Hans" / "en"。
    ///
    /// 扩展端在 menu(for:) 里 reload 后读取，运行时即时切换菜单语言；
    /// 主 App 端由设置界面同步写入 AppleLanguages，重启后生效。
    public var appLanguage: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.appLanguage] as? String ?? "system"
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.appLanguage] = newValue
            save()
        }
    }

    // MARK: - Badge Ownership

    /// 自动解决角标冲突（默认开启）：检测到剪切角标的显示权被其他 Finder Sync 扩展占用时，
    /// 由主 App 短暂重启这些扩展以取回。扩展端用来跳过无谓 IPC，主 App 端作为最终裁决。
    public var badgeOwnershipReclaim: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.badgeOwnershipReclaim] as? Bool ?? true
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.badgeOwnershipReclaim] = newValue
            save()
        }
    }

    // MARK: - Copy Path Format

    /// 「复制路径」的格式（默认绝对路径）
    public var copyPathFormat: CopyPathFormat {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let raw = store[Keys.copyPathFormat] as? String, let format = CopyPathFormat(rawValue: raw) {
                return format
            }
            return .absolute
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.copyPathFormat] = newValue.rawValue
            save()
        }
    }

    // MARK: - Shortcuts

    /// 菜单项快捷键，key 为 action ID（如 "shortcut.cut"）
    public var shortcuts: [String: ActionShortcut] {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = store[Keys.shortcuts] as? Data else { return [:] }
            return (try? JSONDecoder().decode([String: ActionShortcut].self, from: data)) ?? [:]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) {
                store[Keys.shortcuts] = data
                save()
            }
        }
    }

    /// 获取指定 action 的快捷键
    public func shortcut(forActionId id: String) -> ActionShortcut? {
        lock.lock()
        defer { lock.unlock() }
        return shortcuts[id]
    }

    /// 设置或清除指定 action 的快捷键
    public func setShortcut(_ shortcut: ActionShortcut?, forActionId id: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = shortcuts
        if let s = shortcut { current[id] = s } else { current.removeValue(forKey: id) }
        shortcuts = current
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
