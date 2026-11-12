import AppKit
import Foundation

/// 临时/辅助工具窗口面板（剪切队列、行数统计、Git 状态、文件比较、磁盘占用、自定义命令等）。
/// 继承自 NSPanel 并包含 `.nonactivatingPanel` 样式掩码，使得它浮现并接收键盘输入时，
/// 绝对不会激活整个宿主应用（NSApp.activate），从而保证已在后台打开的设置窗口绝对不会被带到前台。
class FRTransientPanel: NSPanel {
    init(contentRect: NSRect, minSize: CGSize? = nil) {
        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel
        ]
        super.init(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.isFloatingPanel = false
        if let minSize {
            self.minSize = NSWindow.frameRect(
                forContentRect: NSRect(origin: .zero, size: minSize),
                styleMask: styleMask).size
        }
    }
}

/// 临时窗口关闭后的激活决策。
///
/// 只有 FinderRight 仍是前台应用时才交还焦点；外部唤起的窗口不受其他后台窗口影响。
/// 是否恢复 accessory 与是否交还焦点分开判断，用户切换到别的应用后也不能留下 Dock 图标。
struct WindowActivationDecision: Equatable {
    let restoreApplicationPID: pid_t?
    let shouldReturnToAccessory: Bool
}

enum WindowActivationPolicy {
    static func decision(
        currentApplicationPID: pid_t,
        previousApplicationPID: pid_t?,
        frontmostApplicationPID: pid_t?,
        isApplicationActive: Bool = true,
        hasVisibleStandardWindow: Bool,
        openedFromExternalApplication: Bool,
        previousApplicationIsRunning: Bool,
        alwaysShowDockIcon: Bool
    ) -> WindowActivationDecision {
        let shouldReturnToAccessory = !alwaysShowDockIcon && !hasVisibleStandardWindow
        // 外部唤起时即使使用非激活面板（frontmost 仍是来源应用），在关闭后也应重新激活来源应用以恢复其窗口焦点
        let owningAppIsFrontmost = frontmostApplicationPID == currentApplicationPID
            || (openedFromExternalApplication && frontmostApplicationPID == previousApplicationPID)
        guard let previousApplicationPID,
              previousApplicationPID != currentApplicationPID,
              previousApplicationIsRunning,
              !hasVisibleStandardWindow || openedFromExternalApplication,
              owningAppIsFrontmost else {
            return WindowActivationDecision(
                restoreApplicationPID: nil,
                shouldReturnToAccessory: shouldReturnToAccessory)
        }
        return WindowActivationDecision(
            restoreApplicationPID: previousApplicationPID,
            shouldReturnToAccessory: shouldReturnToAccessory)
    }
}

/// 从访达等应用打开的临时窗口，关闭后把焦点交还给打开前的应用。
///
/// 记录按窗口保存，而不是按控制器保存：自定义命令可以同时有多个输出窗口。
/// 同一 RunLoop 关闭多个窗口只处理一次，避免前一个窗口的恢复动作覆盖后一个窗口，
/// 也避免旧窗口仍被 AppKit 视为可见时过早切回 accessory。
final class TransientWindowManager {
    struct Environment {
        var frontmostApplication: () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        }
        var applicationIsActive: () -> Bool = { NSApp.isActive }
        var show: (NSWindow) -> Void = { window in
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
        var showInternal: (NSWindow) -> Void = { window in
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
        var isWindowVisible: (NSWindow) -> Bool = { $0.isVisible }
        var hasVisibleStandardWindow: (Set<ObjectIdentifier>) -> Bool = { closing in
            NSApp.windows.contains { window in
                guard !closing.contains(ObjectIdentifier(window)),
                      window.isVisible,
                      !(window is NSPanel) else { return false }
                return window.canBecomeMain || window.canBecomeKey
            }
        }
        var alwaysShowDockIcon: () -> Bool = {
            UserDefaults.standard.bool(forKey: "showDockIcon")
        }
        var previousApplicationIsRunning: (NSRunningApplication) -> Bool = { !$0.isTerminated }
        var activate: (NSRunningApplication) -> Void = { app in
            app.activate(options: [.activateIgnoringOtherApps])
        }
        var returnToAccessory: () -> Void = {
            NSApp.setActivationPolicy(.accessory)
        }
        /// 测试可直接执行，产品代码延后一拍让 AppKit 完成窗口关闭和焦点交接。
        var schedule: (@escaping () -> Void) -> Void = { work in
            DispatchQueue.main.async(execute: work)
        }
    }

    private struct Presentation {
        let application: NSRunningApplication
        let openedFromExternalApplication: Bool
    }

    private struct ClosedWindow {
        let window: NSWindow
        let presentation: Presentation?
    }

    static let shared = TransientWindowManager()

    var onClosed: (() -> Void)? = nil

    private let environment: Environment
    private var lastExternalApplication: NSRunningApplication?
    private var presentations: [ObjectIdentifier: Presentation] = [:]
    private var transientWindows: [ObjectIdentifier: NSWindow] = [:]
    private var closedWindows: [ObjectIdentifier: ClosedWindow] = [:]
    private var closeOrder: [ObjectIdentifier] = []
    private var closeIsScheduled = false

    init(environment: Environment = Environment()) {
        self.environment = environment
    }

    /// IPC 可能先于窗口显示激活 App，持续记录外部前台才能找回真正的来源。
    func startTrackingFrontmostApplications() {
        let currentPID = NSRunningApplication.current.processIdentifier
        if let frontmost = environment.frontmostApplication(), frontmost.processIdentifier != currentPID {
            lastExternalApplication = frontmost
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != currentPID else { return }
            self?.lastExternalApplication = app
        }
    }

    /// 显示临时窗口。窗口仍打开时再次显示，不覆盖原来的前台来源；
    /// 如果用户已从另一个应用重新唤起，则更新为那个应用。
    func present(_ window: NSWindow, openedFromExternalApplication: Bool = true) {
        transientWindows[ObjectIdentifier(window)] = window
        recordPresentation(of: window, openedFromExternalApplication: openedFromExternalApplication)
        if openedFromExternalApplication {
            environment.show(window)
        } else {
            environment.showInternal(window)
        }
    }

    /// 分离记录与真正激活，便于不创建可见窗口的回归检查。
    func recordPresentation(of window: NSWindow, openedFromExternalApplication: Bool = true) {
        let key = ObjectIdentifier(window)
        // 先保留旧关闭记录中的来源；同一窗口在延迟结算前重开时，旧记录会被移除。
        let inheritedSource = closedWindows[key]?.presentation?.application
            ?? lastExternalApplication ?? presentations.values.first?.application
        closedWindows.removeValue(forKey: key)
        closeOrder.removeAll { $0 == key }

        guard let frontmost = environment.frontmostApplication(),
              frontmost.processIdentifier != NSRunningApplication.current.processIdentifier else {
            // IPC/URL 可能已提前激活 FinderRight，来源由调用入口显式声明。
            if presentations[key] == nil, let inheritedSource {
                presentations[key] = Presentation(
                    application: inheritedSource,
                    openedFromExternalApplication: openedFromExternalApplication)
            }
            return
        }
        lastExternalApplication = frontmost
        presentations[key] = Presentation(
            application: frontmost,
            openedFromExternalApplication: openedFromExternalApplication)
    }

    /// 由窗口 delegate 和 AppDelegate 的全局关闭监听共同调用；同一窗口只登记一次。
    func windowWillClose(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        // 仅处理由管理器登记过的受管窗口（临时窗口、设置窗口、引导窗口等），
        // 忽略未受管的系统内部窗口（如 NSPopupMenuWindow 状态栏菜单关闭），避免误将应用切回 accessory。
        guard transientWindows[key] != nil || presentations[key] != nil else { return }
        guard closedWindows[key] == nil else { return }
        transientWindows.removeValue(forKey: key)
        let presentation = presentations.removeValue(forKey: key)
        closedWindows[key] = ClosedWindow(
            window: window,
            presentation: presentation)
        closeOrder.append(key)

        guard !closeIsScheduled else { return }
        closeIsScheduled = true
        environment.schedule { [weak self] in
            self?.processClosedWindows()
        }
    }

    private func processClosedWindows() {
        closeIsScheduled = false
        let records = closeOrder.compactMap { closedWindows[$0] }
        closedWindows.removeAll()
        closeOrder.removeAll()
        guard !records.isEmpty else { return }

        let closing = Set(records.map { ObjectIdentifier($0.window) })
        let previousRecord = records.last(where: { $0.presentation != nil })
        let previous = previousRecord?.presentation?.application
        let hasVisibleTransientWindow = transientWindows.values.contains { environment.isWindowVisible($0) }
        let decision = WindowActivationPolicy.decision(
            currentApplicationPID: NSRunningApplication.current.processIdentifier,
            previousApplicationPID: previous?.processIdentifier,
            frontmostApplicationPID: environment.frontmostApplication()?.processIdentifier,
            isApplicationActive: environment.applicationIsActive(),
            hasVisibleStandardWindow: environment.hasVisibleStandardWindow(closing),
            openedFromExternalApplication: (previousRecord?.presentation?.openedFromExternalApplication ?? false)
                && !hasVisibleTransientWindow,
            previousApplicationIsRunning: previous.map(environment.previousApplicationIsRunning) ?? false,
            alwaysShowDockIcon: environment.alwaysShowDockIcon())

        if let previous, decision.restoreApplicationPID == previous.processIdentifier {
            environment.activate(previous)
        }
        if decision.shouldReturnToAccessory {
            environment.returnToAccessory()
        }
        onClosed?()
        let hook = self.onClosed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            hook?()
        }
    }
}
