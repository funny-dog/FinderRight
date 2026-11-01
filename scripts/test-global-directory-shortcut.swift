import AppKit
import Carbon
import FinderRightKit

// 测试程序不包含 FinderRightApp.swift 的 SwiftUI @main，保留其通知名供设置页编译。
extension Notification.Name {
    static let openOnboarding = Notification.Name("FinderRight.openOnboarding")
}

@main
struct GlobalDirectoryShortcutTests {
    static func main() throws {
        _ = NSApplication.shared
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
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(invocations == 1, "系统热键事件应调用既有弹窗入口一次")

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
