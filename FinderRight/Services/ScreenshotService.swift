import AppKit
import Carbon
import Combine
import FinderRightKit

/// 轻量截图服务：默认关闭，开启后支持唤起系统原生截图面板（⌘⇧5）或 FinderRight 瞬时快照截图。
final class ScreenshotService: ObservableObject {
    static let shared = ScreenshotService()

    private static let screenshotBundleId = "com.apple.screenshot.launcher"
    private static let fallbackScreenshotAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")

    @Published private(set) var isEnabled: Bool
    @Published private(set) var mode: ScreenshotMode
    @Published private(set) var hasScreenCaptureAccess: Bool
    @Published private(set) var isRegistered = false
    @Published private(set) var errorMessage: String?

    private let config: SharedConfig
    private lazy var hotKey: GlobalActionHotKey = GlobalActionHotKey(
        hotKeyID: EventHotKeyID(signature: 0x46525353, id: 3), // FRSS
        actionId: FinderKeyTakeover.screenshotActionId,
        config: config,
        isFeatureEnabled: { $0.screenshotEnabled },
        allowsNativeSystemShortcut: { [weak self] shortcut in
            (self?.config.screenshotMode ?? .system) == .system
                && FinderKeyTakeover.isDefaultScreenshotShortcut(shortcut)
        },
        systemConflictMessage: { [weak self] shortcut in
            guard self?.config.screenshotMode == .snapshot,
                  FinderKeyTakeover.isDefaultScreenshotShortcut(shortcut) else { return nil }
            return NSLocalizedString("⇧⌘5 已被系统截屏占用，请换一个组合或在系统设置中关闭系统截屏快捷键", comment: "")
        },
        onStateChange: { [weak self] registered, error in
            self?.isRegistered = registered
            self?.errorMessage = error
        }
    )

    init(config: SharedConfig = .shared) {
        self.config = config
        self.isEnabled = config.screenshotEnabled
        self.mode = config.screenshotMode
        self.hasScreenCaptureAccess = SnapshotCaptureController.hasScreenCaptureAccess()
    }

    func start() {
        config.reload()
        isEnabled = config.screenshotEnabled
        mode = config.screenshotMode
        hasScreenCaptureAccess = SnapshotCaptureController.hasScreenCaptureAccess()
        hotKey.start { [weak self] in
            self?.trigger()
        }
    }

    func setEnabled(_ enabled: Bool) {
        config.screenshotEnabled = enabled
        refresh()
    }

    func setMode(_ newMode: ScreenshotMode) {
        config.screenshotMode = newMode
        refresh()
    }

    func refreshPermission() {
        hasScreenCaptureAccess = SnapshotCaptureController.hasScreenCaptureAccess()
    }

    func requestScreenCapturePermission() {
        SnapshotCaptureController.requestScreenCaptureAccess()
        refreshPermission()
    }

    func setRecording(_ recording: Bool) {
        hotKey.setRecording(recording)
    }

    func refresh() {
        config.reload()
        isEnabled = config.screenshotEnabled
        mode = config.screenshotMode
        hasScreenCaptureAccess = SnapshotCaptureController.hasScreenCaptureAccess()
        hotKey.refresh()
    }

    func trigger(fromMenu: Bool = false) {
        let perform = {
            self.refresh()
            guard self.isEnabled else { return }
            switch self.mode {
            case .system:
                self.triggerSystemScreenshot()
            case .snapshot:
                guard SnapshotCaptureController.hasScreenCaptureAccess() else {
                    self.hasScreenCaptureAccess = false
                    SnapshotCaptureController.requestScreenCaptureAccess()
                    ClipboardToast.showCopied(
                        message: NSLocalizedString("请先在系统设置中授权「屏幕录制」权限", comment: "notification"),
                        isWarning: true
                    )
                    return
                }
                SnapshotCaptureController.shared.beginCapture()
            }
        }
        if fromMenu && mode == .snapshot {
            // 菜单点击后等待系统状态栏菜单淡出再抓图，避免把菜单本身截进画面
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: perform)
        } else {
            DispatchQueue.main.async(execute: perform)
        }
    }

    private func triggerSystemScreenshot() {
        guard let appURL = Self.resolveScreenshotAppURL() else {
            NSSound.beep()
            ClipboardToast.showCopied(message: NSLocalizedString("无法打开系统截图", comment: "notification"), isWarning: true)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            guard let error else { return }
            NSLog("[ScreenshotService] 唤起系统截图失败: \(error.localizedDescription)")
            DispatchQueue.main.async {
                NSSound.beep()
                ClipboardToast.showCopied(message: NSLocalizedString("无法打开系统截图", comment: "notification"), isWarning: true)
            }
        }
    }

    private static func resolveScreenshotAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: screenshotBundleId) {
            return url
        }
        return FileManager.default.fileExists(atPath: fallbackScreenshotAppURL.path) ? fallbackScreenshotAppURL : nil
    }
}
