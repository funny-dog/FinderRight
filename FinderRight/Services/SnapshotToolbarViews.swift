import AppKit
import CoreGraphics
import FinderRightKit

// MARK: - 选区右下角悬浮工具条

func configureSnapshotCapsuleStyle(on view: NSView, stack: NSStackView? = nil) {
    // 胶囊本身为深色高对比背景，固定深色外观以便主题按钮（尤其石墨主题）在任意系统外观下都清晰醒目
    view.appearance = NSAppearance(named: .darkAqua)
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 0.94).cgColor
    view.layer?.cornerRadius = 8
    view.layer?.borderWidth = 1
    view.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
    view.shadow = {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.45)
        s.shadowBlurRadius = 12
        s.shadowOffset = NSSize(width: 0, height: -4)
        return s
    }()
    if let stack {
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        view.addSubview(stack)
    }
}

final class SnapshotAnnotationBarView: NSView {
    private let onBrushToggle: () -> Void
    private let onUndo: () -> Void

    private let stack = NSStackView()
    private let brushButton: SnapshotBarButton
    private let undoButton: SnapshotBarButton

    init(onBrushToggle: @escaping () -> Void, onUndo: @escaping () -> Void) {
        self.onBrushToggle = onBrushToggle
        self.onUndo = onUndo
        self.brushButton = SnapshotBarButton(symbol: "paintbrush.pointed", title: nil, minWidth: 32, showsColorDot: true)
        self.undoButton = SnapshotBarButton(symbol: "arrow.uturn.backward", title: nil, minWidth: 28)

        super.init(frame: .zero)
        configureSnapshotCapsuleStyle(on: self, stack: stack)

        brushButton.target = self
        brushButton.action = #selector(brushClicked)
        brushButton.toolTip = NSLocalizedString("画笔", comment: "")

        undoButton.target = self
        undoButton.action = #selector(undoClicked)
        undoButton.toolTip = NSLocalizedString("撤销", comment: "")
        undoButton.isActionEnabled = false

        stack.addArrangedSubview(brushButton)
        stack.addArrangedSubview(undoButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    override var fittingSize: NSSize {
        stack.fittingSize
    }

    func setBrushActive(_ active: Bool) {
        brushButton.isSelectedState = active
    }

    func setBrushColor(_ color: ScreenshotRGBA) {
        brushButton.setColorDot(color.cgColor)
    }

    func setUndoEnabled(_ enabled: Bool) {
        undoButton.isActionEnabled = enabled
    }

    @objc private func brushClicked() { onBrushToggle() }
    @objc private func undoClicked() { onUndo() }
}

final class SnapshotToolbarView: NSView {
    private let onCopy: () -> Void
    private let onSave: () -> Void
    private let onSaveDropdown: (NSView) -> Void
    private let onCancel: () -> Void

    private let stack = NSStackView()
    private let saveDropdownButton: SnapshotBarButton

    init(onCopy: @escaping () -> Void,
         onSave: @escaping () -> Void,
         onSaveDropdown: @escaping (NSView) -> Void,
         onCancel: @escaping () -> Void) {
        self.onCopy = onCopy
        self.onSave = onSave
        self.onSaveDropdown = onSaveDropdown
        self.onCancel = onCancel
        self.saveDropdownButton = SnapshotBarButton(symbol: "chevron.down", title: nil, minWidth: 22)

        super.init(frame: .zero)
        configureSnapshotCapsuleStyle(on: self, stack: stack)

        let copyButton = SnapshotBarButton(
            symbol: "doc.on.doc",
            title: NSLocalizedString("复制", comment: ""),
            isPrimary: true
        )
        copyButton.target = self
        copyButton.action = #selector(copyClicked)

        let saveButton = SnapshotBarButton(symbol: "square.and.arrow.down", title: NSLocalizedString("保存", comment: ""))
        saveButton.target = self
        saveButton.action = #selector(saveClicked)

        saveDropdownButton.target = self
        saveDropdownButton.action = #selector(saveDropdownClicked)
        saveDropdownButton.toolTip = NSLocalizedString("保存到常用目录", comment: "")

        let cancelButton = SnapshotBarButton(symbol: "xmark", title: nil, minWidth: 28)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.toolTip = NSLocalizedString("取消", comment: "")

        let saveGroup = NSStackView(views: [saveButton, makeDivider(alpha: 0.14), saveDropdownButton])
        saveGroup.orientation = .horizontal
        saveGroup.spacing = 0
        saveGroup.alignment = .centerY

        stack.addArrangedSubview(cancelButton)
        stack.addArrangedSubview(makeDivider(alpha: 0.18))
        stack.addArrangedSubview(saveGroup)
        stack.addArrangedSubview(copyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    override var fittingSize: NSSize {
        stack.fittingSize
    }

    private func makeDivider(alpha: CGFloat) -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(alpha).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalToConstant: 16),
        ])
        return line
    }

    @objc private func copyClicked() { onCopy() }
    @objc private func saveClicked() { onSave() }
    @objc private func saveDropdownClicked() { onSaveDropdown(saveDropdownButton) }
    @objc private func cancelClicked() { onCancel() }
}

final class SnapshotColorPaletteView: NSView {
    static let presetColors: [ScreenshotRGBA] = [
        ScreenshotRGBA(red: 1.0, green: 0.231, blue: 0.188),
        ScreenshotRGBA(red: 1.0, green: 0.8, blue: 0.0),
        ScreenshotRGBA(red: 0.204, green: 0.78, blue: 0.349),
        ScreenshotRGBA(red: 0.0, green: 0.478, blue: 1.0),
        ScreenshotRGBA(red: 1.0, green: 1.0, blue: 1.0),
        ScreenshotRGBA(red: 0.11, green: 0.11, blue: 0.118),
    ]

    private let onSelectColor: (ScreenshotRGBA) -> Void
    private let stack = NSStackView()
    private var swatchButtons: [SnapshotSwatchButton] = []

    init(initialColor: ScreenshotRGBA, onSelectColor: @escaping (ScreenshotRGBA) -> Void) {
        self.onSelectColor = onSelectColor
        super.init(frame: .zero)
        configureSnapshotCapsuleStyle(on: self, stack: stack)

        for (index, color) in Self.presetColors.enumerated() {
            let button = SnapshotSwatchButton(color: color, tagIndex: index)
            button.target = self
            button.action = #selector(swatchClicked(_:))
            swatchButtons.append(button)
            stack.addArrangedSubview(button)
        }
        setSelectedColor(initialColor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        stack.frame = bounds
    }

    override var fittingSize: NSSize {
        stack.fittingSize
    }

    func setSelectedColor(_ color: ScreenshotRGBA) {
        for button in swatchButtons {
            button.isSelectedSwatch = (button.swatchColor == color)
        }
    }

    @objc private func swatchClicked(_ sender: SnapshotSwatchButton) {
        onSelectColor(sender.swatchColor)
    }
}

final class SnapshotSwatchButton: NSButton {
    let swatchColor: ScreenshotRGBA
    private let dotLayer = CALayer()
    var isSelectedSwatch = false {
        didSet { updateAppearance() }
    }

    init(color: ScreenshotRGBA, tagIndex: Int) {
        self.swatchColor = color
        super.init(frame: .zero)
        tag = tagIndex
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 11

        dotLayer.backgroundColor = color.cgColor
        dotLayer.cornerRadius = 6.5
        dotLayer.borderWidth = 1
        dotLayer.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        layer?.addSublayer(dotLayer)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        dotLayer.frame = NSRect(x: (bounds.width - 13) / 2, y: (bounds.height - 13) / 2, width: 13, height: 13)
    }

    private func updateAppearance() {
        layer?.backgroundColor = isSelectedSwatch
            ? NSColor.white.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        dotLayer.borderWidth = isSelectedSwatch ? 1.5 : 1
        dotLayer.borderColor = NSColor.white.withAlphaComponent(isSelectedSwatch ? 0.95 : 0.35).cgColor
    }
}

final class SnapshotBarButton: NSButton {
    private let isPrimary: Bool
    private var isHovered = false
    private var trackingAreaRef: NSTrackingArea?
    private var colorDotLayer: CALayer?

    var isSelectedState = false {
        didSet { updateBackground() }
    }

    var isActionEnabled = true {
        didSet {
            isEnabled = isActionEnabled
            if !isActionEnabled { isHovered = false }
            alphaValue = isActionEnabled ? 1.0 : 0.35
            updateBackground()
        }
    }

    init(symbol: String,
         title: String?,
         minWidth: CGFloat? = nil,
         isPrimary: Bool = false,
         showsColorDot: Bool = false) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = 5

        let foregroundColor: NSColor
        if isPrimary {
            SharedConfig.shared.reload()
            let darkAppearance = NSAppearance(named: .darkAqua)
            foregroundColor = FRThemeID.current.palette.onAccent.resolved(for: darkAppearance)
        } else {
            foregroundColor = .white
        }
        let textWeight: NSFont.Weight = isPrimary ? .semibold : .medium
        contentTintColor = foregroundColor
        font = .systemFont(ofSize: 12, weight: textWeight)

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: title == nil ? 11 : 12, weight: textWeight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [foregroundColor]))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(symbolConfig)

        if let title {
            self.title = title
            imagePosition = .imageLeading
            imageHugsTitle = true
            attributedTitle = NSAttributedString(
                string: " " + title,
                attributes: [
                    .foregroundColor: foregroundColor,
                    .font: NSFont.systemFont(ofSize: 12, weight: textWeight),
                ]
            )
        } else {
            self.title = ""
            imagePosition = .imageOnly
        }

        if showsColorDot {
            let dot = CALayer()
            dot.cornerRadius = 3.5
            dot.borderWidth = 1
            dot.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
            dot.backgroundColor = SnapshotColorPaletteView.presetColors[0].cgColor
            layer?.addSublayer(dot)
            colorDotLayer = dot
        }

        updateBackground()

        translatesAutoresizingMaskIntoConstraints = false
        let width = minWidth ?? (intrinsicContentSize.width + 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(greaterThanOrEqualToConstant: width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        colorDotLayer?.frame = NSRect(x: bounds.width - 10, y: 3, width: 7, height: 7)
    }

    func setColorDot(_ cgColor: CGColor) {
        colorDotLayer?.backgroundColor = cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard isActionEnabled else { return }
        isHovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateBackground()
    }

    private func updateBackground() {
        if isPrimary {
            let darkAppearance = NSAppearance(named: .darkAqua)
            let accent = FRThemeID.current.palette.accent.resolved(for: darkAppearance)
            layer?.backgroundColor = (isHovered ? accent.withAlphaComponent(0.85) : accent).cgColor
        } else if isSelectedState {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.24).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        } else {
            layer?.borderWidth = 0
            layer?.backgroundColor = (isActionEnabled && isHovered)
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
        }
    }
}
