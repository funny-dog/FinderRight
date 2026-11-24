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

    static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    static func copyImageToPasteboard(_ cgImage: CGImage) -> Bool {
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

    static func presentSavePanel(for cgImage: CGImage) {
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
