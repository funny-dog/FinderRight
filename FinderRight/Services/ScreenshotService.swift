import AppKit
import Carbon
import Combine
import FinderRightKit

/// 轻量截图服务：默认关闭，开启后可通过状态栏菜单或全局快捷键直接唤起系统原生截图面板（⌘⇧5）。
final class ScreenshotService: ObservableObject {
    static let shared = ScreenshotService()

    private static let screenshotBundleId = "com.apple.screenshot.launcher"
    private static let fallbackScreenshotAppURL = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isRegistered = false
    @Published private(set) var errorMessage: String?

    private let config: SharedConfig
    private lazy var hotKey: GlobalActionHotKey = GlobalActionHotKey(
        hotKeyID: EventHotKeyID(signature: 0x46525353, id: 3), // FRSS
        actionId: FinderKeyTakeover.screenshotActionId,
        config: config,
        isFeatureEnabled: { $0.screenshotEnabled },
        allowsNativeSystemShortcut: { FinderKeyTakeover.isDefaultScreenshotShortcut($0) },
        onStateChange: { [weak self] registered, error in
            self?.isRegistered = registered
            self?.errorMessage = error
        }
    )

    init(config: SharedConfig = .shared) {
        self.config = config
        self.isEnabled = config.screenshotEnabled
    }

    func start() {
        config.reload()
        isEnabled = config.screenshotEnabled
        hotKey.start { [weak self] in
            self?.trigger()
        }
    }

    func setEnabled(_ enabled: Bool) {
        config.screenshotEnabled = enabled
        refresh()
    }

    func setRecording(_ recording: Bool) {
        hotKey.setRecording(recording)
    }

    func refresh() {
        config.reload()
        isEnabled = config.screenshotEnabled
        hotKey.refresh()
    }

    func trigger() {
        DispatchQueue.main.async {
            guard self.isEnabled else { return }
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
    }

    private static func resolveScreenshotAppURL() -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: screenshotBundleId) {
            return url
        }
        return FileManager.default.fileExists(atPath: fallbackScreenshotAppURL.path) ? fallbackScreenshotAppURL : nil
    }
}
