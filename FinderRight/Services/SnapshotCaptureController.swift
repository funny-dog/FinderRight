import AppKit
import CoreGraphics
import FinderRightKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 轻量快照截图控制器：按下快捷键时瞬时定格当前屏幕，支持框选、复制及保存到常用目录。
/// 未激活时零窗口驻留、零图像缓存。
final class SnapshotCaptureController {
    static let shared = SnapshotCaptureController()

    private var overlayWindow: SnapshotOverlayWindow?
    private var previousApplication: NSRunningApplication?
    private var isCapturing = false

    private init() {}

    static func hasScreenCaptureAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCaptureAccess() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func beginCapture() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isCapturing, self.overlayWindow == nil else { return }
            guard let screen = Self.targetScreen() else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication
            let currentPID = ProcessInfo.processInfo.processIdentifier
            self.previousApplication = (frontmost?.processIdentifier != currentPID) ? frontmost : nil
            self.isCapturing = true
            Self.captureScreenImage(for: screen) { [weak self] image in
                guard let self else { return }
                self.isCapturing = false
                guard let image else {
                    self.previousApplication = nil
                    NSSound.beep()
                    ClipboardToast.showCopied(message: NSLocalizedString("无法抓取当前屏幕", comment: "notification"), isWarning: true)
                    return
                }
                self.presentOverlay(on: screen, image: image)
            }
        }
    }

    func dismiss(restorePreviousApp: Bool = true) {
        let performDismiss = {
            self.isCapturing = false
            let previousApp = self.previousApplication
            self.previousApplication = nil
            guard let window = self.overlayWindow else { return }
            self.overlayWindow = nil
            window.tearDown()
            NSCursor.arrow.set()
            if restorePreviousApp, let previousApp, !previousApp.isTerminated {
                previousApp.activate(options: [])
            }
        }
        if Thread.isMainThread {
            performDismiss()
        } else {
            DispatchQueue.main.async(execute: performDismiss)
        }
    }

    private func presentOverlay(on screen: NSScreen, image: CGImage) {
        let window = SnapshotOverlayWindow(
            screen: screen,
            image: image,
            onDismiss: { [weak self] restorePreviousApp in
                self?.dismiss(restorePreviousApp: restorePreviousApp)
            }
        )
        overlayWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        if let contentView = window.contentView {
            window.makeFirstResponder(contentView)
            window.invalidateCursorRects(for: contentView)
        }
        NSCursor.crosshair.set()
        // 首次从状态栏菜单或后台 accessory 切入时，系统菜单收尾会延迟交接焦点，下一轮 RunLoop 再补一次激活与准星
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.overlayWindow === window else { return }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if let contentView = window.contentView {
                window.makeFirstResponder(contentView)
                window.invalidateCursorRects(for: contentView)
            }
            NSCursor.crosshair.set()
        }
    }

    private static func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
    }

    private static func captureScreenImage(for screen: NSScreen, completion: @escaping (CGImage?) -> Void) {
        if #available(macOS 14.0, *),
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            let targetWidth = max(1, Int(round(screen.frame.width * screen.backingScaleFactor)))
            let targetHeight = max(1, Int(round(screen.frame.height * screen.backingScaleFactor)))
            Task {
                do {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                        await MainActor.run { completion(nil) }
                        return
                    }
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let config = SCStreamConfiguration()
                    config.width = targetWidth
                    config.height = targetHeight
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    await MainActor.run { completion(image) }
                } catch {
                    NSLog("[SnapshotCaptureController] ScreenCaptureKit 抓图失败: \(error.localizedDescription)")
                    await MainActor.run { completion(nil) }
                }
            }
            return
        }

        // macOS 13 兜底：通过系统 screencapture 静默抓取当前屏幕区域到临时文件后立即删除
        let screenFrame = screen.frame
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        let rectArg = "\(Int(screenFrame.minX)),\(Int(primaryMaxY - screenFrame.maxY)),\(Int(screenFrame.width)),\(Int(screenFrame.height))"
        DispatchQueue.global(qos: .userInitiated).async {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("fr-snapshot-\(UUID().uuidString).png")
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R", rectArg, tempURL.path]
            do {
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let source = CGImageSourceCreateWithURL(tempURL as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    DispatchQueue.main.async { completion(nil) }
                    return
                }
                DispatchQueue.main.async { completion(image) }
            } catch {
                NSLog("[SnapshotCaptureController] macOS 13 抓图兜底失败: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    fileprivate static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    fileprivate static func copyImageToPasteboard(_ cgImage: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        if let tiffData = rep.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }
        return pasteboard.writeObjects([item])
    }

    fileprivate static func presentSavePanel(for cgImage: CGImage) {
        guard let pngData = pngData(from: cgImage) else {
            NSSound.beep()
            ClipboardToast.showCopied(message: NSLocalizedString("保存截图失败", comment: "notification"), isWarning: true)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(ScreenshotSnapshotGeometry.defaultBaseName()).png"
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            try pngData.write(to: url, options: .atomic)
            ClipboardToast.showCopied(message: NSLocalizedString("已保存截图", comment: "notification"))
        } catch {
            NSLog("[SnapshotCaptureController] 保存截图失败: \(error.localizedDescription)")
            NSSound.beep()
            ClipboardToast.showCopied(message: NSLocalizedString("保存截图失败", comment: "notification"), isWarning: true)
        }
    }
}

// MARK: - 全屏定格窗口

private final class SnapshotOverlayWindow: NSWindow {
    private var overlayView: SnapshotOverlayView?

    init(screen: NSScreen, image: CGImage, onDismiss: @escaping (_ restorePreviousApp: Bool) -> Void) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        // 高于菜单栏与状态栏（24/25）以全屏定格，同时低于 NSMenu（101）避免遮挡常用目录下拉框
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        acceptsMouseMovedEvents = true

        let view = SnapshotOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image, onDismiss: onDismiss)
        contentView = view
        overlayView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func tearDown() {
        overlayView?.clearResources()
        overlayView = nil
        contentView = nil
        orderOut(nil)
    }
}

// MARK: - 选区画布与工具条

private final class SnapshotOverlayView: NSView {
    private enum DragMode {
        case none
        case create(origin: NSPoint)
        case move(startMouse: NSPoint, startRect: NSRect)
        case resize(handle: ResizeHandle, oppositeCorner: NSPoint, originalRect: NSRect)
        case draw
    }

    private enum ResizeHandle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var cursor: NSCursor {
            switch self {
            case .left, .right: return .resizeLeftRight
            case .top, .bottom: return .resizeUpDown
            default: return .crosshair
            }
        }
    }

    private var image: CGImage?
    private let onDismiss: (_ restorePreviousApp: Bool) -> Void
    private var selectionRect: NSRect?
    private var dragMode: DragMode = .none
    private var toolbar: SnapshotToolbarView?
    private var annotationBar: SnapshotAnnotationBarView?
    private var colorPalette: SnapshotColorPaletteView?
    private var trackingAreaRef: NSTrackingArea?
    private var strokes: [ScreenshotBrushStroke] = []
    private var isBrushActive = false
    private var selectedBrushColor: ScreenshotRGBA = SnapshotColorPaletteView.presetColors[0]

    private static let brushLineWidth: CGFloat = 3.5
    private static let handleHitRadius: CGFloat = 7
    private static let handleDrawSize: CGFloat = 6

    init(frame: NSRect, image: CGImage, onDismiss: @escaping (_ restorePreviousApp: Bool) -> Void) {
        self.image = image
        self.onDismiss = onDismiss
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clearResources() {
        toolbar?.removeFromSuperview()
        toolbar = nil
        annotationBar?.removeFromSuperview()
        annotationBar = nil
        colorPalette?.removeFromSuperview()
        colorPalette = nil
        strokes.removeAll()
        image = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(at: convert(event.locationInWindow, from: nil))
    }

    private func updateCursor(at point: NSPoint) {
        if let rect = selectionRect, toolbar?.isHidden == false {
            if isBrushActive {
                if rect.contains(point) {
                    NSCursor.crosshair.set()
                    return
                }
                if let handle = hitHandle(at: point, in: rect) {
                    handle.cursor.set()
                    return
                }
            } else {
                if let handle = hitHandle(at: point, in: rect) {
                    handle.cursor.set()
                    return
                }
                if rect.contains(point) {
                    NSCursor.openHand.set()
                    return
                }
            }
        }
        NSCursor.crosshair.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        ctx.draw(image, in: bounds)

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        if let rect = selectionRect, rect.width >= 1, rect.height >= 1 {
            // 选区外遮罩（even-odd 挖空选区）
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(rect)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        guard let rect = selectionRect, rect.width >= 1, rect.height >= 1 else { return }

        if !strokes.isEmpty {
            ctx.saveGState()
            ctx.clip(to: rect)
            ScreenshotSnapshotGeometry.drawStrokes(strokes, in: ctx)
            ctx.restoreGState()
        }

        // 选区描边
        let accent = FRThemeID.current.palette.accent.resolved(for: effectiveAppearance)
        ctx.saveGState()
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(accent.cgColor)
        ctx.stroke(rect.insetBy(dx: 0.75, dy: 0.75))
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.stroke(rect.insetBy(dx: 1.5, dy: 1.5))

        // 拖拽完成后绘制 8 个调整手柄
        if case .none = dragMode {
            let s = Self.handleDrawSize
            for handle in ResizeHandle.allCases {
                let pt = handlePoint(for: handle, in: rect)
                let box = NSRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fill(box)
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(box)
            }
        }
        ctx.restoreGState()

        drawSizeBadge(for: rect, image: image)
    }

    private func drawSizeBadge(for rect: NSRect, image: CGImage) {
        let pixelRect = ScreenshotSnapshotGeometry.pixelCropRect(
            selectionInView: rect,
            viewSize: bounds.size,
            imageWidth: image.width,
            imageHeight: image.height
        )
        let w = Int(pixelRect?.width ?? round(rect.width * (window?.backingScaleFactor ?? 2)))
        let h = Int(pixelRect?.height ?? round(rect.height * (window?.backingScaleFactor ?? 2)))
        let text = "\(w) × \(h)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attrs)
        let badgeSize = NSSize(width: textSize.width + 14, height: 22)
        let badgeY: CGFloat = (rect.maxY + 6 + badgeSize.height <= bounds.maxY)
            ? rect.maxY + 6
            : max(bounds.minY + 6, rect.maxY - badgeSize.height - 6)
        let badgeX = min(max(bounds.minX + 6, rect.minX), bounds.maxX - badgeSize.width - 6)
        let badgeRect = NSRect(origin: NSPoint(x: badgeX, y: badgeY), size: badgeSize)

        let bgPath = NSBezierPath(roundedRect: badgeRect, xRadius: 5, yRadius: 5)
        NSColor(calibratedWhite: 0.1, alpha: 0.82).setFill()
        bgPath.fill()

        let textPoint = NSPoint(
            x: badgeRect.minX + (badgeSize.width - textSize.width) / 2,
            y: badgeRect.minY + (badgeSize.height - textSize.height) / 2
        )
        text.draw(at: textPoint, withAttributes: attrs)
    }

    // MARK: 鼠标事件

    override func mouseDown(with event: NSEvent) {
        let point = clampedToBounds(convert(event.locationInWindow, from: nil))

        if let rect = selectionRect {
            if isBrushActive {
                if rect.contains(point) {
                    hideToolbar()
                    dragMode = .draw
                    strokes.append(
                        ScreenshotBrushStroke(
                            points: [point],
                            color: selectedBrushColor,
                            lineWidth: Self.brushLineWidth
                        )
                    )
                    needsDisplay = true
                    return
                }
                if let handle = hitHandle(at: point, in: rect) {
                    hideToolbar()
                    let opposite = oppositeAnchor(for: handle, in: rect)
                    dragMode = .resize(handle: handle, oppositeCorner: opposite, originalRect: rect)
                    needsDisplay = true
                    return
                }
                return
            }

            hideToolbar()
            if let handle = hitHandle(at: point, in: rect) {
                let opposite = oppositeAnchor(for: handle, in: rect)
                dragMode = .resize(handle: handle, oppositeCorner: opposite, originalRect: rect)
                needsDisplay = true
                return
            }
            if rect.contains(point) {
                dragMode = .move(startMouse: point, startRect: rect)
                NSCursor.closedHand.set()
                needsDisplay = true
                return
            }
        } else {
            hideToolbar()
        }

        strokes.removeAll()
        dragMode = .create(origin: point)
        selectionRect = NSRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clampedToBounds(convert(event.locationInWindow, from: nil))
        switch dragMode {
        case .create(let origin):
            selectionRect = NSRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(point.x - origin.x),
                height: abs(point.y - origin.y)
            )
        case .move(let startMouse, let startRect):
            let dx = point.x - startMouse.x
            let dy = point.y - startMouse.y
            let clampedX = min(max(bounds.minX, startRect.minX + dx), bounds.maxX - startRect.width)
            let clampedY = min(max(bounds.minY, startRect.minY + dy), bounds.maxY - startRect.height)
            selectionRect = NSRect(x: clampedX, y: clampedY, width: startRect.width, height: startRect.height)
        case .resize(let handle, let opposite, let original):
            selectionRect = resizedRect(handle: handle, point: point, opposite: opposite, original: original)
        case .draw:
            if let lastIndex = strokes.indices.last {
                if let prev = strokes[lastIndex].points.last,
                   hypot(point.x - prev.x, point.y - prev.y) < 0.5 {
                    break
                }
                strokes[lastIndex].points.append(point)
            }
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let finished = dragMode
        dragMode = .none
        guard case .none = finished else {
            if let rect = selectionRect, rect.width >= 4, rect.height >= 4 {
                showToolbar(below: rect)
            } else {
                selectionRect = nil
                strokes.removeAll()
                hideToolbar()
            }
            needsDisplay = true
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if selectionRect != nil {
            selectionRect = nil
            dragMode = .none
            strokes.removeAll()
            isBrushActive = false
            annotationBar?.setBrushActive(false)
            annotationBar?.setUndoEnabled(false)
            hideToolbar()
            needsDisplay = true
        } else {
            onDismiss(true)
        }
    }

    // MARK: 键盘事件

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onDismiss(true)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            if selectionRect != nil { performCopy() }
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            if key == "c", selectionRect != nil {
                performCopy()
                return true
            }
            if key == "s", selectionRect != nil {
                performSaveWithPanel()
                return true
            }
            if key == "z", !strokes.isEmpty {
                performUndo()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: 动作执行

    private func cropSelectedCGImage() -> CGImage? {
        guard let image,
              let rect = selectionRect,
              let cropRect = ScreenshotSnapshotGeometry.pixelCropRect(
                selectionInView: rect,
                viewSize: bounds.size,
                imageWidth: image.width,
                imageHeight: image.height
              ),
              let cropped = image.cropping(to: cropRect) else { return nil }
        return ScreenshotSnapshotGeometry.renderCroppedImage(
            cropped,
            strokes: strokes,
            viewSize: bounds.size,
            imageWidth: image.width,
            imageHeight: image.height,
            cropRect: cropRect
        )
    }

    private func performCopy() {
        guard let cropped = cropSelectedCGImage() else {
            NSSound.beep()
            return
        }
        let ok = SnapshotCaptureController.copyImageToPasteboard(cropped)
        onDismiss(true)
        if ok {
            ClipboardToast.showCopied(message: NSLocalizedString("已复制截图到剪贴板", comment: "notification"))
        } else {
            NSSound.beep()
            ClipboardToast.showCopied(message: NSLocalizedString("无法写入剪贴板", comment: "notification"), isWarning: true)
        }
    }

    private func performSaveWithPanel() {
        guard let cropped = cropSelectedCGImage() else {
            NSSound.beep()
            return
        }
        onDismiss(false)
        DispatchQueue.main.async {
            SnapshotCaptureController.presentSavePanel(for: cropped)
        }
    }

    private func performQuickSave(to directoryPath: String, displayName: String, isFavorite: Bool) {
        guard let cropped = cropSelectedCGImage(),
              let pngData = SnapshotCaptureController.pngData(from: cropped) else {
            onDismiss(true)
            NSSound.beep()
            ClipboardToast.showCopied(message: NSLocalizedString("保存截图失败", comment: "notification"), isWarning: true)
            return
        }
        let dirURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        let destURL = UniqueName.fileURL(
            baseName: ScreenshotSnapshotGeometry.defaultBaseName(),
            ext: "png",
            in: dirURL
        )
        do {
            try pngData.write(to: destURL, options: .atomic)
            if isFavorite {
                SharedConfig.shared.markFavoriteUsed(directoryPath)
            }
            onDismiss(true)
            ClipboardToast.showCopied(
                message: String(format: NSLocalizedString("已保存到「%@」", comment: "notification"), displayName)
            )
        } catch {
            NSLog("[SnapshotCaptureController] 快速保存到常用目录失败: \(error.localizedDescription)")
            onDismiss(true)
            NSSound.beep()
            ClipboardToast.showCopied(message: NSLocalizedString("保存截图失败", comment: "notification"), isWarning: true)
        }
    }

    private func toggleBrush() {
        isBrushActive.toggle()
        annotationBar?.setBrushActive(isBrushActive)
        if let rect = selectionRect {
            showToolbar(below: rect)
        }
        if let window {
            updateCursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    private func performUndo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        annotationBar?.setUndoEnabled(!strokes.isEmpty)
        needsDisplay = true
    }

    private func selectBrushColor(_ color: ScreenshotRGBA) {
        selectedBrushColor = color
        annotationBar?.setBrushColor(color)
        colorPalette?.setSelectedColor(color)
    }

    // MARK: 悬浮工具条定位与菜单

    private func showToolbar(below rect: NSRect) {
        let bar: SnapshotToolbarView
        if let existing = toolbar {
            bar = existing
        } else {
            let created = SnapshotToolbarView(
                onCopy: { [weak self] in self?.performCopy() },
                onSave: { [weak self] in self?.performSaveWithPanel() },
                onSaveDropdown: { [weak self] anchor in self?.showFavoriteSaveMenu(anchoredTo: anchor) },
                onCancel: { [weak self] in self?.onDismiss(true) }
            )
            addSubview(created)
            toolbar = created
            bar = created
        }

        let leftBar: SnapshotAnnotationBarView
        if let existing = annotationBar {
            leftBar = existing
        } else {
            let created = SnapshotAnnotationBarView(
                onBrushToggle: { [weak self] in self?.toggleBrush() },
                onUndo: { [weak self] in self?.performUndo() }
            )
            addSubview(created)
            annotationBar = created
            leftBar = created
        }

        leftBar.setBrushActive(isBrushActive)
        leftBar.setBrushColor(selectedBrushColor)
        leftBar.setUndoEnabled(!strokes.isEmpty)

        let rightSize = bar.fittingSize
        let leftSize = leftBar.fittingSize
        let margin: CGFloat = 8
        let barGap: CGFloat = 12
        let barHeight = max(rightSize.height, leftSize.height)
        let y: CGFloat
        if rect.minY - margin - barHeight >= bounds.minY + margin {
            y = rect.minY - margin - barHeight
        } else if rect.maxY + margin + barHeight <= bounds.maxY - margin {
            y = rect.maxY + margin
        } else {
            y = max(bounds.minY + margin, rect.minY + 12)
        }

        let maxRightX = max(bounds.minX + margin, bounds.maxX - rightSize.width - margin)
        let minRightXForLeft = min(maxRightX, bounds.minX + margin + leftSize.width + barGap)
        let rightX = min(max(minRightXForLeft, rect.maxX - rightSize.width), maxRightX)
        let leftX = max(bounds.minX + margin, min(rect.minX, rightX - barGap - leftSize.width))

        bar.frame = NSRect(origin: NSPoint(x: rightX, y: y), size: rightSize)
        bar.isHidden = false
        leftBar.frame = NSRect(origin: NSPoint(x: leftX, y: y), size: leftSize)
        leftBar.isHidden = false

        if isBrushActive {
            let palette: SnapshotColorPaletteView
            if let existing = colorPalette {
                palette = existing
            } else {
                let created = SnapshotColorPaletteView(
                    initialColor: selectedBrushColor,
                    onSelectColor: { [weak self] color in self?.selectBrushColor(color) }
                )
                addSubview(created)
                colorPalette = created
                palette = created
            }
            palette.setSelectedColor(selectedBrushColor)
            let paletteSize = palette.fittingSize
            let px = min(max(bounds.minX + margin, leftBar.frame.minX), bounds.maxX - paletteSize.width - margin)
            let gap: CGFloat = 6
            let py: CGFloat = (leftBar.frame.minY - gap - paletteSize.height >= bounds.minY + margin)
                ? leftBar.frame.minY - gap - paletteSize.height
                : min(bounds.maxY - paletteSize.height - margin, leftBar.frame.maxY + gap)
            palette.frame = NSRect(origin: NSPoint(x: px, y: py), size: paletteSize)
            palette.isHidden = false
        } else {
            colorPalette?.isHidden = true
        }
    }

    private func hideToolbar() {
        toolbar?.isHidden = true
        annotationBar?.isHidden = true
        colorPalette?.isHidden = true
    }

    private func showFavoriteSaveMenu(anchoredTo button: NSView) {
        SharedConfig.shared.reload()
        let ordered = SharedConfig.shared.orderedFavoriteDirectories
        let fileManager = FileManager.default
        let validFavorites = ordered.filter { path in
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }
        let homeURL = IPCBridge.realUserHomeDirectory
        let displayNames = FavoriteDirectories.displayNames(for: validFavorites, home: homeURL.path)

        let menu = NSMenu()
        let folderIcon = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)

        for (path, displayName) in zip(validFavorites, displayNames) {
            let item = NSMenuItem(title: displayName, action: #selector(handleQuickSaveMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.image = folderIcon
            item.representedObject = QuickSaveTarget(path: path, displayName: displayName, isFavorite: true)
            menu.addItem(item)
        }

        let desktopPath = homeURL.appendingPathComponent("Desktop").path
        var desktopIsDir: ObjCBool = false
        if !validFavorites.contains(desktopPath),
           fileManager.fileExists(atPath: desktopPath, isDirectory: &desktopIsDir),
           desktopIsDir.boolValue {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let desktopTitle = NSLocalizedString("桌面", comment: "")
            let desktopItem = NSMenuItem(title: desktopTitle, action: #selector(handleQuickSaveMenuItem(_:)), keyEquivalent: "")
            desktopItem.target = self
            desktopItem.image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil) ?? folderIcon
            desktopItem.representedObject = QuickSaveTarget(path: desktopPath, displayName: desktopTitle, isFavorite: false)
            menu.addItem(desktopItem)
        }

        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let otherItem = NSMenuItem(
            title: NSLocalizedString("保存到其他位置…", comment: ""),
            action: #selector(handleSaveOtherMenuItem),
            keyEquivalent: ""
        )
        otherItem.target = self
        otherItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(otherItem)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: button)
    }

    @objc private func handleQuickSaveMenuItem(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? QuickSaveTarget else { return }
        performQuickSave(to: target.path, displayName: target.displayName, isFavorite: target.isFavorite)
    }

    @objc private func handleSaveOtherMenuItem() {
        performSaveWithPanel()
    }

    // MARK: 几何辅助

    private func clampedToBounds(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(bounds.minX, point.x), bounds.maxX),
            y: min(max(bounds.minY, point.y), bounds.maxY)
        )
    }

    private func handlePoint(for handle: ResizeHandle, in rect: NSRect) -> NSPoint {
        switch handle {
        case .topLeft:     return NSPoint(x: rect.minX, y: rect.maxY)
        case .top:         return NSPoint(x: rect.midX, y: rect.maxY)
        case .topRight:    return NSPoint(x: rect.maxX, y: rect.maxY)
        case .right:       return NSPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return NSPoint(x: rect.maxX, y: rect.minY)
        case .bottom:      return NSPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft:  return NSPoint(x: rect.minX, y: rect.minY)
        case .left:        return NSPoint(x: rect.minX, y: rect.midY)
        }
    }

    private func hitHandle(at point: NSPoint, in rect: NSRect) -> ResizeHandle? {
        ResizeHandle.allCases.first { handle in
            let pt = handlePoint(for: handle, in: rect)
            return hypot(point.x - pt.x, point.y - pt.y) <= Self.handleHitRadius
        }
    }

    private func oppositeAnchor(for handle: ResizeHandle, in rect: NSRect) -> NSPoint {
        switch handle {
        case .topLeft:     return NSPoint(x: rect.maxX, y: rect.minY)
        case .top:         return NSPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return NSPoint(x: rect.minX, y: rect.minY)
        case .right:       return NSPoint(x: rect.minX, y: rect.midY)
        case .bottomRight: return NSPoint(x: rect.minX, y: rect.maxY)
        case .bottom:      return NSPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:  return NSPoint(x: rect.maxX, y: rect.maxY)
        case .left:        return NSPoint(x: rect.maxX, y: rect.midY)
        }
    }

    private func resizedRect(handle: ResizeHandle, point: NSPoint, opposite: NSPoint, original: NSRect) -> NSRect {
        switch handle {
        case .topLeft, .topRight, .bottomRight, .bottomLeft:
            return NSRect(
                x: min(opposite.x, point.x),
                y: min(opposite.y, point.y),
                width: abs(point.x - opposite.x),
                height: abs(point.y - opposite.y)
            )
        case .left, .right:
            return NSRect(
                x: min(opposite.x, point.x),
                y: original.minY,
                width: abs(point.x - opposite.x),
                height: original.height
            )
        case .top, .bottom:
            return NSRect(
                x: original.minX,
                y: min(opposite.y, point.y),
                width: original.width,
                height: abs(point.y - opposite.y)
            )
        }
    }
}

private final class QuickSaveTarget {
    let path: String
    let displayName: String
    let isFavorite: Bool

    init(path: String, displayName: String, isFavorite: Bool) {
        self.path = path
        self.displayName = displayName
        self.isFavorite = isFavorite
    }
}
