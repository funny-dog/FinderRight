import AppKit
import Carbon
import Combine
import FinderRightKit

/// 通用的单动作全局热键注册器（基于 Carbon RegisterEventHotKey，无需辅助功能权限）。
/// 所有方法在主线程调用。
final class GlobalActionHotKey {
    private let hotKeyID: EventHotKeyID
    private let actionId: String
    private let config: SharedConfig
    private let isFeatureEnabled: (SharedConfig) -> Bool
    private let allowsNativeSystemShortcut: (ActionShortcut) -> Bool
    private let systemConflictMessage: (ActionShortcut) -> String?
    private let onStateChange: (_ isRegistered: Bool, _ errorMessage: String?) -> Void

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var registeredChord: FinderKeyTakeover.KeyChord?
    private var isRecording = false
    private var onTrigger: (() -> Void)?

    init(
        hotKeyID: EventHotKeyID,
        actionId: String,
        config: SharedConfig = .shared,
        isFeatureEnabled: @escaping (SharedConfig) -> Bool,
        allowsNativeSystemShortcut: @escaping (ActionShortcut) -> Bool = { _ in false },
        systemConflictMessage: @escaping (ActionShortcut) -> String? = { _ in nil },
        onStateChange: @escaping (_ isRegistered: Bool, _ errorMessage: String?) -> Void
    ) {
        self.hotKeyID = hotKeyID
        self.actionId = actionId
        self.config = config
        self.isFeatureEnabled = isFeatureEnabled
        self.allowsNativeSystemShortcut = allowsNativeSystemShortcut
        self.systemConflictMessage = systemConflictMessage
        self.onStateChange = onStateChange
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func start(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        refresh()
    }

    func setRecording(_ recording: Bool) {
        isRecording = recording
        refresh()
    }

    func refresh() {
        config.reload()
        guard isFeatureEnabled(config) else {
            unregister()
            onStateChange(false, nil)
            return
        }
        guard let shortcut = config.shortcut(forActionId: actionId) else {
            unregister()
            onStateChange(false, nil)
            return
        }
        guard !isRecording else {
            unregister()
            return
        }
        guard let chord = FinderShortcutInterceptor.chord(for: shortcut) else {
            fail(NSLocalizedString("当前键盘布局无法使用这个快捷键，请重新录制", comment: ""))
            return
        }
        let modifiers = Self.carbonModifiers(chord.modifiers)
        guard modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
                || FinderKeyTakeover.isFunctionKey(shortcut.key),
              FinderKeyTakeover.recordingConflict(for: shortcut, actionId: actionId,
                                                  interceptorAvailable: true)?.isSystem != true else {
            fail(NSLocalizedString("该组合不能用作全局快捷键，或已被系统使用，请重新录制", comment: ""))
            return
        }

        let systemConflict = Self.hasSystemSymbolicConflict(keyCode: chord.keyCode, carbonModifiers: modifiers)
        if systemConflict {
            if allowsNativeSystemShortcut(shortcut) {
                // 系统原生热键已启用且与默认组合一致时，直接交由系统响应，不抢占也不报错
                unregister()
                onStateChange(false, nil)
                return
            }
            fail(systemConflictMessage(shortcut)
                 ?? NSLocalizedString("该组合不能用作全局快捷键，或已被系统使用，请重新录制", comment: ""))
            return
        }

        if registeredChord == chord {
            onStateChange(true, nil)
            return
        }
        unregister()
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<GlobalActionHotKey>.fromOpaque(context).takeUnretainedValue()
                var id = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                      id.signature == owner.hotKeyID.signature,
                      id.id == owner.hotKeyID.id else { return OSStatus(eventNotHandledErr) }
                guard !owner.isRecording else { return OSStatus(eventNotHandledErr) }
                owner.config.reload()
                guard owner.isFeatureEnabled(owner.config) else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { [weak owner] in
                    guard let owner, !owner.isRecording else { return }
                    owner.onTrigger?()
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { registrationFailed(status); return }
        }
        let status = RegisterEventHotKey(UInt32(chord.keyCode), modifiers, hotKeyID,
                                        GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        guard status == noErr else { registrationFailed(status); return }
        registeredChord = chord
        onStateChange(true, nil)
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
        onStateChange(false, message)
    }

    private static func hasSystemSymbolicConflict(keyCode: Int, carbonModifiers: UInt32) -> Bool {
        var symbolicKeys: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&symbolicKeys)
        let systemKeys = symbolicKeys?.takeRetainedValue() as? [[String: Any]] ?? []
        return status == noErr && systemKeys.contains {
            ($0[kHISymbolicHotKeyEnabled] as? Bool) == true &&
            ($0[kHISymbolicHotKeyCode] as? Int) == keyCode &&
            ($0[kHISymbolicHotKeyModifiers] as? UInt32) == carbonModifiers
        }
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

/// 只注册「剪贴板」这一组全局热键，无需辅助功能权限。所有方法在主线程调用。
final class GlobalClipboardShortcut: ObservableObject {
    static let shared = GlobalClipboardShortcut()

    @Published private(set) var isRegistered = false
    @Published private(set) var errorMessage: String?

    private lazy var hotKey: GlobalActionHotKey = GlobalActionHotKey(
        hotKeyID: EventHotKeyID(signature: 0x46525043, id: 2), // FRPC
        actionId: FinderKeyTakeover.clipboardActionId,
        config: config,
        isFeatureEnabled: { $0.clipboardEnabled },
        onStateChange: { [weak self] registered, error in
            self?.isRegistered = registered
            self?.errorMessage = error
        }
    )
    private let config: SharedConfig

    init(config: SharedConfig = .shared) {
        self.config = config
    }

    func start(onTrigger: @escaping () -> Void) {
        hotKey.start(onTrigger: onTrigger)
    }

    func setRecording(_ recording: Bool) {
        hotKey.setRecording(recording)
    }

    func refresh() {
        hotKey.refresh()
    }
}
