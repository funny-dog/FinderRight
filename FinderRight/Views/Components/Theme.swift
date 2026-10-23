import SwiftUI
import AppKit
@_exported import FinderRightKit


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
    /// 开关关闭态的轨道与滑块：比卡片底色明显亮一档，深色下也能一眼看出轮廓
    static let switchOffTrack = dynamic(FRColorPair(0xDCDCE1, 0x46464E))
    static let switchOffKnob = dynamic(FRColorPair(0xFFFFFF, 0xD4D4D8))
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
        pair.resolved(for: appearance)
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

/// 开关：自绘轨道与滑块，开 / 关两态颜色都由主题控制（原生开关的 tint 会被系统淡化，关闭态也改不了色）。
/// 外层用 Button 保留键盘操作，无障碍语义交给原生 Toggle 表达
struct FRSwitch: View {
    let label: LocalizedStringKey
    @Binding var isOn: Bool

    @Environment(\.isEnabled) private var isEnabled

    private let width: CGFloat = 38
    private let height: CGFloat = 22
    private let inset: CGFloat = 2

    /// 开启态滑块：石墨主题的强调色接近白 / 黑，滑块取反色（onAccent）形成明暗反转；其余主题用白色
    private var onKnob: Color {
        FRThemeID.current == .graphite ? FRTheme.onAccent : .white
    }

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? FRTheme.accent : FRTheme.switchOffTrack)
                Circle()
                    .fill(isOn ? onKnob : FRTheme.switchOffKnob)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(inset)
            }
            .frame(width: width, height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
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

/// 右键菜单图标风格实时预览（展示具有代表性的功能图标样式）
struct MenuIconPreview: View {
    let style: MenuIconStyle

    private var sampleFeatures: [MenuFeature] {
        let sampleIds = [
            MenuFeatureCatalog.newFile,
            MenuFeatureCatalog.copyPath,
            MenuFeatureCatalog.openTerminal,
            MenuFeatureCatalog.openEditor,
            MenuFeatureCatalog.cut,
        ]
        return sampleIds.compactMap { MenuFeatureCatalog.feature(forId: $0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            if style == .none {
                Text(LocalizedStringKey("无图标"))
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
                    .padding(.horizontal, 4)
            } else {
                ForEach(sampleFeatures) { feature in
                    sampleIcon(feature)
                        .help(Text(LocalizedStringKey(feature.nameKey)))
                }
            }
        }
        .frame(minHeight: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey("右键菜单预览")))
        .animation(.easeInOut(duration: 0.18), value: style)
    }

    @ViewBuilder
    private func sampleIcon(_ feature: MenuFeature) -> some View {
        switch style {
        case .tile:
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(nsColor: feature.tint.dynamicTileColor()))
                    .frame(width: 18, height: 18)
                Image(systemName: feature.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(feature.tint.darkGlyph ? Color(nsColor: NSColor(hex: 0x2B2200)) : .white)
            }
        case .tinted:
            Image(systemName: feature.systemImage)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundColor(Color(nsColor: feature.tint.dynamicLineColor()))
                .frame(width: 18, height: 18)
        case .modern:
            Image(systemName: feature.systemImage)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundColor(FRTheme.text)
                .frame(width: 18, height: 18)
        case .none:
            EmptyView()
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
        case accent
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
        case .accent: return FRTheme.accentText
        case .ok: return FRTheme.okText
        case .warn: return FRTheme.warnText
        case .neutral: return FRTheme.mute
        }
    }

    private var background: Color {
        switch kind {
        case .accent: return FRTheme.selection
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
