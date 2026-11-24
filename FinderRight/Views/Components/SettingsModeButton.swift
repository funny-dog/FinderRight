import SwiftUI

struct SettingsModeButton: View {
    let isCompact: Bool
    let isTransitioning: Bool
    let reduceMotion: Bool
    let action: () -> Void
    @FRState private var isHovering = false

    var body: some View {
        let activeHover = isHovering && !isTransitioning
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isCompact ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(activeHover ? FRTheme.accentText : FRTheme.mute)
                Text(LocalizedStringKey(isCompact ? "完整模式" : "简洁模式"))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(activeHover ? FRTheme.accentText : FRTheme.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .fixedSize()
            .background(Capsule().fill(activeHover ? FRTheme.selection : FRTheme.dropdownFill))
            .overlay(
                Capsule().strokeBorder(activeHover ? FRTheme.accentText.opacity(0.45) : FRTheme.fieldBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.05), radius: 1.5, y: 0.5)
            .contentShape(Capsule())
        }
        .buttonStyle(SettingsModePressStyle(reduceMotion: reduceMotion))
        .onHover { isHovering = $0 }
        .disabled(isTransitioning)
        .opacity(isTransitioning ? 0.6 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: activeHover)
        .help(isCompact ? Text("恢复完整设置窗口") : Text("收起为简洁窗口"))
        .accessibilityLabel(isCompact ? Text("切换到完整模式") : Text("切换到简洁模式"))
    }
}

private struct SettingsModePressStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
