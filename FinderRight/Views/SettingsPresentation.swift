import AppKit
import SwiftUI
import QuartzCore

enum SettingsWindowLayout {
    static let compactSize = NSSize(width: 340, height: 280)
    static let minimumFullSize = NSSize(width: 680, height: 500)
    static let defaultFullSize = NSSize(width: 780, height: 620)
    static let duration = 0.72

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
    @Published private(set) var showsContent = true
    private weak var window: NSWindow?
    private let defaults: UserDefaults
    private var fullSize: NSSize
    private var transitionID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCompact = defaults.bool(forKey: Self.compactKey)
        if let size = defaults.array(forKey: Self.fullSizeKey) as? [Double], size.count == 2 {
            fullSize = NSSize(width: max(size[0], SettingsWindowLayout.minimumFullSize.width),
                              height: max(size[1], SettingsWindowLayout.minimumFullSize.height))
        } else {
            fullSize = SettingsWindowLayout.defaultFullSize
        }
    }

    func attach(to window: NSWindow) {
        transitionID = UUID()
        isTransitioning = false
        showsContent = true
        self.window = window
        let size = isCompact ? SettingsWindowLayout.compactSize : fullSize
        window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        window.center()
        _ = window.setFrameUsingName(frameName)
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
        if compact, let currentWindow {
            fullSize = currentWindow.frame.size
            defaults.set([Double(fullSize.width), Double(fullSize.height)], forKey: Self.fullSizeKey)
        }
        currentWindow?.saveFrame(usingName: frameName)
        currentWindow?.setFrameAutosaveName("")
        isTransitioning = currentWindow != nil && !reduceMotion
        showsContent = !isTransitioning
        isCompact = compact
        defaults.set(compact, forKey: Self.compactKey)
        guard let window = currentWindow else { return }

        if isTransitioning {
            DispatchQueue.main.asyncAfter(deadline: .now() + SettingsWindowLayout.duration * 0.6) { [weak self] in
                guard let self, self.transitionID == id else { return }
                self.showsContent = true
            }
        }

        window.minSize = SettingsWindowLayout.compactSize
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let size = compact ? SettingsWindowLayout.compactSize : fullSize
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let target = SettingsWindowLayout.frame(from: window.frame, size: size, visibleFrame: visibleFrame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : SettingsWindowLayout.duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.19, 1)
            window.animator().setFrame(target, display: true)
        } completionHandler: { [weak self, weak window] in
            guard let self, let window, self.transitionID == id, self.window === window else { return }
            self.isTransitioning = false
            self.showsContent = true
            self.applySizeLimits(to: window)
            window.saveFrame(usingName: self.frameName)
            window.setFrameAutosaveName(self.frameName)
        }
    }

    private func applySizeLimits(to window: NSWindow) {
        if isCompact {
            window.styleMask.remove(.resizable)
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            window.setFrame(SettingsWindowLayout.frame(from: window.frame,
                            size: SettingsWindowLayout.compactSize, visibleFrame: visibleFrame), display: false)
        } else {
            window.styleMask.insert(.resizable)
        }
        window.minSize = isCompact ? SettingsWindowLayout.compactSize : SettingsWindowLayout.minimumFullSize
        window.maxSize = isCompact ? SettingsWindowLayout.compactSize
            : NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.standardWindowButton(.zoomButton)?.isEnabled = !isCompact
    }
}
