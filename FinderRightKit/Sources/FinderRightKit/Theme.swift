import AppKit

// MARK: - 主题色

/// 用户可选的主题色，存于 UserDefaults 的 `appTheme` 与 SharedConfig，默认午夜薄荷
public enum FRThemeID: String, CaseIterable, Identifiable {
    case midnight
    case sky
    case lavender
    case sunset
    case sakura
    case graphite

    public static let storageKey = "appTheme"

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .midnight: return "午夜薄荷"
        case .sky: return "晴空蓝"
        case .lavender: return "薰衣草紫"
        case .sunset: return "落日橙"
        case .sakura: return "樱花粉"
        case .graphite: return "石墨"
        }
    }

    /// 当前生效的主题。动态颜色在每次绘制时读取它，切换后让视图重绘即可生效
    public static var current: FRThemeID {
        get {
            // 优先读取 SharedConfig（跨进程共享，沙箱化的 FinderSync 扩展也能读取最新配置）
            if let saved = SharedConfig.shared.appThemeValue {
                return saved
            }
            if let raw = UserDefaults.standard.string(forKey: storageKey),
               let theme = FRThemeID(rawValue: raw) {
                return theme
            }
            return .midnight
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
            SharedConfig.shared.appTheme = newValue
        }
    }

    public var palette: FRPalette {
        switch self {
        case .midnight: return .midnight
        case .sky: return .sky
        case .lavender: return .lavender
        case .sunset: return .sunset
        case .sakura: return .sakura
        case .graphite: return .graphite
        }
    }
}

/// 界面明暗：跟随系统或固定浅色 / 深色，存于 UserDefaults 的 `appAppearance`
public enum FRAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    public static let storageKey = "appAppearance"

    public var id: String { rawValue }

    public var titleKey: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    public static var stored: FRAppearanceMode {
        FRAppearanceMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// 设置整个 App 的外观。动态颜色按窗口的实际外观取值，AppKit 会自动重绘，无需重建视图
    public func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 一组浅色 / 深色外观下的颜色
public struct FRColorPair: Equatable {
    public let light: NSColor
    public let dark: NSColor

    public init(_ light: NSColor, _ dark: NSColor) {
        self.light = light
        self.dark = dark
    }

    public init(_ light: UInt32, _ dark: UInt32) {
        self.init(NSColor(hex: light), NSColor(hex: dark))
    }

    public func resolved(for appearance: NSAppearance?) -> NSColor {
        guard let appearance = appearance else { return light }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// 一套主题的全部界面色。描边、悬停、输入框等中性色由主文字色统一推导，各主题只需给出差异部分
public struct FRPalette: Equatable {
    public let window, sidebar, card, border, text, mute: FRColorPair
    public let accent, accentText, onAccent, selection, hover, field, fieldBorder: FRColorPair

    public init(
        window: FRColorPair, sidebar: FRColorPair, card: FRColorPair, text: FRColorPair, mute: FRColorPair,
        accent: FRColorPair, accentText: FRColorPair, onAccent: FRColorPair,
        selectionAlpha: (light: CGFloat, dark: CGFloat)
    ) {
        self.window = window
        self.sidebar = sidebar
        self.card = card
        self.text = text
        self.mute = mute
        self.accent = accent
        self.accentText = accentText
        self.onAccent = onAccent
        selection = FRColorPair(accent.light.withAlphaComponent(selectionAlpha.light),
                                accent.dark.withAlphaComponent(selectionAlpha.dark))
        let ink = text.light
        let white = NSColor(hex: 0xFFFFFF)
        border = FRColorPair(ink.withAlphaComponent(0.09), white.withAlphaComponent(0.08))
        hover = FRColorPair(ink.withAlphaComponent(0.05), white.withAlphaComponent(0.06))
        field = FRColorPair(white, white.withAlphaComponent(0.06))
        fieldBorder = FRColorPair(ink.withAlphaComponent(0.16), white.withAlphaComponent(0.14))
    }

    /// 午夜蓝 + 薄荷（默认）
    public static let midnight = FRPalette(
        window: .init(0xF5F7FB, 0x0F1626), sidebar: .init(0xE8EDF5, 0x0B1220), card: .init(0xFFFFFF, 0x17223A),
        text: .init(0x0B1220, 0xEAF0FA), mute: .init(0x596680, 0x97A4BD),
        accent: .init(0x2BD4A0, 0x4FE3B1), accentText: .init(0x0B7A5A, 0x4FE3B1), onAccent: .init(0x04251B, 0x062B20),
        selectionAlpha: (0.20, 0.16)
    )

    /// 石板灰 + 蓝，接近系统原生观感
    public static let sky = FRPalette(
        window: .init(0xF5F7FA, 0x0F141C), sidebar: .init(0xEAEEF3, 0x0A0E14), card: .init(0xFFFFFF, 0x18202C),
        text: .init(0x0F172A, 0xE8EDF5), mute: .init(0x5B6779, 0x98A3B3),
        accent: .init(0x2F74E8, 0x60A5FA), accentText: .init(0x1D5FD6, 0x7AB4FF), onAccent: .init(0xFFFFFF, 0x0A1B33),
        selectionAlpha: (0.14, 0.16)
    )

    /// 冷灰偏紫 + 紫
    public static let lavender = FRPalette(
        window: .init(0xF7F6FB, 0x13111C), sidebar: .init(0xEEEBF6, 0x0E0C16), card: .init(0xFFFFFF, 0x1D1A2B),
        text: .init(0x1A1530, 0xEEEAF8), mute: .init(0x676080, 0xA39DB8),
        accent: .init(0x8B5CF6, 0xA78BFA), accentText: .init(0x6D3FD9, 0xB9A2FF), onAccent: .init(0xFFFFFF, 0x1B1035),
        selectionAlpha: (0.14, 0.16)
    )

    /// 暖灰 + 橙。橙色上白字对比度不足，两种外观都用深色字
    public static let sunset = FRPalette(
        window: .init(0xFAF7F4, 0x17130F), sidebar: .init(0xF2ECE5, 0x110E0B), card: .init(0xFFFFFF, 0x221C17),
        text: .init(0x231A12, 0xF3ECE4), mute: .init(0x7A6A5C, 0xB0A293),
        accent: .init(0xF97316, 0xFB923C), accentText: .init(0xC2550A, 0xFFA868), onAccent: .init(0x2B1405, 0x2B1405),
        selectionAlpha: (0.14, 0.16)
    )

    /// 暖灰偏粉 + 玫瑰粉
    public static let sakura = FRPalette(
        window: .init(0xFBF6F7, 0x171114), sidebar: .init(0xF4EAED, 0x110C0E), card: .init(0xFFFFFF, 0x22191D),
        text: .init(0x2A1419, 0xF5EAED), mute: .init(0x806670, 0xB8A0A8),
        accent: .init(0xE64A72, 0xFB7196), accentText: .init(0xC22D55, 0xFF8FAB), onAccent: .init(0xFFFFFF, 0x33081A),
        selectionAlpha: (0.13, 0.16)
    )

    /// 纯中性灰，无彩色强调
    public static let graphite = FRPalette(
        window: .init(0xF6F6F7, 0x141416), sidebar: .init(0xECECEE, 0x0E0E10), card: .init(0xFFFFFF, 0x1E1E21),
        text: .init(0x18181B, 0xEDEDF0), mute: .init(0x6B6B73, 0xA1A1AA),
        accent: .init(0x2A2A2E, 0xE8E8EC), accentText: .init(0x18181B, 0xF4F4F5), onAccent: .init(0xFFFFFF, 0x18181B),
        selectionAlpha: (0.08, 0.10)
    )
}

public extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
