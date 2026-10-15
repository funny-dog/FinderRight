import AppKit

/// 两种复制入口共用的短提示，不激活应用或占用鼠标。
/// 背景颜色与 App 主题色动态关联，自动适配浅色 / 深色模式。
public final class ClipboardToast {
    private static let shared = ClipboardToast()
    private let panel: NSPanel
    private let background: NSVisualEffectView
    private let tintView: NSView
    private let iconView: NSImageView
    private let label: NSTextField
    private var dismissTimer: Timer?

    private init() {
        label = NSTextField(labelWithString: NSLocalizedString("已复制到剪贴板", comment: "clipboard feedback"))
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)

        background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 160, height: 42))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        tintView = NSView(frame: background.bounds)
        tintView.wantsLayer = true
        tintView.layer?.cornerRadius = 14
        tintView.layer?.masksToBounds = true

        background.addSubview(tintView)
        background.addSubview(iconView)
        background.addSubview(label)

        panel = NSPanel(
            contentRect: background.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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

    /// 根据当前主题色与外观动态更新背景与文字颜色及尺寸
    private func updateAppearanceAndLayout() {
        SharedConfig.shared.reload()
        let theme = FRThemeID.current
        let palette = theme.palette

        let appearance = panel.effectiveAppearance
        let accent = palette.accent.resolved(for: appearance)
        let onAccent = palette.onAccent.resolved(for: appearance)

        label.stringValue = NSLocalizedString("已复制到剪贴板", comment: "clipboard feedback")
        label.textColor = onAccent
        label.sizeToFit()

        iconView.contentTintColor = onAccent

        let hasIcon = iconView.image != nil
        let leadingPadding: CGFloat = 18
        let iconSize: CGFloat = hasIcon ? 14 : 0
        let iconGap: CGFloat = hasIcon ? 8 : 0
        let trailingPadding: CGFloat = 18
        let height: CGFloat = 42

        let contentWidth = leadingPadding + iconSize + iconGap + label.frame.width + trailingPadding
        let panelSize = NSSize(width: max(contentWidth, 140), height: height)

        background.frame = NSRect(origin: .zero, size: panelSize)
        tintView.frame = NSRect(origin: .zero, size: panelSize)
        tintView.layer?.backgroundColor = accent.cgColor
        tintView.layer?.borderColor = onAccent.withAlphaComponent(0.18).cgColor
        tintView.layer?.borderWidth = 1

        if hasIcon {
            let iconY = (height - iconSize) / 2
            iconView.frame = NSRect(x: leadingPadding, y: iconY, width: iconSize, height: iconSize)
            iconView.isHidden = false
        } else {
            iconView.isHidden = true
        }

        let labelX = leadingPadding + iconSize + iconGap
        let labelY = (height - label.frame.height) / 2
        label.frame = NSRect(x: labelX, y: labelY, width: label.frame.width, height: label.frame.height)

        panel.setContentSize(panelSize)
    }

    private func show() {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main else { return }
        dismissTimer?.invalidate()

        updateAppearanceAndLayout()

        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 64))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: label.stringValue,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.panel.orderOut(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }
}
