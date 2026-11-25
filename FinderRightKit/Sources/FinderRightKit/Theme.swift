import AppKit

// MARK: - 主题色

/// 用户可选的主题色，存于 UserDefaults 的 `appTheme` 与 SharedConfig，默认午夜薄荷
public enum FRThemeID: String, CaseIterable, Identifiable {
    case terracotta
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
        case .terracotta: return "暖陶"
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
        case .terracotta: return .terracotta
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
    public let switchOffTrack, switchOffKnob: FRColorPair
    public let segmentedTrack, segmentedTrackBorder, segmentedThumb, segmentedThumbBorder: FRColorPair
    public let dropdownFill, dropdownHoverFill, cardShadow: FRColorPair

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
        let black = NSColor(hex: 0x000000)
        border = FRColorPair(ink.withAlphaComponent(0.09), white.withAlphaComponent(0.08))
        hover = FRColorPair(ink.withAlphaComponent(0.05), white.withAlphaComponent(0.06))
        field = FRColorPair(white, white.withAlphaComponent(0.06))
        fieldBorder = FRColorPair(ink.withAlphaComponent(0.16), white.withAlphaComponent(0.14))
        switchOffTrack = FRColorPair(ink.withAlphaComponent(0.18), white.withAlphaComponent(0.22))
        switchOffKnob = FRColorPair(white, text.dark.withAlphaComponent(0.88))
        segmentedTrack = FRColorPair(ink.withAlphaComponent(0.055), black.withAlphaComponent(0.24))
        segmentedTrackBorder = FRColorPair(ink.withAlphaComponent(0.10), white.withAlphaComponent(0.10))
        segmentedThumb = FRColorPair(card.light, white.withAlphaComponent(0.15))
        segmentedThumbBorder = FRColorPair(ink.withAlphaComponent(0.10), white.withAlphaComponent(0.16))
        dropdownFill = FRColorPair(card.light, white.withAlphaComponent(0.07))
        dropdownHoverFill = FRColorPair(ink.withAlphaComponent(0.04), white.withAlphaComponent(0.11))
        cardShadow = FRColorPair(ink.withAlphaComponent(0.04), black.withAlphaComponent(0.22))
    }

    /// 暖纸感 + 陶土红（Claude 风格）
    public static let terracotta = FRPalette(
        window: .init(0xFAF9F5, 0x1C1B19), sidebar: .init(0xF2F0E8, 0x151412), card: .init(0xFFFFFF, 0x262522),
        text: .init(0x141413, 0xF2EFE9), mute: .init(0x6B6860, 0xA39E93),
        accent: .init(0xB65533, 0xD97757), accentText: .init(0x9E4425, 0xE58B6D), onAccent: .init(0xFFFFFF, 0x1C1410),
        selectionAlpha: (0.12, 0.16)
    )

    /// 午夜蓝 + 薄荷（默认）
    public static let midnight = FRPalette(
        window: .init(0xF5F7F8, 0x15191E), sidebar: .init(0xEAEFF2, 0x101318), card: .init(0xFFFFFF, 0x1F252C),
        text: .init(0x0F1720, 0xECF1F5), mute: .init(0x5A6673, 0x99A5B2),
        accent: .init(0x118262, 0x3FD1A5), accentText: .init(0x0D6B50, 0x56DFB6), onAccent: .init(0xFFFFFF, 0x07241B),
        selectionAlpha: (0.12, 0.16)
    )

    /// 石板灰 + 蓝，接近系统原生观感
    public static let sky = FRPalette(
        window: .init(0xF6F7FA, 0x16181D), sidebar: .init(0xECEFF5, 0x111318), card: .init(0xFFFFFF, 0x20242B),
        text: .init(0x111722, 0xECEFF5), mute: .init(0x5B6575, 0x9AA3B2),
        accent: .init(0x2563D8, 0x60A5FA), accentText: .init(0x1D54BF, 0x7AB4FF), onAccent: .init(0xFFFFFF, 0x0A1B33),
        selectionAlpha: (0.12, 0.16)
    )

    /// 冷灰偏紫 + 紫
    public static let lavender = FRPalette(
        window: .init(0xF8F7FA, 0x18171D), sidebar: .init(0xEFEDF5, 0x121117), card: .init(0xFFFFFF, 0x23212A),
        text: .init(0x1A1726, 0xF0EEF6), mute: .init(0x655F75, 0xA39EB3),
        accent: .init(0x7648E2, 0xA78BFA), accentText: .init(0x6237C9, 0xBCA5FF), onAccent: .init(0xFFFFFF, 0x1B1035),
        selectionAlpha: (0.12, 0.16)
    )

    /// 暖灰 + 温润琥珀 / 焦糖金
    public static let sunset = FRPalette(
        window: .init(0xFAF8F3, 0x1B1A16), sidebar: .init(0xF2EFE6, 0x141310), card: .init(0xFFFFFF, 0x26241E),
        text: .init(0x1E1A12, 0xF3EFE6), mute: .init(0x6E6658, 0xA8A090),
        accent: .init(0xD4942A, 0xE6AE48), accentText: .init(0x8C5B08, 0xF0BE5E), onAccent: .init(0x241704, 0x221604),
        selectionAlpha: (0.14, 0.16)
    )

    /// 暖灰偏粉 + 玫瑰粉
    public static let sakura = FRPalette(
        window: .init(0xFAF7F8, 0x1C181A), sidebar: .init(0xF3ECEE, 0x151214), card: .init(0xFFFFFF, 0x262123),
        text: .init(0x24161A, 0xF4ECEE), mute: .init(0x746067, 0xAD9BA1),
        accent: .init(0xC73A5E, 0xEE7292), accentText: .init(0xA8294B, 0xF792AC), onAccent: .init(0xFFFFFF, 0x2B0B15),
        selectionAlpha: (0.12, 0.16)
    )

    /// 纯中性灰，无彩色强调
    public static let graphite = FRPalette(
        window: .init(0xF6F6F7, 0x161618), sidebar: .init(0xECECEE, 0x101012), card: .init(0xFFFFFF, 0x212124),
        text: .init(0x18181B, 0xEDEDF0), mute: .init(0x66666E, 0xA1A1AA),
        accent: .init(0x2A2A2E, 0xE4E4E8), accentText: .init(0x18181B, 0xF4F4F5), onAccent: .init(0xFFFFFF, 0x18181B),
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
