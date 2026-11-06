import Foundation
import AppKit

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
    
    public private(set) var windowPositions: [WindowPositionInfo] {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = try? Data(contentsOf: configFileURL),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let windows = dict[WindowKeys.windowPositions] as? [[String: Any]] else {
                return []
            }
            
            return windows.compactMap { dict -> WindowPositionInfo? in
                guard let id = dict["id"] as? String,
                      let screenIdentifier = dict["screenIdentifier"] as? String,
                      let originX = dict["originX"] as? Double,
                      let originY = dict["originY"] as? Double,
                      let width = dict["width"] as? Double,
                      let height = dict["height"] as? Double else {
                    return nil
                }
                
                return WindowPositionInfo(
                    id: id,
                    screenIdentifier: screenIdentifier.isEmpty ? nil : screenIdentifier,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            }
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[WindowKeys.windowPositions] = newValue.map { info -> [String: Any] in
                [
                    "id": info.id,
                    "screenIdentifier": info.screenIdentifier ?? "",
                    "originX": info.originX,
                    "originY": info.originY,
                    "width": info.sizeWidth,
                    "height": info.sizeHeight
                ]
            }
            save()
        }
    }
    
    /// 保存窗口位置（简化版）
    public func saveWindowPosition(for windowType: String, frame: NSRect) {
        var currentPositions = windowPositions
        if let index = currentPositions.firstIndex(where: { $0.id == windowType }) {
            currentPositions[index] = WindowPositionInfo(
                id: windowType,
                screenIdentifier: nil,
                originX: frame.origin.x,
                originY: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            )
        } else {
            currentPositions.append(WindowPositionInfo(
                id: windowType,
                screenIdentifier: nil,
                originX: frame.origin.x,
                originY: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            ))
        }
        
        windowPositions = currentPositions
    }
    
    /// 恢复窗口位置
    public func restoreWindowPosition(for windowType: String) -> NSRect? {
        lock.lock()
        defer { lock.unlock() }
        
        guard let info = windowPositions.first(where: { $0.id == windowType }) else {
            return nil
        }
        
        return NSRect(
            origin: NSPoint(x: info.originX, y: info.originY),
            size: CGSize(width: info.sizeWidth, height: info.sizeHeight)
        )
    }
    
    /// 清除特定窗口的记忆位置
    public func clearWindowPosition(for windowType: String) {
        var currentPositions = windowPositions
        currentPositions.removeAll { $0.id == windowType }
        windowPositions = currentPositions
    }
    
    /// 清除所有窗口位置记忆
    public func clearAllWindowPositions() {
        windowPositions = []
    }
}

// MARK: - Command Templates

public enum CommandCategory: String, Codable, CaseIterable, Identifiable {
    case build = "Build"
    case test = "Test"
    case deploy = "Deploy"
    case format = "Format"
    case search = "Search"
    case custom = "Custom"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .build: return "构建与编译"
        case .test: return "测试与验证"
        case .deploy: return "部署与发布"
        case .format: return "格式化与 lint"
        case .search: return "搜索与查找"
        case .custom: return "自定义"
        }
    }
}

/// 保存的命令（基于预定义模板创建）
public struct SavedCommandTemplate: Codable, Identifiable {
    public var id: String
    public let originalTemplateId: String
    public var name: String
    public var script: String
    public var category: CommandCategory
    public var lastUsed: Date?
    
    public init(id: String = UUID().uuidString, originalTemplateId: String, name: String, script: String, category: CommandCategory) {
        self.id = id
        self.originalTemplateId = originalTemplateId
        self.name = name
        self.script = script
        self.category = category
        self.lastUsed = nil
    }
}

extension SharedConfig {
    
    private enum TemplateKeys {
        static let savedCommandTemplates = "savedCommandTemplates"
    }
    
    public private(set) var commandTemplates: [SavedCommandTemplate] {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = try? Data(contentsOf: configFileURL),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let templates = dict[TemplateKeys.savedCommandTemplates] as? [[String: Any]] else {
                return []
            }
            
            return templates.compactMap { dict -> SavedCommandTemplate? in
                guard let id = dict["id"] as? String,
                      let originalTemplateId = dict["originalTemplateId"] as? String,
                      let name = dict["name"] as? String,
                      let script = dict["script"] as? String,
                      let categoryRaw = dict["category"] as? String else { return nil }
                
                return SavedCommandTemplate(
                    id: id,
                    originalTemplateId: originalTemplateId,
                    name: name,
                    script: script,
                    category: CommandCategory(rawValue: categoryRaw) ?? .custom
                )
            }
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[TemplateKeys.savedCommandTemplates] = newValue.map { template -> [String: Any] in
                [
                    "id": template.id,
                    "originalTemplateId": template.originalTemplateId,
                    "name": template.name,
                    "script": template.script,
                    "category": template.category.rawValue,
                    "lastUsed": template.lastUsed?.iso8601String
                ]
            }
            save()
        }
    }
}

extension Date {
    fileprivate var iso8601String: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: self)
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
