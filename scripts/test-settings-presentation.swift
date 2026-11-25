import AppKit
import SwiftUI

@main
enum SettingsPresentationTests {
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let full = NSRect(x: 400, y: 200, width: 780, height: 620)
        let compact = SettingsWindowLayout.frame(from: full, size: SettingsWindowLayout.compactSize, visibleFrame: screen)
        precondition(compact.size == SettingsWindowLayout.compactSize)
        precondition(compact.maxX == full.maxX && compact.maxY == full.maxY)
        precondition(SettingsWindowLayout.frame(from: compact, size: full.size, visibleFrame: screen) == full)
        precondition(SettingsWindowLayout.minimumFullSize == NSSize(width: 620, height: 440))
        precondition(SettingsWindowLayout.defaultFullSize == NSSize(width: 780, height: 620))

        let edge = NSRect(x: 0, y: 0, width: SettingsWindowLayout.compactSize.width, height: SettingsWindowLayout.compactSize.height)
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
        precondition(presentation.fullSize == SettingsWindowLayout.defaultFullSize)
        presentation.toggle(reduceMotion: false)
        precondition(presentation.isCompact && !presentation.isTransitioning)
        precondition(SettingsPresentation(defaults: defaults).isCompact)

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = StubRestoredSettingsWindow(restoredFrame: full)
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
        precondition(window.minSize == SettingsWindowLayout.minimumFullSize)
        precondition(window.frame.size == full.size)

        // 旧缓存若小于最小完整尺寸，attach 后应自动抬升至 minimumFullSize
        let smallWindow = StubRestoredSettingsWindow(restoredFrame: NSRect(x: 200, y: 200, width: 560, height: 380))
        let smallPresentation = SettingsPresentation(defaults: defaults)
        smallPresentation.attach(to: smallWindow)
        precondition(smallWindow.frame.size == SettingsWindowLayout.minimumFullSize)
        precondition(smallPresentation.fullSize == SettingsWindowLayout.minimumFullSize)
        smallWindow.close()

        // 介于最小与默认之间的合法缓存（720×560）应原样保留，切换简洁后再切回也不重置为默认
        let midSuite = "FinderRight.SettingsPresentationMidTests.\(UUID().uuidString)"
        let midDefaults = UserDefaults(suiteName: midSuite)!
        defer { midDefaults.removePersistentDomain(forName: midSuite) }
        let midSize = NSSize(width: 720, height: 560)
        let midWindow = StubRestoredSettingsWindow(restoredFrame: NSRect(origin: NSPoint(x: 220, y: 160), size: midSize))
        let midPresentation = SettingsPresentation(defaults: midDefaults)
        midPresentation.attach(to: midWindow)
        precondition(midWindow.frame.size == midSize)
        precondition(midPresentation.fullSize == midSize)
        midPresentation.toggle(reduceMotion: true)
        precondition(midWindow.frame.size == SettingsWindowLayout.compactSize)
        midPresentation.toggle(reduceMotion: true)
        precondition(midWindow.frame.size == midSize)
        precondition(SettingsPresentation(defaults: midDefaults).fullSize == midSize)
        midWindow.close()

        // 自定义大窗口切入简洁模式再切回完整模式时，应维持之前的尺寸而非回退默认窗口
        let customSuite = "FinderRight.SettingsPresentationCustomTests.\(UUID().uuidString)"
        let customDefaults = UserDefaults(suiteName: customSuite)!
        defer { customDefaults.removePersistentDomain(forName: customSuite) }
        let customSize = NSSize(width: 920, height: 700)
        let customWindow = StubRestoredSettingsWindow(restoredFrame: NSRect(origin: NSPoint(x: 240, y: 120), size: customSize))
        let customPresentation = SettingsPresentation(defaults: customDefaults)
        customPresentation.attach(to: customWindow)
        precondition(customPresentation.fullSize == customSize)
        customPresentation.toggle(reduceMotion: true)
        precondition(customPresentation.isCompact)
        precondition(customWindow.frame.size == SettingsWindowLayout.compactSize)
        customPresentation.toggle(reduceMotion: true)
        precondition(!customPresentation.isCompact)
        precondition(customWindow.frame.size == customSize)
        precondition(SettingsPresentation(defaults: customDefaults).fullSize == customSize)
        customWindow.close()

        // NSHostingView 经普通 NSView 容器包裹并清空 sizingOptions，布局后不得覆盖 NSWindow.minSize
        let hostedSuite = "FinderRight.SettingsPresentationHostedTests.\(UUID().uuidString)"
        let hostedDefaults = UserDefaults(suiteName: hostedSuite)!
        defer { hostedDefaults.removePersistentDomain(forName: hostedSuite) }
        let hostedWindow = StubRestoredSettingsWindow(restoredFrame: full)
        let container = NSView(frame: NSRect(origin: .zero, size: SettingsWindowLayout.defaultFullSize))
        let hostingView = NSHostingView(rootView: Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).ignoresSafeArea())
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = container.bounds
        container.addSubview(hostingView)
        hostedWindow.contentView = container
        let hostedPresentation = SettingsPresentation(defaults: hostedDefaults)
        hostedPresentation.attach(to: hostedWindow)
        hostedWindow.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(hostedWindow.minSize == SettingsWindowLayout.minimumFullSize)
        precondition(hostedWindow.contentMinSize == SettingsWindowLayout.minimumFullSize)
        hostedWindow.close()

        window.close()
        print("PASS: 简洁模式固定尺寸、可移动、旧尺寸恢复、完整模式缩放、屏幕边界与模式持久化")
    }
}

/// 模拟旧窗口尺寸缓存，避免测试读写用户的真实窗口位置。
private final class StubRestoredSettingsWindow: NSWindow {
    private let restoredFrame: NSRect

    init(restoredFrame: NSRect) {
        self.restoredFrame = restoredFrame
        super.init(contentRect: restoredFrame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override func setFrameUsingName(_ name: NSWindow.FrameAutosaveName) -> Bool {
        setFrame(restoredFrame, display: false)
        return true
    }

    override func setFrameAutosaveName(_ name: NSWindow.FrameAutosaveName) -> Bool { true }
    override func saveFrame(usingName name: NSWindow.FrameAutosaveName) {}
}
