import Foundation
import AppKit

/// 彩色图标的配色。按功能分组着色（剪切/粘贴同为橙色、移动到/复制到同为绿色……），长菜单里便于扫视定位
public struct MenuTint: Equatable, Hashable {
    /// 缓存键
    public let name: String
    /// 彩色方块的底色（浅色 / 深色菜单）
    public let tile: (light: UInt32, dark: UInt32)
    /// 彩色线条的颜色：浅色菜单下略加深，保证细线条在浅底上的对比度
    public let line: (light: UInt32, dark: UInt32)
    /// 底色过浅时，方块里的符号改用深色
    public var darkGlyph: Bool

    public init(name: String, tile: (light: UInt32, dark: UInt32), line: (light: UInt32, dark: UInt32), darkGlyph: Bool = false) {
        self.name = name
        self.tile = tile
        self.line = line
        self.darkGlyph = darkGlyph
    }

    public static func == (lhs: MenuTint, rhs: MenuTint) -> Bool {
        lhs.name == rhs.name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    public func tileNSColor(isDark: Bool) -> NSColor {
        NSColor(hex: isDark ? tile.dark : tile.light)
    }

    public func lineNSColor(isDark: Bool) -> NSColor {
        NSColor(hex: isDark ? line.dark : line.light)
    }

    public func dynamicTileColor() -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return self.tileNSColor(isDark: isDark)
        }
    }

    public func dynamicLineColor() -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return self.lineNSColor(isDark: isDark)
        }
    }

    public static let blue     = MenuTint(name: "blue",     tile: (0x007AFF, 0x0A84FF), line: (0x007AFF, 0x0A84FF))
    public static let indigo   = MenuTint(name: "indigo",   tile: (0x5856D6, 0x5E5CE6), line: (0x5856D6, 0x7D7AFF))
    public static let teal     = MenuTint(name: "teal",     tile: (0x30B0C7, 0x40C8E0), line: (0x1A9CB3, 0x40C8E0))
    public static let cyan     = MenuTint(name: "cyan",     tile: (0x32ADE6, 0x48B8EC), line: (0x1E9BD7, 0x64D2FF))
    public static let graphite = MenuTint(name: "graphite", tile: (0x48484A, 0x6C6C70), line: (0x48484A, 0xAEAEB2))
    public static let purple   = MenuTint(name: "purple",   tile: (0xAF52DE, 0xBF5AF2), line: (0xA447D6, 0xBF5AF2))
    public static let orange   = MenuTint(name: "orange",   tile: (0xFF9500, 0xFF9F0A), line: (0xF08A00, 0xFF9F0A))
    public static let green    = MenuTint(name: "green",    tile: (0x34C759, 0x30D158), line: (0x28A745, 0x30D158))
    public static let brown    = MenuTint(name: "brown",    tile: (0xA2845E, 0xAC8E68), line: (0x8F714B, 0xAC8E68))
    public static let pink     = MenuTint(name: "pink",     tile: (0xFF2D55, 0xFF375F), line: (0xF0244B, 0xFF375F))
    public static let red      = MenuTint(name: "red",      tile: (0xFF3B30, 0xFF453A), line: (0xE5332A, 0xFF453A))
    public static let gray     = MenuTint(name: "gray",     tile: (0x8E8E93, 0x7C7C80), line: (0x7C7C80, 0x98989D))
    public static let yellow   = MenuTint(name: "yellow",   tile: (0xFFCC00, 0xFFD60A), line: (0xD4A000, 0xFFD60A), darkGlyph: true)
}

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
    /// 彩色模式下的主题色分组
    public let tint: MenuTint

    public init(id: String, nameKey: String, descriptionKey: String, systemImage: String, tint: MenuTint = .blue) {
        self.id = id
        self.nameKey = nameKey
        self.descriptionKey = descriptionKey
        self.systemImage = systemImage
        self.tint = tint
    }
}

/// 右键菜单图标风格
public enum MenuIconStyle: String, Codable, CaseIterable, Identifiable {
    case modern = "modern"     // 单色线条：SF Symbols 模板图，随菜单明暗自动反色
    case tinted = "tinted"     // 彩色线条：按功能分组着色的 SF Symbols
    case tile = "tile"         // 彩色方块：圆角色块 + 白色 SF Symbols
    case none = "none"         // 纯文本 (无图标)

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .modern: return "单色线条"
        case .tinted: return "彩色线条"
        case .tile: return "彩色方块"
        case .none: return "无图标"
        }
    }

    /// 解析存储值。旧版的「彩色 (Emoji)」(classic) 已移除，迁移为同属彩色的彩色方块
    public init?(storedValue: String) {
        if storedValue == "classic" {
            self = .tile
        } else {
            self.init(rawValue: storedValue)
        }
    }
}

/// 内置功能清单。`all` 的顺序即右键菜单的顺序。
public enum MenuFeatureCatalog {
    public static let undo         = "feature.undo"
    public static let newFile      = "feature.newFile"
    public static let copyPath     = "feature.copyPath"
    public static let copyFileName = "feature.copyFileName"
    public static let copyFileContent = "feature.copyFileContent"
    public static let goToDirectory = "feature.goToDirectory"
    public static let openTerminal = "feature.openTerminal"
    public static let openEditor   = "feature.openEditor"
    public static let cut          = "feature.cut"
    public static let paste        = "feature.paste"
    public static let moveTo       = "feature.moveTo"
    public static let copyTo       = "feature.copyTo"
    public static let compress     = "feature.compress"
    public static let decompress   = "feature.decompress"
    public static let toggleHidden = "feature.toggleHidden"

    public static let all: [MenuFeature] = [
        // 只在有可撤销的操作时出现，放最前面便于发现
        MenuFeature(id: undo,         nameKey: "撤销",           descriptionKey: "撤销 FinderRight 的上一次文件操作，只在可撤销时出现", systemImage: "arrow.uturn.backward", tint: .gray),
        MenuFeature(id: newFile,      nameKey: "新建文件",       descriptionKey: "在当前目录新建文件",       systemImage: "doc.badge.plus", tint: .blue),
        MenuFeature(id: copyPath,     nameKey: "复制路径",       descriptionKey: "复制文件或文件夹的完整路径", systemImage: "link", tint: .indigo),
        MenuFeature(id: copyFileName, nameKey: "复制文件名",     descriptionKey: "复制完整文件名（含扩展名），多选时每行一项", systemImage: "character.cursor.ibeam", tint: .indigo),
        MenuFeature(id: copyFileContent, nameKey: "复制文件内容", descriptionKey: "复制单选文本文件的全部内容到剪贴板", systemImage: "doc.plaintext", tint: .teal),
        MenuFeature(id: goToDirectory, nameKey: "打开路径…",     descriptionKey: "输入文件或文件夹路径，在访达中显示或直接打开", systemImage: "arrow.right.circle", tint: .cyan),
        MenuFeature(id: openTerminal, nameKey: "打开终端",       descriptionKey: "使用默认终端打开当前目录",   systemImage: "terminal", tint: .graphite),
        MenuFeature(id: openEditor,   nameKey: "打开编辑器",     descriptionKey: "使用默认编辑器打开文件",     systemImage: "curlybraces", tint: .purple),
        MenuFeature(id: cut,          nameKey: "剪切",           descriptionKey: "剪切选中的文件",           systemImage: "scissors", tint: .orange),
        MenuFeature(id: paste,        nameKey: "粘贴",           descriptionKey: "粘贴已剪切的文件",         systemImage: "doc.on.clipboard", tint: .orange),
        MenuFeature(id: moveTo,       nameKey: "移动到",         descriptionKey: "把选中项移动到常用目录",     systemImage: "arrowshape.turn.up.right", tint: .green),
        MenuFeature(id: copyTo,       nameKey: "复制到",         descriptionKey: "把选中项复制到常用目录",     systemImage: "plus.square.on.square", tint: .green),
        MenuFeature(id: compress,     nameKey: "压缩为 ZIP",     descriptionKey: "压缩选中的文件或文件夹",     systemImage: "doc.zipper", tint: .brown),
        MenuFeature(id: decompress,   nameKey: "解压到当前目录", descriptionKey: "解压选中的压缩包",         systemImage: "shippingbox.and.arrow.backward", tint: .brown),
        MenuFeature(id: toggleHidden, nameKey: "切换隐藏文件",   descriptionKey: "显示或隐藏隐藏文件",       systemImage: "eye", tint: .pink),
    ]

    /// 默认关闭的功能：用户从未设置过开关时视为关闭，显式开启后照常显示。
    /// 压缩 / 解压与系统能力重叠（访达自带「压缩」，双击压缩包即由归档实用工具解压），默认不占菜单位置
    public static let disabledByDefault: Set<String> = [compress, decompress]

    public static func feature(forId id: String) -> MenuFeature? {
        all.first { $0.id == id }
    }

    /// 按用户保存的顺序排列全部功能（保存的顺序先经 normalizedOrder 归一化）
    public static func ordered(by savedOrder: [String]) -> [MenuFeature] {
        normalizedOrder(savedOrder, defaults: all.map(\.id)).compactMap { feature(forId: $0) }
    }

    /// 把用户保存的顺序归一化为 defaults 的一个排列：
    /// - 丢弃未知 id 与重复 id（功能被移除、配置被手改）；
    /// - 缺失的 id（新版本新增的功能）插到它在默认顺序里「最近的前一项」之后，
    ///   没有前一项时放到最前，使新功能出现在合理位置而不是一律堆到末尾。
    public static func normalizedOrder(_ saved: [String], defaults: [String]) -> [String] {
        let known = Set(defaults)
        var seen = Set<String>()
        var result = saved.filter { known.contains($0) && seen.insert($0).inserted }
        for (index, id) in defaults.enumerated() where !seen.contains(id) {
            let predecessor = defaults[..<index].last { result.contains($0) }
            if let predecessor, let position = result.firstIndex(of: predecessor) {
                result.insert(id, at: position + 1)
            } else {
                result.insert(id, at: 0)
            }
            seen.insert(id)
        }
        return result
    }
}
