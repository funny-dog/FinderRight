import AppKit
import Carbon
import Combine
import FinderRightKit

/// 只注册「打开路径」这一组全局热键，不监听其他应用的按键。所有方法在主线程调用。
final class GlobalDirectoryShortcut: ObservableObject {
    static let shared = GlobalDirectoryShortcut()
    private static let hotKeyID = EventHotKeyID(signature: 0x46525048, id: 1) // FRPH

    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private let config: SharedConfig
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredChord: FinderKeyTakeover.KeyChord?
    private var isRecording = false
    private var showPrompt: (() -> Void)?

    init(config: SharedConfig = .shared) {
        self.config = config
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func start(showPrompt: @escaping () -> Void) {
        self.showPrompt = showPrompt
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        config.globalOpenPathShortcut = enabled
        refresh()
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        refresh()
    }

    func refresh() {
        isEnabled = config.globalOpenPathShortcut
        guard isEnabled else { unregister(); return }
        guard let shortcut = config.shortcut(forActionId: FinderKeyTakeover.goToDirectoryActionId) else {
            fail(NSLocalizedString("请先设置打开路径的快捷键", comment: ""))
            return
        }
        guard !isRecording else { unregister(); return }
        guard let chord = FinderShortcutInterceptor.chord(for: shortcut) else {
            fail(NSLocalizedString("当前键盘布局无法使用这个快捷键，请重新录制", comment: ""))
            return
        }
        let modifiers = Self.carbonModifiers(chord.modifiers)
        var symbolicKeys: Unmanaged<CFArray>?
        let systemKeysStatus = CopySymbolicHotKeys(&symbolicKeys)
        let systemKeys = symbolicKeys?.takeRetainedValue() as? [[String: Any]] ?? []
        let systemConflict = systemKeysStatus == noErr && systemKeys.contains {
            ($0[kHISymbolicHotKeyEnabled] as? Bool) == true &&
            ($0[kHISymbolicHotKeyCode] as? Int) == chord.keyCode &&
            ($0[kHISymbolicHotKeyModifiers] as? UInt32) == modifiers
        }
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0,
              FinderKeyTakeover.recordingConflict(for: shortcut, actionId: FinderKeyTakeover.goToDirectoryActionId,
                                                  interceptorAvailable: true)?.isSystem != true,
              !systemConflict else {
            fail(NSLocalizedString("该组合不能用作全局快捷键，或已被系统使用，请重新录制", comment: ""))
            return
        }
        if registeredChord == chord { return }
        unregister()
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == GlobalDirectoryShortcut.hotKeyID.signature,
                      id.id == GlobalDirectoryShortcut.hotKeyID.id else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalDirectoryShortcut>.fromOpaque(context).takeUnretainedValue()
                guard owner.isEnabled, !owner.isRecording else { return OSStatus(eventNotHandledErr) }
                owner.config.reload()
                guard owner.config.isActionEnabled(MenuFeatureCatalog.goToDirectory) else {
                    NSSound.beep()
                    return noErr
                }
                // 先返回系统事件处理器，避免路径弹窗的模态循环占住热键回调。
                DispatchQueue.main.async { [weak owner] in
                    guard let owner, owner.isEnabled, !owner.isRecording else { return }
                    owner.showPrompt?()
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { registrationFailed(status); return }
        }
        let status = RegisterEventHotKey(UInt32(chord.keyCode), modifiers, Self.hotKeyID,
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard status == noErr else { registrationFailed(status); return }
        registeredChord = chord
        errorMessage = nil
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        registeredChord = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func registrationFailed(_ status: OSStatus) {
        fail(String(format: NSLocalizedString("无法注册全局快捷键（错误 %d），请换一个组合。其他应用可能已注册此快捷键。", comment: ""), status))
    }

    private func fail(_ message: String) {
        unregister()
        config.globalOpenPathShortcut = false
        isEnabled = false
        errorMessage = message
    }

    private static func carbonModifiers(_ modifiers: Int) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}
