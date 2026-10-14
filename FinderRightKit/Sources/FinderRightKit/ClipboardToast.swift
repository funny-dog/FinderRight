import AppKit

/// 两种复制入口共用的短提示，不激活应用或占用鼠标。
public final class ClipboardToast {
    private static let shared = ClipboardToast()
    private let panel: NSPanel
    private var dismissTimer: Timer?

    private init() {
        let label = NSTextField(labelWithString: NSLocalizedString("已复制到剪贴板", comment: "clipboard feedback"))
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: 44)
        label.setFrameOrigin(NSPoint(x: 20, y: (size.height - label.frame.height) / 2))

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.addSubview(label)

        panel = NSPanel(contentRect: background.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = background
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
    }

    public static func showCopied() {
        DispatchQueue.main.async { shared.show() }
    }

    private func show() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main else { return }
        dismissTimer?.invalidate()
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 64))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: NSLocalizedString("已复制到剪贴板", comment: "clipboard feedback"),
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.panel.orderOut(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }
}
