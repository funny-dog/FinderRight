import SwiftUI

struct SettingsModeButton: View {
    let isCompact: Bool
    let isTransitioning: Bool
    let reduceMotion: Bool
    let action: () -> Void
    @FRState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(0..<3) { index in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(FRTheme.accentText)
                            .frame(width: 4, height: index == 1 && !isCompact ? 8 : 12)
                            .offset(x: isCompact ? CGFloat(1 - index) * 6 : 0)
                            .opacity(isCompact && index != 1 ? 0 : 1)
                    }
                }
                .frame(width: 16, height: 16)
                Text(LocalizedStringKey(isCompact ? "完整模式" : "简洁模式"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(FRTheme.text)
                Circle()
                    .fill(FRTheme.accentText)
                    .frame(width: 4, height: 4)
                    .opacity(isCompact ? 1 : 0)
            }
            .frame(width: 146, height: 32)
            .background(Capsule().fill(isHovering ? FRTheme.selection : FRTheme.card))
            .overlay(Capsule().strokeBorder(isHovering ? FRTheme.accentText.opacity(0.65) : FRTheme.border))
            .shadow(color: FRTheme.accent.opacity(isHovering ? 0.16 : 0), radius: 8)
            .contentShape(Capsule())
        }
        .buttonStyle(SettingsModePressStyle(reduceMotion: reduceMotion))
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: isCompact)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovering)
        .disabled(isTransitioning)
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

struct SettingsModeEffect: View {
    let isCollapsing: Bool
    @FRState private var progress: CGFloat = 0

    var body: some View {
        SettingsSpeedLines(progress: progress, isCollapsing: isCollapsing)
            .onAppear {
                withAnimation(.linear(duration: SettingsWindowLayout.duration)) { progress = 1 }
            }
    }
}

private struct SettingsSpeedLines: View, Animatable {
    var progress: CGFloat
    let isCollapsing: Bool
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            let distance = max(size.width, size.height)
            let travel = isCollapsing ? 1 - progress : progress
            let origin = CGPoint(x: size.width - 85, y: 25)
            for index in 0..<28 {
                let angle = CGFloat.pi * (0.3 + 0.65 * CGFloat(index) / 27)
                let spread = 0.25 + CGFloat((index * 13) % 28) / 28
                let radius = 16 + distance * travel * spread
                let length = (12 + CGFloat(index % 5) * 8) * sin(progress * .pi)
                let start = CGPoint(x: origin.x + cos(angle) * radius,
                                    y: origin.y + sin(angle) * radius)
                let end = CGPoint(x: start.x + cos(angle) * length,
                                  y: start.y + sin(angle) * length)
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)
                context.stroke(path, with: .linearGradient(
                    Gradient(colors: [.clear, FRTheme.accentText.opacity(Double(sin(progress * .pi)) * 0.75)]),
                    startPoint: start, endPoint: end), style: StrokeStyle(lineWidth: index % 3 == 0 ? 1.4 : 0.8, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
