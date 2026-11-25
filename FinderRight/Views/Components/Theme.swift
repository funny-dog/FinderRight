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
    static let switchOffTrack = themed(\.switchOffTrack)
    static let switchOffKnob = themed(\.switchOffKnob)
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

    /// 分段选择器轨道、滑块及下拉触发器动态色
    static let segmentedTrack = themed(\.segmentedTrack)
    static let segmentedTrackBorder = themed(\.segmentedTrackBorder)
    static let segmentedThumb = themed(\.segmentedThumb)
    static let segmentedThumbBorder = themed(\.segmentedThumbBorder)
    static let dropdownFill = themed(\.dropdownFill)
    static let dropdownHoverFill = themed(\.dropdownHoverFill)
    static let cardShadow = themed(\.cardShadow)

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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(FRTheme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13.5))
                            .foregroundColor(FRTheme.mute)
                    }
                }
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
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
        .shadow(color: FRTheme.cardShadow, radius: 3, y: 1)
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

    @FRState private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let width: CGFloat = 38
    private let height: CGFloat = 22
    private let inset: CGFloat = 2

    var body: some View {
        let activeHover = isHovering && isEnabled
        Button {
            if reduceMotion {
                isOn.toggle()
            } else {
                withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() }
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? FRTheme.accent : FRTheme.switchOffTrack)
                    .overlay(
                        Capsule()
                            .strokeBorder(activeHover ? FRTheme.accentText.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                Circle()
                    .fill(isOn ? FRTheme.onAccent : FRTheme.switchOffKnob)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(inset)
            }
            .frame(width: width, height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: activeHover)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(label, isOn: $isOn)
        }
    }
}

/// 胶囊分段选择器：外层微凹轨道，内层浮起高亮胶囊，适用于二选一或少量固定选项
struct FRSegmentedPicker<Selection: Hashable>: View {
    let label: LocalizedStringKey
    @Binding var selection: Selection
    let options: [(value: Selection, titleKey: String)]

    @FRState private var hovered: Selection?
    @Namespace private var thumbNamespace
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSmall: Bool { controlSize == .small }

    init(label: LocalizedStringKey, selection: Binding<Selection>, options: [(value: Selection, titleKey: String)]) {
        self.label = label
        self._selection = selection
        self.options = options
    }

    init<Data: RandomAccessCollection>(
        label: LocalizedStringKey,
        selection: Binding<Selection>,
        _ data: Data,
        titleKey: KeyPath<Data.Element, String>
    ) where Data.Element == Selection {
        self.label = label
        self._selection = selection
        self.options = data.map { ($0, $0[keyPath: titleKey]) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = selection == option.value
                let isHovered = hovered == option.value
                Button {
                    if reduceMotion {
                        selection = option.value
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selection = option.value
                        }
                    }
                } label: {
                    Text(LocalizedStringKey(option.titleKey))
                        .font(.system(size: isSmall ? 11.5 : 12.5, weight: isSelected ? .semibold : .medium))
                        .foregroundColor(isSelected ? FRTheme.accentText : (isHovered ? FRTheme.text.opacity(0.88) : FRTheme.mute))
                        .lineLimit(1)
                        .padding(.horizontal, isSmall ? 9 : 12)
                        .padding(.vertical, isSmall ? 4 : 5)
                        .background {
                            if isSelected {
                                selectedCapsule
                            } else if isHovered {
                                Capsule()
                                    .fill(FRTheme.hover)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = option.value
                    } else if hovered == option.value {
                        hovered = nil
                    }
                }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(isSmall ? 2.5 : 3)
        .background(Capsule().fill(FRTheme.segmentedTrack))
        .overlay(Capsule().strokeBorder(FRTheme.segmentedTrackBorder, lineWidth: 1))
        .fixedSize()
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private var selectedCapsule: some View {
        let base = Capsule()
            .fill(FRTheme.segmentedThumb)
            .overlay(Capsule().strokeBorder(FRTheme.segmentedThumbBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        if reduceMotion {
            base
        } else {
            base.matchedGeometryEffect(id: "thumb", in: thumbNamespace)
        }
    }
}

/// 深色模式分段选择器：通用设置与简洁模式共用；尺寸自动响应外层 `.controlSize(...)`。
struct FRAppearancePicker: View {
    @AppStorage(FRAppearanceMode.storageKey) private var appearanceRaw = FRAppearanceMode.system.rawValue

    var body: some View {
        FRSegmentedPicker(
            label: "深色模式",
            selection: Binding(
                get: { FRAppearanceMode(rawValue: appearanceRaw) ?? .system },
                set: { newValue in
                    guard newValue.rawValue != appearanceRaw else { return }
                    appearanceRaw = newValue.rawValue
                    newValue.apply()
                }
            ),
            FRAppearanceMode.allCases,
            titleKey: \.titleKey
        )
    }
}

/// 下拉选择器：自定义胶囊触发器 + 原生系统菜单（保留勾选、键盘导航与无障碍语义）
struct FRPicker<Selection: Hashable, Content: View>: View {
    let label: LocalizedStringKey
    let title: Text
    @Binding var selection: Selection
    var fullWidth: Bool = false
    @ViewBuilder let content: Content

    @FRState private var isHovering = false
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        label: LocalizedStringKey,
        title: Text,
        selection: Binding<Selection>,
        fullWidth: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.title = title
        self._selection = selection
        self.fullWidth = fullWidth
        self.content = content()
    }

    init(
        label: LocalizedStringKey,
        titleKey: String,
        selection: Binding<Selection>,
        fullWidth: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            label: label,
            title: Text(LocalizedStringKey(titleKey)),
            selection: selection,
            fullWidth: fullWidth,
            content: content
        )
    }

    private var isSmall: Bool { controlSize == .small }

    var body: some View {
        let activeHover = isHovering && isEnabled
        Menu {
            Picker(label, selection: $selection) {
                content
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: isSmall ? 6 : 8) {
                title
                    .font(.system(size: isSmall ? 11.5 : 12.5, weight: .medium))
                    .foregroundColor(FRTheme.text)
                    .lineLimit(1)
                if fullWidth {
                    Spacer(minLength: 8)
                }
                ZStack {
                    Circle()
                        .fill(activeHover ? FRTheme.selection : FRTheme.segmentedTrack)
                        .frame(width: isSmall ? 16 : 20, height: isSmall ? 16 : 20)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: isSmall ? 8.5 : 9.5, weight: .semibold))
                        .foregroundColor(activeHover ? FRTheme.accentText : FRTheme.mute)
                }
            }
            .padding(.leading, isSmall ? 10 : 12)
            .padding(.trailing, isSmall ? 5 : 6)
            .frame(height: isSmall ? 24 : 28)
            .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
            .background(Capsule().fill(activeHover ? FRTheme.dropdownHoverFill : FRTheme.dropdownFill))
            .overlay(
                Capsule().strokeBorder(activeHover ? FRTheme.accentText.opacity(0.45) : FRTheme.fieldBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
            .contentShape(Capsule())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: activeHover)
        .accessibilityLabel(Text(label))
    }
}

/// 主题色选择：一排可直接点选的色块，选中项外加一圈描边
struct FRThemeSwatches: View {
    @Binding var selection: FRThemeID
    @FRState private var hovered: FRThemeID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FRThemeID.allCases) { theme in
                let isSelected = selection == theme
                let isHovered = hovered == theme
                Button {
                    selection = theme
                } label: {
                    Circle()
                        .fill(FRTheme.accent(of: theme))
                        .overlay(Circle().strokeBorder(FRTheme.border, lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(
                            Circle().strokeBorder(
                                isSelected ? FRTheme.text.opacity(0.6) : (isHovered ? FRTheme.text.opacity(0.28) : Color.clear),
                                lineWidth: 1.5
                            )
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = theme
                    } else if hovered == theme {
                        hovered = nil
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
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
    var maxCount: Int? = nil

    private var sampleFeatures: [MenuFeature] {
        let sampleIds = [
            MenuFeatureCatalog.newFile,
            MenuFeatureCatalog.copyPath,
            MenuFeatureCatalog.openTerminal,
            MenuFeatureCatalog.openEditor,
            MenuFeatureCatalog.cut,
        ]
        let list = sampleIds.compactMap { MenuFeatureCatalog.feature(forId: $0) }
        if let maxCount {
            return Array(list.prefix(maxCount))
        }
        return list
    }

    var body: some View {
        HStack(spacing: 6) {
            if style == .none {
                if maxCount == nil {
                    Text(LocalizedStringKey("无图标"))
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                        .padding(.horizontal, 4)
                }
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
        case destructive
    }

    var kind: Kind = .secondary
    var isCapsule: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        FRButtonBody(kind: kind, isCapsule: isCapsule, configuration: configuration)
    }
}

private struct FRButtonBody: View {
    let kind: FRButtonStyle.Kind
    let isCapsule: Bool
    let configuration: ButtonStyleConfiguration
    @FRState private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var activeHover: Bool { isHovering && isEnabled }

    // 胶囊危险按钮（高 28、圆角 14）用于与同行 FRPicker 胶囊对齐；常规按钮统一圆角 8
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isCapsule ? 14 : 8, style: .continuous)
    }

    private var textColor: Color {
        switch kind {
        case .primary: return FRTheme.onAccent
        case .destructive: return FRTheme.danger
        case .secondary: return FRTheme.text
        }
    }

    private var fillColor: Color {
        switch kind {
        case .primary: return FRTheme.accent
        case .destructive: return activeHover ? FRTheme.dropdownHoverFill : (isCapsule ? FRTheme.dropdownFill : FRTheme.field)
        case .secondary: return activeHover ? FRTheme.dropdownHoverFill : FRTheme.field
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: return .clear
        case .destructive: return activeHover ? FRTheme.danger.opacity(0.45) : FRTheme.fieldBorder
        case .secondary: return activeHover ? FRTheme.accentText.opacity(0.35) : FRTheme.fieldBorder
        }
    }

    private var pressedOpacity: Double {
        guard isEnabled else { return 0.45 }
        guard configuration.isPressed else { return 1 }
        return kind == .primary ? 0.82 : 0.72
    }

    var body: some View {
        let primary = kind == .primary
        configuration.label
            .font(.system(size: 12.5, weight: primary ? .semibold : .medium))
            .foregroundColor(textColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, isCapsule ? 14 : 12)
            .padding(.vertical, isCapsule ? 0 : 5)
            .frame(height: isCapsule ? 28 : nil)
            .background(
                shape.fill(fillColor)
                    .overlay(shape.fill(primary && activeHover ? Color.white.opacity(0.10) : Color.clear))
            )
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            .shadow(color: .black.opacity(isCapsule ? 0.06 : 0), radius: 2, y: 1)
            .opacity(pressedOpacity)
            .contentShape(shape)
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: activeHover)
    }
}

extension ButtonStyle where Self == FRButtonStyle {
    static var frSecondary: FRButtonStyle { FRButtonStyle(kind: .secondary) }
    static var frPrimary: FRButtonStyle { FRButtonStyle(kind: .primary) }
    static var frDestructive: FRButtonStyle { FRButtonStyle(kind: .destructive) }
    static var frDestructiveCapsule: FRButtonStyle { FRButtonStyle(kind: .destructive, isCapsule: true) }
}

/// 文字链接式按钮（小号强调色文字）
struct FRLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        FRLinkBody(configuration: configuration)
    }
}

private struct FRLinkBody: View {
    let configuration: ButtonStyleConfiguration
    @FRState private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let activeHover = isHovering && isEnabled
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(FRTheme.accentText)
            .underline(activeHover)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: activeHover)
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
    enum Style {
        case accent
        case subtle
    }

    let systemName: String
    var size: CGFloat = 30
    var style: Style = .accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: systemName)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundColor(style == .accent ? FRTheme.accentText : FRTheme.text.opacity(0.76))
            .frame(width: size, height: size)
            .background(shape.fill(style == .accent ? FRTheme.selection : FRTheme.hover))
            .overlay(
                shape.strokeBorder(style == .subtle ? FRTheme.border : Color.clear, lineWidth: 0.5)
            )
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

/// 统一输入框容器：可选前置图标 + 圆角 8 描边 + 悬停 / 焦点态高亮
struct FRTextFieldContainer<Content: View>: View {
    var symbol: String? = nil
    var isFocused: Bool = false
    var height: CGFloat? = 32
    @ViewBuilder let content: Content

    @FRState private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12.5))
                    .foregroundColor(isFocused ? FRTheme.accentText : FRTheme.mute)
                    .accessibilityHidden(true)
            }
            content
        }
        .padding(.horizontal, 10)
        .padding(.vertical, height == nil ? 6 : 0)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FRTheme.field))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
        )
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isFocused)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
    }

    private var borderColor: Color {
        if isFocused { return FRTheme.accent }
        if isHovering { return FRTheme.text.opacity(0.25) }
        return FRTheme.fieldBorder
    }
}

/// 统一行内图标按钮：26×26 触控区，悬停柔和底色，删除类操作悬停显警示色
struct FRIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    var isDestructive: Bool = false
    let action: () -> Void

    @FRState private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let activeHover = isHovering && isEnabled
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(activeHover ? (isDestructive ? FRTheme.danger : FRTheme.text) : FRTheme.mute)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(activeHover ? (isDestructive ? FRTheme.danger.opacity(0.12) : FRTheme.hover) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: activeHover)
        .help(help)
        .accessibilityLabel(Text(help))
    }
}

extension View {
    /// 拖拽排序目标行反馈：轻柔高亮 + 顶部 2pt 强调色插入指示线
    func frDropTarget(_ isTargeted: Bool) -> some View {
        background(isTargeted ? FRTheme.selection.opacity(0.35) : Color.clear)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(FRTheme.accent)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .opacity(isTargeted ? 1 : 0)
            }
    }
}
