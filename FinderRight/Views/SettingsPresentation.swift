import AppKit
import SwiftUI
import QuartzCore

enum SettingsWindowLayout {
    static let compactSize = NSSize(width: 340, height: 280)
    static let minimumFullSize = NSSize(width: 620, height: 440)
    static let defaultFullSize = NSSize(width: 780, height: 620)
    static let duration = 0.28

    /// 将完整模式尺寸钳制到不小于最小完整尺寸。
    static func clampedFullSize(_ size: NSSize) -> NSSize {
        NSSize(
            width: max(size.width, minimumFullSize.width),
            height: max(size.height, minimumFullSize.height)
        )
    }

    /// 保持右上角不动；展开超出屏幕时，仅移动到可见区域内。
    static func frame(from current: NSRect, size: NSSize, visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: max(visibleFrame.minX, min(current.maxX - size.width, visibleFrame.maxX - size.width)),
            y: max(visibleFrame.minY, min(current.maxY - size.height, visibleFrame.maxY - size.height)),
            width: size.width, height: size.height
        )
    }
}

final class SettingsPresentation: ObservableObject {
    static let shared = SettingsPresentation()
    private static let compactKey = "compactSettings"
    private static let fullSizeKey = "fullSettingsSize"

    @Published private(set) var isCompact: Bool
    @Published private(set) var isTransitioning = false
    @Published private(set) var fullSize: NSSize
    private weak var window: NSWindow?
    private let defaults: UserDefaults
    private var transitionID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCompact = defaults.bool(forKey: Self.compactKey)
        if let size = defaults.array(forKey: Self.fullSizeKey) as? [Double], size.count == 2 {
            fullSize = SettingsWindowLayout.clampedFullSize(NSSize(width: size[0], height: size[1]))
        } else {
            fullSize = SettingsWindowLayout.defaultFullSize
        }
    }

    func attach(to window: NSWindow) {
        transitionID = UUID()
        isTransitioning = false
        self.window = window
        let size = isCompact ? SettingsWindowLayout.compactSize : fullSize
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.center()
        _ = window.setFrameUsingName(frameName)
        if !isCompact {
            let clamped = SettingsWindowLayout.clampedFullSize(window.frame.size)
            if clamped != window.frame.size {
                let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
                window.setFrame(SettingsWindowLayout.frame(from: window.frame, size: clamped, visibleFrame: visibleFrame),
                                display: false)
            }
            fullSize = window.frame.size
        }
        applySizeLimits(to: window)
        window.setFrameAutosaveName(frameName)
    }

    func toggle(reduceMotion: Bool) {
        setCompact(!isCompact, reduceMotion: reduceMotion)
    }

    func showFullSettings() {
        setCompact(false, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private var frameName: String { isCompact ? "FinderRightCompactSettings" : "FinderRightSettings" }

    private func setCompact(_ compact: Bool, reduceMotion: Bool) {
        guard compact != isCompact else { return }
        // 具体设置链接可以中断收拢；旧动画的完成回调不得覆盖新窗口状态。
        let id = UUID()
        transitionID = id
        let currentWindow = window
        if compact, let currentWindow, !isTransitioning {
            fullSize = SettingsWindowLayout.clampedFullSize(currentWindow.frame.size)
            defaults.set([Double(fullSize.width), Double(fullSize.height)], forKey: Self.fullSizeKey)
        }
        currentWindow?.saveFrame(usingName: frameName)
        currentWindow?.setFrameAutosaveName("")
        isTransitioning = currentWindow != nil && !reduceMotion
        isCompact = compact
        defaults.set(compact, forKey: Self.compactKey)
        guard let window = currentWindow else { return }

        window.minSize = SettingsWindowLayout.compactSize
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let size = compact ? SettingsWindowLayout.compactSize : SettingsWindowLayout.clampedFullSize(fullSize)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let target = SettingsWindowLayout.frame(from: window.frame, size: size, visibleFrame: visibleFrame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : SettingsWindowLayout.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [weak self, weak window] in
            guard let self, let window, self.transitionID == id, self.window === window else { return }
            self.isTransitioning = false
            self.applySizeLimits(to: window)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.transitionID == id, self.window === window else { return }
                window.saveFrame(usingName: self.frameName)
                window.setFrameAutosaveName(self.frameName)
            }
        }
    }

    private func applySizeLimits(to window: NSWindow) {
        if isCompact {
            window.styleMask.remove(.resizable)
            if window.frame.size != SettingsWindowLayout.compactSize {
                let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
                window.setFrame(SettingsWindowLayout.frame(from: window.frame,
                                size: SettingsWindowLayout.compactSize, visibleFrame: visibleFrame), display: false)
            }
        } else {
            window.styleMask.insert(.resizable)
        }
        window.minSize = isCompact ? SettingsWindowLayout.compactSize : SettingsWindowLayout.minimumFullSize
        window.maxSize = isCompact ? SettingsWindowLayout.compactSize
            : NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.standardWindowButton(.zoomButton)?.isEnabled = !isCompact
    }
}
