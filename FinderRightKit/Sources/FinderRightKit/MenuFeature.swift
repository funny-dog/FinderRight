import Foundation

/// Finder 右键菜单中的一个功能项 —— 全应用的「单一事实来源」。
///
/// 主 App 设置界面据此渲染功能开关；FinderSync 扩展据此决定每个菜单项是否显示。
/// 两端共用同一份清单与同一套 id，避免「设置里的开关与右键菜单对不上」。
public struct MenuFeature: Identifiable, Equatable {
    /// 功能唯一标识（同时作为 SharedConfig 开关存储的 key）
    public let id: String
    /// 名称的本地化 key（中文做 key，en.lproj 提供英文）
    public let nameKey: String
    /// 描述的本地化 key
    public let descriptionKey: String
    /// SF Symbol 名
    public let systemImage: String
    /// 经典 Emoji 图标
    public let emoji: String

    public init(id: String, nameKey: String, descriptionKey: String, systemImage: String, emoji: String = "") {
        self.id = id
        self.nameKey = nameKey
        self.descriptionKey = descriptionKey
        self.systemImage = systemImage
        self.emoji = emoji
    }
}

/// 右键菜单图标风格
public enum MenuIconStyle: String, Codable, CaseIterable, Identifiable {
    case modern = "modern"     // 简洁 (SF Symbols 原生图标)
    case classic = "classic"   // 经典 (Emoji 彩色图标)
    case none = "none"         // 纯文本 (无图标)

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .modern: return "简洁 (SF Symbols)"
        case .classic: return "彩色 (Emoji)"
        case .none: return "无图标"
        }
    }
}

/// 内置功能清单。`all` 的顺序即右键菜单的顺序。
public enum MenuFeatureCatalog {
    public static let newFile      = "feature.newFile"
    public static let copyPath     = "feature.copyPath"
    public static let openTerminal = "feature.openTerminal"
    public static let openEditor   = "feature.openEditor"
    public static let cut          = "feature.cut"
    public static let paste        = "feature.paste"
    public static let compress     = "feature.compress"
    public static let decompress   = "feature.decompress"
    public static let toggleHidden = "feature.toggleHidden"

    public static let all: [MenuFeature] = [
        MenuFeature(id: newFile,      nameKey: "新建文件",       descriptionKey: "在当前目录新建文件",       systemImage: "doc.badge.plus", emoji: "📄"),
        MenuFeature(id: copyPath,     nameKey: "复制路径",       descriptionKey: "复制文件或文件夹的完整路径", systemImage: "doc.on.doc",     emoji: "📋"),
        MenuFeature(id: openTerminal, nameKey: "打开终端",       descriptionKey: "使用默认终端打开当前目录",   systemImage: "terminal",       emoji: "💻"),
        MenuFeature(id: openEditor,   nameKey: "打开编辑器",     descriptionKey: "使用默认编辑器打开文件",     systemImage: "curlybraces",     emoji: "✏️"),
        MenuFeature(id: cut,          nameKey: "剪切",           descriptionKey: "剪切选中的文件",           systemImage: "scissors",        emoji: "✂️"),
        MenuFeature(id: paste,        nameKey: "粘贴",           descriptionKey: "粘贴已剪切的文件",         systemImage: "doc.on.clipboard", emoji: "📋"),
        MenuFeature(id: compress,     nameKey: "压缩为 ZIP",     descriptionKey: "压缩选中的文件或文件夹",     systemImage: "archivebox",     emoji: "📦"),
        MenuFeature(id: decompress,   nameKey: "解压到当前目录", descriptionKey: "解压选中的压缩包",         systemImage: "archivebox",     emoji: "📂"),
        MenuFeature(id: toggleHidden, nameKey: "切换隐藏文件",   descriptionKey: "显示或隐藏隐藏文件",       systemImage: "eye",            emoji: "👁"),
    ]

    public static func feature(forId id: String) -> MenuFeature? {
        all.first { $0.id == id }
    }
}
