import SwiftUI
import FinderRightKit

extension AppDelegate {
    // 供 Settings scene 的 ⌘, 命令与状态栏菜单共用（@objc 供 #selector 使用）
    @objc func openSettings() {
        NSApp.setActivationPolicy(.regular)
        // accessory→regular 切换需延一拍，否则窗口创建早于策略生效会不显示
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.settingsWindow == nil {
                let hosting = NSHostingController(rootView: SettingsView())
                let win = NSWindow(contentViewController: hosting)
                win.title = "FinderRight"
                // 侧边栏延伸到标题栏下方：隐藏标题文字、标题栏透明。
                // 刻意不设 isMovableByWindowBackground：整窗背景拖动会和 SwiftUI 的拖拽排序抢事件，
                // 在 macOS 13 上表现为「拖手柄时窗口跟着鼠标走、无法换行」（Issue #7）。
                // 拖动窗口改用顶端一条显式的拖动条（installTitleDragBar）
                win.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                win.titlebarAppearsTransparent = true
                win.titleVisibility = .hidden
                win.isReleasedWhenClosed = false
                // 先确定 SwiftUI 内容尺寸，避免按尚未布局的小窗口居中后再扩展而偏移。
                win.setContentSize(hosting.view.fittingSize)
                win.center()
                win.setFrameAutosaveName("FinderRightSettings")
                installTitleDragBar(in: win)
                self.settingsWindow = win
            }
            self.settingsWindow?.makeKeyAndOrderFront(nil)
            self.settingsWindow?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// 在窗口顶端挂一条显式的拖动条，取代 isMovableByWindowBackground。
    /// 直接 addSubview 而不走 SwiftUI 的 overlay：NSViewRepresentable 能否拿到鼠标事件
    /// 取决于 SwiftUI 的命中测试，实测不稳定；这里需要的是确定性。
    func installTitleDragBar(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let bar = WindowDragBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            // 让开红绿灯：即使它们与内容区的层叠顺序变化也不会被拖动条盖住
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 78),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    func openGoToDirectory(initialPath: String = "", failure: String? = nil) {
        if let directoryDialog {
            directoryDialog.bringToFront()
            return
        }

        let home = IPCBridge.realUserHomeDirectory.path
        let dialog = FRDialog(
            title: L("打开路径"),
            message: failure ?? L("输入或粘贴文件、文件夹的路径（绝对路径或以 ~/ 开头）"),
            symbol: "arrow.right.circle",
            // 回车默认「在访达中显示」：文件会在所在文件夹中选中，文件夹直接打开
            buttons: [L("在访达中显示"), L("打开"), L("取消")],
            input: .text(initial: initialPath, placeholder: "/Users/… / ~/Documents/…",
                         accessibilityLabel: L("文件或文件夹路径"),
                         hint: { [weak self] input in self?.pathHint(for: input, home: home) }))
        dialog.validate = { [weak self] index in
            guard index != 2 else { return nil }
            do {
                _ = try DirectoryPath.resolve(dialog.text, home: home)
                return nil
            } catch let error as DirectoryPath.ValidationError {
                return self?.L(error.rawValue)
            } catch {
                return error.localizedDescription
            }
        }
        directoryDialog = dialog
        let response = dialog.runModal()
        directoryDialog = nil

        guard response == 0 || response == 1,
              let target = try? DirectoryPath.resolve(dialog.text, home: home) else { return }
        let enteredPath = dialog.text
        let reopenOnFailure: (Error?) -> Void = { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                self?.openGoToDirectory(initialPath: enteredPath, failure: error.localizedDescription)
            }
        }
        switch target {
        case .file(let file) where response == 0:
            NSWorkspace.shared.activateFileViewerSelecting([file])
        case .file(let file):
            // 与在访达中双击相同：交给该文件的默认 App
            NSWorkspace.shared.open(file, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                reopenOnFailure(error)
            }
        case .directory(let directory):
            guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
                openGoToDirectory(initialPath: enteredPath, failure: L("无法打开目录，请检查访问权限"))
                return
            }
            NSWorkspace.shared.open([directory], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                reopenOnFailure(error)
            }
        }
    }

    /// 输入框下方的实时识别：是文件还是文件夹、位于哪里
    func pathHint(for input: String, home: String) -> FRDialog.Hint? {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let abbreviate = { (path: String) -> String in
            path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        switch try? DirectoryPath.resolve(input, home: home) {
        case .file(let file):
            return FRDialog.Hint(symbol: "doc", text: String(format: L("文件 · 位于 %@"), abbreviate(file.deletingLastPathComponent().path)), ok: true)
        case .directory(let directory):
            return FRDialog.Hint(symbol: "folder", text: String(format: L("文件夹 · %@"), abbreviate(directory.path)), ok: true)
        case nil:
            return FRDialog.Hint(symbol: "questionmark.circle", text: L("未找到这个路径"), ok: false)
        }
    }

    /// 设置页「重新查看引导」：从头开始
    @objc func openOnboarding() {
        showOnboarding()
    }

    /// 菜单栏「启用 Finder 扩展…」：直接从扩展步骤开始
    @objc func openExtensionSetup() {
        showOnboarding(startingAt: OnboardingView.extensionStep)
    }

    /// 引导窗口已打开时只把它提到前面，不重置用户当前所在的步骤
    func showOnboarding(startingAt step: Int = 0) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.onboardingWindow == nil {
                let hosting = NSHostingController(rootView: OnboardingView(initialStep: step, onClose: { [weak self] in
                    self?.onboardingWindow?.close()
                }))
                let win = NSWindow(contentViewController: hosting)
                win.title = self.L("欢迎使用 FinderRight")
                win.styleMask = [.titled, .closable, .fullSizeContentView]
                win.titlebarAppearsTransparent = true
                win.titleVisibility = .hidden
                win.isMovableByWindowBackground = true
                win.isReleasedWhenClosed = false
                win.setContentSize(NSSize(width: 600, height: 500))
                win.center()
                self.onboardingWindow = win
            }
            self.onboardingWindow?.makeKeyAndOrderFront(nil)
            self.onboardingWindow?.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - 窗口与激活策略

    /// 打开普通窗口（设置/引导）前调用：
    /// accessory App 无法正常显示并聚焦窗口，先临时切为 regular 再激活。
    func beginShowingStandardWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 标准窗口关闭后，如果用户没要求常驻 Dock，且已无可见标准窗口，则切回 accessory
    @objc func windowWillClose(_ note: Notification) {
        if let closing = note.object as? NSWindow {
            if closing === settingsWindow {
                // 关闭后 AppKit 可能仍持有窗口，释放保存名称供下次创建恢复。
                closing.setFrameAutosaveName("")
                settingsWindow = nil
            }
            if closing === onboardingWindow { onboardingWindow = nil }
        }
        guard !alwaysShowDockIcon else { return }
        let closing = note.object as? NSWindow
        DispatchQueue.main.async { [weak self] in
            let stillHasStandardWindow = NSApp.windows.contains { w in
                w !== closing && w.isVisible && w.canBecomeMain
            }
            if !stillHasStandardWindow {
                NSApp.setActivationPolicy(.accessory)
            }
            _ = self
        }
    }

}

// MARK: - 窗口拖动条

/// 窗口顶端的拖动条：只有这一条响应「拖窗口」。
///
/// 之前用 isMovableByWindowBackground 让整个窗口背景可拖，它会和 SwiftUI 的拖拽会话抢同一个
/// mouseDown：在 macOS 13 上两条路径同时启动，窗口跟着鼠标走，指针相对列表行的位移恒为 0，
/// 拖拽排序因此永远换不了行（Issue #7）。改成只留一条后既彻底避开抢事件，
/// 也符合设置窗口「点开关时不该把窗口拖走」的预期。
private final class WindowDragBar: NSView {
    override var isOpaque: Bool { false }

    /// 窗口未激活时第一次按下也能直接开拖，与系统标题栏一致
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // 双击与系统标题栏行为保持一致（设置 - 桌面与程序坞 - 双击窗口标题栏）
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
            return
        }
        window.performDrag(with: event)
    }
}
