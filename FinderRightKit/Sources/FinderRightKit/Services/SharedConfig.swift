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
        static let menuOrder = "menuOrder"
        static let favoriteDirectories = "favoriteDirectories"
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

    /// 检查指定 action 是否启用（未设置时默认启用，MenuFeatureCatalog.disabledByDefault 中的除外）
    public func isActionEnabled(_ actionId: String) -> Bool {
        return enabledActions[actionId] ?? !MenuFeatureCatalog.disabledByDefault.contains(actionId)
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

    /// 右键菜单图标风格（默认彩色线条）
    public var menuIconStyle: MenuIconStyle {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let raw = store[Keys.menuIconStyle] as? String,
               let style = MenuIconStyle(storedValue: raw) {
                return style
            }
            return .tinted
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.menuIconStyle] = newValue.rawValue
            save()
        }
    }

    /// 图标风格默认值从「单色线条」改成「彩色线条」：
    /// - **老用户**（升级前就存在配置文件）从没选过样式的，显式落盘旧的默认值「单色线条」，看到的菜单保持不变；
    /// - **新用户**（没有配置文件）不落盘，直接拿到新的默认值。
    ///
    /// 必须用独立的标记位而不是「文件是否存在」判断：新用户首次运行后配置文件可能因改别的设置而生成，
    /// 那时若再按「文件已存在」判断就会把他们的默认样式误钉成单色线条。
    private func migrateIconStyleDefaultIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard store[Keys.iconStyleDefaultMigrated] as? Bool != true else { return }

        if FileManager.default.fileExists(atPath: configFileURL.path),
           store[Keys.menuIconStyle] == nil {
            store[Keys.menuIconStyle] = MenuIconStyle.modern.rawValue
        }
        store[Keys.iconStyleDefaultMigrated] = true
        save()
    }

    // MARK: - Preferred Terminal

    public var followsSystemTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (store[Keys.preferredTerminal] as? String ?? "").isEmpty
    }

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

    /// 右键菜单启用的终端；未配置时只启用已有的默认终端。
    public var selectedTerminals: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let saved = store[Keys.selectedTerminals] as? [String] else {
                return [preferredTerminal]
            }
            return Set(saved)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.selectedTerminals] = newValue.sorted()
            save()
        }
    }

    /// 默认菜单项随首选终端变化，不将当前系统默认固定保存为某个 bundle id。
    public func resetTerminalMenuToDefault() {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: Keys.selectedTerminals)
        save()
    }

    /// 终端 bundle identifier 的显示顺序；未配置的终端由清单顺序补到末尾。
    public var terminalOrder: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.terminalOrder] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.terminalOrder] = newValue
            save()
        }
    }

    // MARK: - Editors

    /// 编辑器 bundle identifier 的显示顺序。
    public var editorOrder: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.editorOrder] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.editorOrder] = newValue
            save()
        }
    }

    /// 用户选定的默认编辑器 bundle identifier（服务菜单 / 快捷键使用）。
    /// nil 表示未选择，由 EditorCatalog.resolvedDefault 自动取右键菜单中的第一个
    public var preferredEditor: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let saved = store[Keys.preferredEditor] as? String, !saved.isEmpty else { return nil }
            return saved
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue, !newValue.isEmpty {
                store[Keys.preferredEditor] = newValue
            } else {
                store.removeValue(forKey: Keys.preferredEditor)
            }
            save()
        }
    }

    /// 用户手动添加的编辑器（预置清单之外的应用），按添加顺序
    public var customEditors: [KnownEditor] {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = store[Keys.customEditors] as? Data else { return [] }
            return (try? JSONDecoder().decode([KnownEditor].self, from: data)) ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) {
                store[Keys.customEditors] = data
                save()
            }
        }
    }

    /// 在右键「打开编辑器」子菜单中隐藏的编辑器 bundle identifier
    public var hiddenEditors: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Set(store[Keys.hiddenEditors] as? [String] ?? [])
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.hiddenEditors] = newValue.sorted()
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

    /// 更新已存在的自定义文件模板
    public func updateFileTemplate(_ template: FileTemplate) {
        lock.lock()
        defer { lock.unlock() }
        var templates = customFileTemplates
        if let idx = templates.firstIndex(where: { $0.id == template.id }) {
            templates[idx] = template
            customFileTemplates = templates
        }
    }

    /// 删除自定义文件模板
    public func removeFileTemplate(withId id: String) {
        lock.lock()
        defer { lock.unlock() }
        var templates = customFileTemplates
        templates.removeAll { $0.id == id }
        customFileTemplates = templates

        if newFileOrder.contains(id) {
            newFileOrder = newFileOrder.filter { $0 != id }
        }
        if hiddenNewFileTemplates.contains(id) {
            var hidden = hiddenNewFileTemplates
            hidden.remove(id)
            hiddenNewFileTemplates = hidden
        }
    }

    // MARK: - New File Order

    /// 新建文件子菜单项顺序（文件模板 id 列表）。未设置或为空时表示默认顺序
    public var newFileOrder: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.newFileOrder] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue.isEmpty {
                store.removeValue(forKey: Keys.newFileOrder)
            } else {
                store[Keys.newFileOrder] = newValue
            }
            save()
        }
    }

    // MARK: - Hidden New File Templates

    /// 在新建文件子菜单中隐藏的文件模板 id 集合
    public var hiddenNewFileTemplates: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Set(store[Keys.hiddenNewFileTemplates] as? [String] ?? [])
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue.isEmpty {
                store.removeValue(forKey: Keys.hiddenNewFileTemplates)
            } else {
                store[Keys.hiddenNewFileTemplates] = newValue.sorted()
            }
            save()
        }
    }

    /// 检查指定模板是否启用
    public func isNewFileTemplateEnabled(_ id: String) -> Bool {
        return !hiddenNewFileTemplates.contains(id)
    }

    /// 设置指定模板的启用状态
    public func setNewFileTemplateEnabled(_ id: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var hidden = hiddenNewFileTemplates
        if enabled {
            hidden.remove(id)
        } else {
            hidden.insert(id)
        }
        hiddenNewFileTemplates = hidden
    }

    // MARK: - Removed Built-in New File Templates

    /// 从设置的「文件模板」列表里移除的内置类型 id（自定义模板直接删除，不进这里）。
    /// 移除时同时记入 hiddenNewFileTemplates，访达菜单与服务只看隐藏集合，不必认识这个集合
    public var removedNewFileTemplates: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Set(store[Keys.removedNewFileTemplates] as? [String] ?? [])
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue.isEmpty {
                store.removeValue(forKey: Keys.removedNewFileTemplates)
            } else {
                store[Keys.removedNewFileTemplates] = newValue.sorted()
            }
            save()
        }
    }

    /// 移除内置类型：不再列出，也不出现在菜单中。不是内置类型的 id 忽略
    public func removeBuiltInNewFileTemplate(_ id: String) {
        guard NewFileTemplateCatalog.defaultOrder.contains(id) else { return }
        lock.lock()
        defer { lock.unlock() }
        removedNewFileTemplates.insert(id)
        setNewFileTemplateEnabled(id, enabled: false)
    }

    /// 恢复移除的内置类型，恢复后即为启用状态
    public func restoreBuiltInNewFileTemplate(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        removedNewFileTemplates.remove(id)
        setNewFileTemplateEnabled(id, enabled: true)
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

    // MARK: - Menu Order

    /// 右键菜单功能的顺序（功能 id 列表）。未设置时为空，表示默认顺序；
    /// 读取方用 MenuFeatureCatalog.ordered(by:) 归一化，容忍新增或移除的功能
    public var menuOrder: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.menuOrder] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue.isEmpty {
                store.removeValue(forKey: Keys.menuOrder)
            } else {
                store[Keys.menuOrder] = newValue
            }
            save()
        }
    }

    // MARK: - Favorite Directories

    /// 常用目录（绝对路径，按设置里的顺序），用于右键「移动到 / 复制到」
    public var favoriteDirectories: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.favoriteDirectories] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.favoriteDirectories] = newValue
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

    // MARK: - App Theme

    /// 存储的 appTheme，nil 表示尚未写入
    public var appThemeValue: FRThemeID? {
        lock.lock()
        defer { lock.unlock() }
        if let raw = store[Keys.appTheme] as? String {
            return FRThemeID(rawValue: raw)
        }
        return nil
    }

    /// 界面主题色，默认午夜薄荷
    public var appTheme: FRThemeID {
        get {
            appThemeValue ?? .midnight
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.appTheme] = newValue.rawValue
            save()
        }
    }

    // MARK: - Copy File Content Max Size

    /// 允许「复制文件内容」的最大文件大小（KB），默认 1024 KB (1 MB)
    public var copyFileContentMaxSizeKB: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let saved = store[Keys.copyFileContentMaxSizeKB] as? Int, saved > 0 {
                return saved
            }
            return 1024
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.copyFileContentMaxSizeKB] = max(1, newValue)
            save()
        }
    }

    /// 允许「复制文件内容」的最大字节数
    public var copyFileContentMaxBytes: Int64 {
        Int64(copyFileContentMaxSizeKB) * 1024
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
