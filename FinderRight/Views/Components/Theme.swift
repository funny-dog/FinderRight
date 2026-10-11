import SwiftUI
import AppKit

// MARK: - 主题色

/// 用户可选的主题色，存于 UserDefaults 的 `appTheme`，默认午夜薄荷
enum FRThemeID: String, CaseIterable, Identifiable {
    case midnight
    case sky
    case lavender
    case sunset
    case sakura
    case graphite

    static let storageKey = "appTheme"

    var id: String { rawValue }

    var titleKey: String {
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
    static var current: FRThemeID = FRThemeID(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .midnight

    var palette: FRPalette {
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
enum FRAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let storageKey = "appAppearance"

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    static var stored: FRAppearanceMode {
        FRAppearanceMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// 设置整个 App 的外观。动态颜色按窗口的实际外观取值，AppKit 会自动重绘，无需重建视图
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// 一组浅色 / 深色外观下的颜色
struct FRColorPair {
    let light: NSColor
    let dark: NSColor

    init(_ light: NSColor, _ dark: NSColor) {
        self.light = light
        self.dark = dark
    }

    init(_ light: UInt32, _ dark: UInt32) {
        self.init(NSColor(hex: light), NSColor(hex: dark))
    }
}

/// 一套主题的全部界面色。描边、悬停、输入框等中性色由主文字色统一推导，各主题只需给出差异部分
struct FRPalette {
    let window, sidebar, card, border, text, mute: FRColorPair
    let accent, accentText, onAccent, selection, hover, field, fieldBorder: FRColorPair

    init(
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
    static let midnight = FRPalette(
        window: .init(0xF5F7FB, 0x0F1626), sidebar: .init(0xE8EDF5, 0x0B1220), card: .init(0xFFFFFF, 0x17223A),
        text: .init(0x0B1220, 0xEAF0FA), mute: .init(0x596680, 0x97A4BD),
        accent: .init(0x2BD4A0, 0x4FE3B1), accentText: .init(0x0B7A5A, 0x4FE3B1), onAccent: .init(0x04251B, 0x062B20),
        selectionAlpha: (0.20, 0.16)
    )

    /// 石板灰 + 蓝，接近系统原生观感
    static let sky = FRPalette(
        window: .init(0xF5F7FA, 0x0F141C), sidebar: .init(0xEAEEF3, 0x0A0E14), card: .init(0xFFFFFF, 0x18202C),
        text: .init(0x0F172A, 0xE8EDF5), mute: .init(0x5B6779, 0x98A3B3),
        accent: .init(0x2F74E8, 0x60A5FA), accentText: .init(0x1D5FD6, 0x7AB4FF), onAccent: .init(0xFFFFFF, 0x0A1B33),
        selectionAlpha: (0.14, 0.16)
    )

    /// 冷灰偏紫 + 紫
    static let lavender = FRPalette(
        window: .init(0xF7F6FB, 0x13111C), sidebar: .init(0xEEEBF6, 0x0E0C16), card: .init(0xFFFFFF, 0x1D1A2B),
        text: .init(0x1A1530, 0xEEEAF8), mute: .init(0x676080, 0xA39DB8),
        accent: .init(0x8B5CF6, 0xA78BFA), accentText: .init(0x6D3FD9, 0xB9A2FF), onAccent: .init(0xFFFFFF, 0x1B1035),
        selectionAlpha: (0.14, 0.16)
    )

    /// 暖灰 + 橙。橙色上白字对比度不足，两种外观都用深色字
    static let sunset = FRPalette(
        window: .init(0xFAF7F4, 0x17130F), sidebar: .init(0xF2ECE5, 0x110E0B), card: .init(0xFFFFFF, 0x221C17),
        text: .init(0x231A12, 0xF3ECE4), mute: .init(0x7A6A5C, 0xB0A293),
        accent: .init(0xF97316, 0xFB923C), accentText: .init(0xC2550A, 0xFFA868), onAccent: .init(0x2B1405, 0x2B1405),
        selectionAlpha: (0.14, 0.16)
    )

    /// 暖灰偏粉 + 玫瑰粉
    static let sakura = FRPalette(
        window: .init(0xFBF6F7, 0x171114), sidebar: .init(0xF4EAED, 0x110C0E), card: .init(0xFFFFFF, 0x22191D),
        text: .init(0x2A1419, 0xF5EAED), mute: .init(0x806670, 0xB8A0A8),
        accent: .init(0xE64A72, 0xFB7196), accentText: .init(0xC22D55, 0xFF8FAB), onAccent: .init(0xFFFFFF, 0x33081A),
        selectionAlpha: (0.13, 0.16)
    )

    /// 纯中性灰，无彩色强调
    static let graphite = FRPalette(
        window: .init(0xF6F6F7, 0x141416), sidebar: .init(0xECECEE, 0x0E0E10), card: .init(0xFFFFFF, 0x1E1E21),
        text: .init(0x18181B, 0xEDEDF0), mute: .init(0x6B6B73, 0xA1A1AA),
        accent: .init(0x2A2A2E, 0xE8E8EC), accentText: .init(0x18181B, 0xF4F4F5), onAccent: .init(0xFFFFFF, 0x18181B),
        selectionAlpha: (0.08, 0.10)
    )
}

/// 界面主题。颜色按系统外观动态取值，深色 / 浅色自动切换；主题色由 FRThemeID.current 决定
enum FRTheme {
    /// 窗口内容区背景
    static let window = themed(\.window)
    /// 侧边栏背景
    static let sidebar = themed(\.sidebar)
    /// 卡片背景
    static let card = themed(\.card)
    /// 卡片 / 分隔线描边
    static let border = themed(\.border)

    /// 主文字
    static let text = themed(\.text)
    /// 次要文字
    static let mute = themed(\.mute)

    /// 强调色（填充用）
    static let accent = themed(\.accent)
    /// 强调色（文字 / 图标用）：浅色下加深，保证在浅底上的对比度
    static let accentText = themed(\.accentText)
    /// 压在强调色填充上的文字
    static let onAccent = themed(\.onAccent)
    /// 选中 / 图标底色：强调色的淡化版
    static let selection = themed(\.selection)
    /// 悬停底色
    static let hover = themed(\.hover)

    /// 按钮 / 选择器 / 输入框底色与描边
    static let field = themed(\.field)
    static let fieldBorder = themed(\.fieldBorder)

    /// 状态色：表达含义，不随主题变化
    static let okBackground = dynamic(FRColorPair(NSColor(hex: 0x109664, alpha: 0.12), NSColor(hex: 0x50DCA0, alpha: 0.16)))
    static let okText = dynamic(FRColorPair(0x0B7A5A, 0x6EE7B7))
    static let warnBackground = dynamic(FRColorPair(NSColor(hex: 0xDC7800, alpha: 0.14), NSColor(hex: 0xFFAA3C, alpha: 0.16)))
    static let warnText = dynamic(FRColorPair(0x9A5200, 0xFFB84D))
    static let danger = dynamic(FRColorPair(0xC62828, 0xFF7A7A))

    /// 指定主题的强调色，供主题色块预览使用（不受当前主题影响）
    static func accent(of theme: FRThemeID) -> Color {
        dynamic(theme.palette.accent)
    }

    private static func themed(_ key: KeyPath<FRPalette, FRColorPair>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            resolve(FRThemeID.current.palette[keyPath: key], for: appearance)
        })
    }

    private static func dynamic(_ pair: FRColorPair) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            resolve(pair, for: appearance)
        })
    }

    private static func resolve(_ pair: FRColorPair, for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - 页面外壳

/// 设置页统一外壳：大标题 + 可选副标题 + 可滚动内容
struct FRPage<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(FRTheme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundColor(FRTheme.mute)
                    }
                }
                content
            }
            .padding(.horizontal, 30)
            .padding(.top, 30)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 一组设置：小标题 + 卡片 + 可选脚注
struct FRSection<Content: View, Header: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
        }
    }
}

extension FRSection where Header == FRCaption {
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.header = FRCaption(title)
        self.content = content()
    }
}

/// 卡片上方的小标题
struct FRCaption: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FRTheme.mute)
            .padding(.leading, 4)
    }
}

/// 卡片下方的说明文字
struct FRFootnote: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(.system(size: 12))
            .foregroundColor(FRTheme.mute)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

// MARK: - 卡片与行

struct FRCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FRTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(FRTheme.border, lineWidth: 1))
    }
}

/// 卡片内行与行之间的分隔线
struct FRDivider: View {
    var body: some View {
        Rectangle()
            .fill(FRTheme.border)
            .frame(height: 1)
    }
}

/// 标准设置行：左侧标题 + 说明，右侧放任意控件
struct FRRow<Trailing: View>: View {
    let title: Text
    var subtitle: Text? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                if let subtitle {
                    subtitle
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
    }
}

extension FRRow where Trailing == EmptyView {
    init(title: Text, subtitle: Text? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = EmptyView()
    }
}

// MARK: - 控件

/// 开关：沿用系统原生开关（保留无障碍与键盘支持），只把开启色换成主题强调色
struct FRSwitch: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(FRTheme.accent)
    }
}

/// 下拉选择器：系统菜单样式，隐藏自带标签（标题由所在行提供）
struct FRPicker<Selection: Hashable, Content: View>: View {
    let label: LocalizedStringKey
    @Binding var selection: Selection
    @ViewBuilder let content: Content

    var body: some View {
        Picker(label, selection: $selection) {
            content
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

/// 主题色选择：一排可直接点选的色块，选中项外加一圈描边
struct FRThemeSwatches: View {
    @Binding var selection: FRThemeID

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FRThemeID.allCases) { theme in
                let isSelected = selection == theme
                Button {
                    selection = theme
                } label: {
                    Circle()
                        .fill(FRTheme.accent(of: theme))
                        .overlay(Circle().strokeBorder(FRTheme.border, lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(isSelected ? FRTheme.text.opacity(0.6) : Color.clear, lineWidth: 1.5)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text(LocalizedStringKey(theme.titleKey)))
                .accessibilityLabel(Text(LocalizedStringKey(theme.titleKey)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

struct FRButtonStyle: ButtonStyle {
    enum Kind {
        case secondary
        case primary
    }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        FRButtonBody(kind: kind, configuration: configuration)
    }
}

private struct FRButtonBody: View {
    let kind: FRButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let primary = kind == .primary
        configuration.label
            .font(.system(size: 12.5, weight: primary ? .semibold : .medium))
            .foregroundColor(primary ? FRTheme.onAccent : FRTheme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(primary ? FRTheme.accent : FRTheme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(primary ? Color.clear : FRTheme.fieldBorder, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == FRButtonStyle {
    static var frSecondary: FRButtonStyle { FRButtonStyle(kind: .secondary) }
    static var frPrimary: FRButtonStyle { FRButtonStyle(kind: .primary) }
}

/// 文字链接式按钮（小号强调色文字）
struct FRLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FRLinkBody(configuration: configuration)
    }
}

private struct FRLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FRTheme.accentText)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
    }
}

extension ButtonStyle where Self == FRLinkButtonStyle {
    static var frLink: FRLinkButtonStyle { FRLinkButtonStyle() }
}

/// 状态小标签
struct FRChip: View {
    enum Kind {
        case ok
        case warn
        case neutral
    }

    let text: Text
    var kind: Kind = .neutral

    var body: some View {
        text
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
            .fixedSize()
    }

    private var foreground: Color {
        switch kind {
        case .ok: return FRTheme.okText
        case .warn: return FRTheme.warnText
        case .neutral: return FRTheme.mute
        }
    }

    private var background: Color {
        switch kind {
        case .ok: return FRTheme.okBackground
        case .warn: return FRTheme.warnBackground
        case .neutral: return FRTheme.hover
        }
    }
}

/// 圆角方块图标（功能、终端、权限等行的前导图标）
struct FRIconChip: View {
    let systemName: String
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundColor(FRTheme.accentText)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(FRTheme.selection))
    }
}

/// 行首拖动把手
struct FRGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(FRTheme.mute.opacity(0.8))
            .frame(width: 18, height: 24)
            .contentShape(Rectangle())
    }
}
