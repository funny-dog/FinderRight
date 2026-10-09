import SwiftUI
import AppKit

// MARK: - 主题：午夜蓝 + 薄荷

/// 界面主题。颜色按系统外观动态取值，深色 / 浅色自动切换，不需要在设置里另做开关。
enum FRTheme {
    /// 窗口内容区背景
    static let window = dynamic(light: NSColor(hex: 0xF5F7FB), dark: NSColor(hex: 0x0F1626))
    /// 侧边栏背景
    static let sidebar = dynamic(light: NSColor(hex: 0xE8EDF5), dark: NSColor(hex: 0x0B1220))
    /// 卡片背景
    static let card = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x17223A))
    /// 卡片 / 分隔线描边
    static let border = dynamic(light: NSColor(hex: 0x0B1220, alpha: 0.09), dark: NSColor(hex: 0xFFFFFF, alpha: 0.08))

    /// 主文字
    static let text = dynamic(light: NSColor(hex: 0x0B1220), dark: NSColor(hex: 0xEAF0FA))
    /// 次要文字
    static let mute = dynamic(light: NSColor(hex: 0x596680), dark: NSColor(hex: 0x97A4BD))

    /// 强调色（填充用）：薄荷绿
    static let accent = dynamic(light: NSColor(hex: 0x2BD4A0), dark: NSColor(hex: 0x4FE3B1))
    /// 强调色（文字 / 图标用）：浅色下加深，保证在浅底上的对比度
    static let accentText = dynamic(light: NSColor(hex: 0x0B7A5A), dark: NSColor(hex: 0x4FE3B1))
    /// 压在强调色填充上的文字
    static let onAccent = dynamic(light: NSColor(hex: 0x04251B), dark: NSColor(hex: 0x062B20))
    /// 选中 / 图标底色：强调色的淡化版
    static let selection = dynamic(light: NSColor(hex: 0x2BD4A0, alpha: 0.20), dark: NSColor(hex: 0x4FE3B1, alpha: 0.16))
    /// 悬停底色
    static let hover = dynamic(light: NSColor(hex: 0x0B1220, alpha: 0.05), dark: NSColor(hex: 0xFFFFFF, alpha: 0.06))

    /// 按钮 / 选择器 / 输入框底色与描边
    static let field = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0xFFFFFF, alpha: 0.06))
    static let fieldBorder = dynamic(light: NSColor(hex: 0x0B1220, alpha: 0.16), dark: NSColor(hex: 0xFFFFFF, alpha: 0.14))

    /// 状态色
    static let okBackground = dynamic(light: NSColor(hex: 0x109664, alpha: 0.12), dark: NSColor(hex: 0x50DCA0, alpha: 0.16))
    static let okText = dynamic(light: NSColor(hex: 0x0B7A5A), dark: NSColor(hex: 0x6EE7B7))
    static let warnBackground = dynamic(light: NSColor(hex: 0xDC7800, alpha: 0.14), dark: NSColor(hex: 0xFFAA3C, alpha: 0.16))
    static let warnText = dynamic(light: NSColor(hex: 0x9A5200), dark: NSColor(hex: 0xFFB84D))
    static let danger = dynamic(light: NSColor(hex: 0xC62828), dark: NSColor(hex: 0xFF7A7A))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
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
