import AppKit
import Carbon
import FinderRightKit

// 测试程序不包含 FinderRightApp.swift 的 SwiftUI @main，保留其通知名供设置页编译。
extension Notification.Name {
    static let openOnboarding = Notification.Name("FinderRight.openOnboarding")
}

private final class DialogTestApplication: NSApplication {
    var modalCalls = 0
    var attentionRequests = 0

    override func runModal(for window: NSWindow) -> NSApplication.ModalResponse {
        modalCalls += 1
        return .cancel
    }

    override func requestUserAttention(_ requestType: NSApplication.RequestUserAttentionType) -> Int {
        attentionRequests += 1
        return 0
    }
}

@main
struct GlobalDirectoryShortcutTests {
    static func main() throws {
        precondition(!ServiceShortcutSync.defaultShowsServicesMenu, "在服务中显示 FinderRight 应默认关闭")
        let application = DialogTestApplication.shared as! DialogTestApplication
        application.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        weak var releasedDialog: FRDialog?
        autoreleasepool {
            delegate.openGoToDirectory(initialPath: "/")
            precondition(application.modalCalls == 0 && NSApp.modalWindow == nil, "打开路径不能进入后台模态循环")
            guard let dialog = delegate.directoryDialog else { preconditionFailure("非模态输入框应保持可用") }
            releasedDialog = dialog
            delegate.openGoToDirectory()
            precondition(delegate.directoryDialog === dialog, "重复唤起应复用输入框")
            dialog.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            precondition(delegate.directoryDialog == nil, "取消后应清除输入框状态")
        }
        precondition(releasedDialog == nil, "关闭后不能因校验闭包引用而泄漏")
        precondition(application.attentionRequests == 0, "显示路径输入框不应请求 Dock 提醒")
        print("✓ 路径输入框：非模态、重复唤起、取消清理与释放检查通过")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = SharedConfig(fileURL: directory.appendingPathComponent("settings.plist"))
        let action = FinderKeyTakeover.goToDirectoryActionId
        let modifiers = Int(NSEvent.ModifierFlags([.command, .control, .option, .shift]).rawValue)
        let first = ActionShortcut(key: "\u{F709}", modifiers: modifiers) // F6
        let second = ActionShortcut(key: "\u{F70A}", modifiers: modifiers) // F7
        let controller = GlobalDirectoryShortcut(config: config)
        var invocations = 0
        controller.start { invocations += 1 }
        precondition(!controller.isEnabled && !config.globalOpenPathShortcut)

        controller.setEnabled(true)
        precondition(!controller.isEnabled && controller.errorMessage != nil, "未设置组合时不能开启")
        config.setShortcut(first, forActionId: action)
        controller.setEnabled(true)
        precondition(controller.isEnabled && controller.errorMessage == nil, "注册失败：\(controller.errorMessage ?? "")")
        precondition(!canRegister(first), "应已独占注册全局热键")
        controller.refresh()
        precondition(controller.isEnabled, "重复刷新不应与自己冲突")

        var event: EventRef?
        precondition(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed),
                                 0, OptionBits(kEventAttributeUserEvent), &event) == noErr)
        var id = EventHotKeyID(signature: 0x46525048, id: 1)
        precondition(SetEventParameter(event!, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       MemoryLayout<EventHotKeyID>.size, &id) == noErr)
        precondition(SendEventToEventTarget(event!, GetApplicationEventTarget()) == noErr)
        ReleaseEvent(event!)
        // CI 负载下主队列回调可能显著晚于单个 50ms 窗口。
        let dispatchDeadline = Date(timeIntervalSinceNow: 5)
        while invocations == 0 && Date() < dispatchDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        precondition(invocations == 1, "系统热键事件应调用既有弹窗入口一次")
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(invocations == 1, "热键事件不应重复调用弹窗入口")

        controller.setRecording(true)
        precondition(canRegister(first), "录制时释放旧组合")
        controller.setRecording(false)
        precondition(!canRegister(first), "结束录制后恢复注册")
        config.setShortcut(second, forActionId: action)
        controller.refresh()
        precondition(canRegister(first) && !canRegister(second), "改键后释放旧组合并注册新组合")
        controller.setEnabled(false)
        precondition(canRegister(second) && !config.globalOpenPathShortcut, "关闭时释放组合并持久化")

        var occupied: EventHotKeyRef?
        let chord = FinderShortcutInterceptor.chord(for: first)!
        let carbon = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        precondition(RegisterEventHotKey(UInt32(chord.keyCode), carbon, EventHotKeyID(signature: 0x54455354, id: 2),
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &occupied) == noErr)
        config.setShortcut(first, forActionId: action)
        controller.setEnabled(true)
        precondition(!controller.isEnabled && !config.globalOpenPathShortcut && controller.errorMessage != nil,
                     "已被注册时保持关闭并给出错误")
        UnregisterEventHotKey(occupied!)

        config.setShortcut(ActionShortcut(key: " ", modifiers: Int(NSEvent.ModifierFlags.command.rawValue)), forActionId: action)
        controller.setEnabled(true)
        precondition(!controller.isEnabled && controller.errorMessage != nil, "系统组合不能全局注册")
        config.setShortcut(first, forActionId: action)
        controller.setEnabled(true)
        config.setShortcut(nil, forActionId: action)
        controller.refresh()
        precondition(!controller.isEnabled && canRegister(first), "清除组合时关闭全局入口")
        print("✓ 全局打开路径：默认关闭、事件派发、重复刷新、录制暂停、改键、关闭、冲突和清除检查通过")

        let menu = NSMenu()
        func toolItems() -> (clipboard: NSMenuItem, screenshot: NSMenuItem) {
            menu.removeAllItems()
            delegate.populate(menu, clipboardEnabled: true, screenshotEnabled: true, config: config)
            guard let clipboard = menu.items.first(where: { $0.action == #selector(AppDelegate.openClipboardHistory) }),
                  let screenshot = menu.items.first(where: { $0.action == #selector(AppDelegate.triggerScreenshot) }) else {
                preconditionFailure("状态栏菜单应包含剪贴板与截图菜单项")
            }
            return (clipboard, screenshot)
        }

        let initialItems = toolItems()
        precondition(initialItems.clipboard.keyEquivalent == "" && initialItems.clipboard.keyEquivalentModifierMask.isEmpty,
                     "未设置剪贴板快捷键时菜单项右侧不应显示快捷键")
        precondition(initialItems.screenshot.keyEquivalent == "" && initialItems.screenshot.keyEquivalentModifierMask.isEmpty,
                     "未设置截图快捷键时菜单项右侧不应显示快捷键")
        let targetSelectors: [Selector] = [
            #selector(AppDelegate.openClipboardHistory),
            #selector(AppDelegate.triggerScreenshot),
            #selector(AppDelegate.openSettings),
            #selector(AppDelegate.checkForUpdates),
        ]
        for selector in targetSelectors {
            guard let item = menu.items.first(where: { $0.action == selector }) else {
                preconditionFailure("状态栏菜单缺少预期的菜单项：\(selector)")
            }
            precondition(!item.title.contains("…") && !item.title.contains("..."),
                         "状态栏静态菜单文案不应带省略号：\(item.title)")
        }

        let clipboardShortcut = ActionShortcut(key: "V", modifiers: Int(NSEvent.ModifierFlags([.command, .option]).rawValue))
        config.setShortcut(clipboardShortcut, forActionId: FinderKeyTakeover.clipboardActionId)
        config.setShortcut(FinderKeyTakeover.defaultScreenshotShortcut, forActionId: FinderKeyTakeover.screenshotActionId)
        let configuredItems = toolItems()
        precondition(configuredItems.clipboard.keyEquivalent == "v"
                     && configuredItems.clipboard.keyEquivalentModifierMask == [.command, .option],
                     "剪贴板菜单项应显示用户设置的 ⌥⌘V 快捷键")
        precondition(configuredItems.screenshot.keyEquivalent == "5"
                     && configuredItems.screenshot.keyEquivalentModifierMask == [.command, .shift],
                     "截图菜单项应显示用户设置的 ⇧⌘5 快捷键")

        config.setShortcut(nil, forActionId: FinderKeyTakeover.clipboardActionId)
        let clearedItems = toolItems()
        precondition(clearedItems.clipboard.keyEquivalent == "" && clearedItems.clipboard.keyEquivalentModifierMask.isEmpty,
                     "清空剪贴板快捷键后菜单项右侧应同步清除")
        precondition(clearedItems.screenshot.keyEquivalent == "5"
                     && clearedItems.screenshot.keyEquivalentModifierMask == [.command, .shift],
                     "清空剪贴板快捷键不应影响截图菜单项快捷键")
        print("✓ 状态栏菜单：剪贴板与截图快捷键显示与更新检查通过")

        let clipboardRoot = directory.appendingPathComponent("clipboard-service", isDirectory: true)
        let clipboardDir = clipboardRoot.appendingPathComponent("history", isDirectory: true)
        let clipboardConfig = SharedConfig(fileURL: clipboardRoot.appendingPathComponent("settings.plist"))
        precondition(clipboardConfig.clipboardEnabled, "剪贴板功能应默认开启")
        let persistence = ClipboardHistoryPersistence(directoryURL: clipboardDir)
        let isolatedPasteboard = NSPasteboard.withUniqueName()
        defer { isolatedPasteboard.releaseGlobally() }

        let fileA = directory.appendingPathComponent("drop-a.txt")
        let fileB = directory.appendingPathComponent("drop-b.txt")
        try Data("a".utf8).write(to: fileA)
        try Data("b".utf8).write(to: fileB)

        let service = ClipboardHistoryService(config: clipboardConfig, persistence: persistence)
        precondition(service.recordDroppedFiles([fileA, fileB], pasteboard: isolatedPasteboard, showToast: false),
                     "拖入有效文件应写入隔离剪贴板与历史记录")
        precondition(service.items.first?.kind == .files([fileA.standardizedFileURL, fileB.standardizedFileURL]),
                     "拖入文件应置顶进入剪贴板历史")
        let pbURLs = ClipboardHistoryService.fileURLs(from: isolatedPasteboard).map(\.standardizedFileURL)
        precondition(pbURLs == [fileA.standardizedFileURL, fileB.standardizedFileURL],
                     "拖入文件后应同时写入剪贴板：\(pbURLs)")
        precondition(!service.recordDroppedFiles([URL(string: "https://example.com")!], pasteboard: isolatedPasteboard, showToast: false),
                     "非 fileURL 不应被记录")
        service.prepareForTermination()

        let restarted = ClipboardHistoryService(config: clipboardConfig, persistence: persistence)
        precondition(restarted.items.first?.kind == .files([fileA.standardizedFileURL, fileB.standardizedFileURL]),
                     "退出重建服务后应仍保留已持久化的拖入文件记录")
        restarted.clear()
        restarted.prepareForTermination()
        precondition(!FileManager.default.fileExists(atPath: clipboardDir.path),
                     "清空历史并同步写盘后应删除磁盘目录")
        print("✓ 剪贴板文件拖入：写入剪贴板、重启持久化恢复与清空删除检查通过")
    }

    static func canRegister(_ shortcut: ActionShortcut) -> Bool {
        let chord = FinderShortcutInterceptor.chord(for: shortcut)!
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(chord.keyCode), UInt32(cmdKey | controlKey | optionKey | shiftKey),
                                        EventHotKeyID(signature: 0x54455354, id: 3), GetApplicationEventTarget(),
                                        OptionBits(kEventHotKeyExclusive), &reference)
        if let reference { UnregisterEventHotKey(reference) }
        return status == noErr
    }
}
