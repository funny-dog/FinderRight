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

    /// 撤销结果的提示样式：全部撤销 / 部分撤销 / 一项未撤销
    public enum Style {
        case success, partial, failure
    }

    /// 内部外观：复制提示跟随主题色，警告为橙色，撤销结果按 Style 用绿 / 黄 / 红
    private enum Look {
        case copied, warning, result(Style)
    }

    public static func showCopied(message: String? = nil, isWarning: Bool = false) {
        DispatchQueue.main.async { shared.show(message: message, look: isWarning ? .warning : .copied) }
    }

    /// 撤销结果提示：文字较长，停留时间比复制提示更久
    public static func show(message: String, style: Style) {
        DispatchQueue.main.async { shared.show(message: message, look: .result(style)) }
    }

    /// 根据当前主题色与外观动态更新背景与文字颜色及尺寸
    private func updateAppearanceAndLayout(message: String?, look: Look) {
        SharedConfig.shared.reload()
        let theme = FRThemeID.current
        let palette = theme.palette

        let appearance = panel.effectiveAppearance
        let accent: NSColor, onAccent: NSColor, iconSymbol: String
        switch look {
        case .copied:
            accent = palette.accent.resolved(for: appearance)
            onAccent = palette.onAccent.resolved(for: appearance)
            iconSymbol = "checkmark"
        case .warning:
            accent = .systemOrange
            onAccent = .white
            iconSymbol = "exclamationmark.triangle"
        case .result(.success):
            accent = .systemGreen
            onAccent = .white
            iconSymbol = "checkmark"
        case .result(.partial):
            // 黄底白字看不清，改用深色文字
            accent = .systemYellow
            onAccent = .black
            iconSymbol = "exclamationmark.triangle"
        case .result(.failure):
            accent = .systemRed
            onAccent = .white
            iconSymbol = "xmark"
        }
        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)

        label.stringValue = message ?? NSLocalizedString("已复制到剪贴板", comment: "clipboard feedback")
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

    private func show(message: String?, look: Look) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
                ?? NSScreen.main else { return }
        dismissTimer?.invalidate()

        updateAppearanceAndLayout(message: message, look: look)

        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 64))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: label.stringValue,
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
        let duration: TimeInterval
        if case .result = look { duration = 3 } else { duration = 1.2 }
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            self?.panel.orderOut(nil)
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }
}
