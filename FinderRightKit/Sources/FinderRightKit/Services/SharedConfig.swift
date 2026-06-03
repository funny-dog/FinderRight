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

    private var store: [String: Any] = [:]

    private enum Keys {
        static let enabledActions = "enabledActions"
        static let preferredTerminal = "preferredTerminal"
        static let preferredEditor = "preferredEditor"
        static let customFileTemplates = "customFileTemplates"
        static let showHiddenFiles = "showHiddenFiles"
        static let shortcuts = "shortcuts"
    }

    private init() {
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: SharedConfig.sharedFileURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            store = [:]
            return
        }
        store = dict
    }

    private func save() {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: store, format: .xml, options: 0) else { return }
        try? data.write(to: SharedConfig.sharedFileURL, options: .atomic)
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
            return store[Keys.enabledActions] as? [String: Bool] ?? [:]
        }
        set {
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
        var current = enabledActions
        current[actionId] = enabled
        enabledActions = current
    }

    // MARK: - Preferred Terminal

    /// 首选终端应用 bundle identifier
    public var preferredTerminal: String {
        get {
            return store[Keys.preferredTerminal] as? String ?? "com.apple.Terminal"
        }
        set {
            store[Keys.preferredTerminal] = newValue
            save()
        }
    }

    // MARK: - Preferred Editor

    /// 首选编辑器应用 bundle identifier
    public var preferredEditor: String {
        get {
            return store[Keys.preferredEditor] as? String ?? "com.microsoft.VSCode"
        }
        set {
            store[Keys.preferredEditor] = newValue
            save()
        }
    }

    // MARK: - Custom File Templates

    /// 自定义文件模板列表
    public var customFileTemplates: [FileTemplate] {
        get {
            guard let data = store[Keys.customFileTemplates] as? Data else { return [] }
            return (try? JSONDecoder().decode([FileTemplate].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                store[Keys.customFileTemplates] = data
                save()
            }
        }
    }

    /// 添加自定义文件模板
    public func addFileTemplate(_ template: FileTemplate) {
        var templates = customFileTemplates
        templates.append(template)
        customFileTemplates = templates
    }

    /// 删除自定义文件模板
    public func removeFileTemplate(withId id: String) {
        var templates = customFileTemplates
        templates.removeAll { $0.id == id }
        customFileTemplates = templates
    }

    // MARK: - Show Hidden Files

    /// 是否显示隐藏文件
    public var showHiddenFiles: Bool {
        get {
            return store[Keys.showHiddenFiles] as? Bool ?? false
        }
        set {
            store[Keys.showHiddenFiles] = newValue
            save()
        }
    }

    // MARK: - Shortcuts

    /// 菜单项快捷键，key 为 action ID（如 "shortcut.cut"）
    public var shortcuts: [String: ActionShortcut] {
        get {
            guard let data = store[Keys.shortcuts] as? Data else { return [:] }
            return (try? JSONDecoder().decode([String: ActionShortcut].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                store[Keys.shortcuts] = data
                save()
            }
        }
    }

    /// 获取指定 action 的快捷键
    public func shortcut(forActionId id: String) -> ActionShortcut? {
        shortcuts[id]
    }

    /// 设置或清除指定 action 的快捷键
    public func setShortcut(_ shortcut: ActionShortcut?, forActionId id: String) {
        var current = shortcuts
        if let s = shortcut { current[id] = s } else { current.removeValue(forKey: id) }
        shortcuts = current
    }

    // MARK: - Reset

    /// 重置所有配置为默认值
    public func resetToDefaults() {
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
