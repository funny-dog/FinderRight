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

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = RestoredSettingsWindow(contentRect: full, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let compactPresentation = SettingsPresentation(defaults: defaults)
        compactPresentation.attach(to: window)
        precondition(window.frame.size == SettingsWindowLayout.compactSize)
        precondition(window.minSize == window.maxSize)
        precondition(!window.styleMask.contains(.resizable))
        precondition(window.isMovable && window.styleMask.contains(.titled))

        presentation.toggle(reduceMotion: true)
        precondition(!presentation.isCompact && !SettingsPresentation(defaults: defaults).isCompact)
        SettingsPresentation(defaults: defaults).attach(to: window)
        precondition(window.styleMask.contains(.resizable))
        precondition(window.frame.size == full.size)
        window.close()
        print("PASS: 简洁模式固定尺寸、可移动、旧尺寸恢复、完整模式缩放、屏幕边界与模式持久化")
    }
}

/// 模拟旧窗口尺寸缓存，避免测试读写用户的真实窗口位置。
private final class RestoredSettingsWindow: NSWindow {
    override func setFrameUsingName(_ name: NSWindow.FrameAutosaveName) -> Bool {
        setFrame(NSRect(x: 400, y: 200, width: 780, height: 620), display: false)
        return true
    }

    override func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool { true }
    override func saveFrame(usingName name: NSWindow.FrameAutosaveName) {}
}
