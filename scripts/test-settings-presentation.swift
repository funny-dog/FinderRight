import AppKit

@main
enum SettingsPresentationTests {
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let full = NSRect(x: 400, y: 200, width: 780, height: 620)
        let compact = SettingsWindowLayout.frame(from: full, size: SettingsWindowLayout.compactSize, visibleFrame: screen)
        precondition(compact.size == NSSize(width: 340, height: 224))
        precondition(compact.maxX == full.maxX && compact.maxY == full.maxY)
        precondition(SettingsWindowLayout.frame(from: compact, size: full.size, visibleFrame: screen) == full)

        let edge = NSRect(x: 0, y: 0, width: 340, height: 224)
        let expanded = SettingsWindowLayout.frame(from: edge, size: full.size, visibleFrame: screen)
        precondition(screen.contains(expanded))
        let leftScreen = NSRect(x: -1440, y: -120, width: 1440, height: 900)
        let otherDisplay = SettingsWindowLayout.frame(from: edge.offsetBy(dx: -1440, dy: -120), size: full.size, visibleFrame: leftScreen)
        precondition(leftScreen.contains(otherDisplay))

        let suite = "FinderRight.SettingsPresentationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let presentation = SettingsPresentation(defaults: defaults)
        precondition(!presentation.isCompact)
        presentation.toggle(reduceMotion: false)
        precondition(presentation.isCompact && !presentation.isTransitioning)
        precondition(SettingsPresentation(defaults: defaults).isCompact)
        presentation.toggle(reduceMotion: true)
        precondition(!presentation.isCompact && !SettingsPresentation(defaults: defaults).isCompact)
        print("PASS: 简洁模式尺寸、右上角锚点、屏幕边界、多屏坐标与模式持久化")
    }
}
