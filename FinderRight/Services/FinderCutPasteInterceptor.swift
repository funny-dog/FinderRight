import AppKit
import ApplicationServices
import Carbon
import FinderRightKit

/// 处理设置页「剪切」「粘贴」快捷键（默认 ⌘X / ⌘V，可改，清空即停用；需「辅助功能」权限）。
/// 决策规则见 Kit 的 FinderCutPasteTakeover。
///
/// - 只在访达处于前台时启用按键拦截：看不到其他 App 的按键，本 App 卡顿也不会拖慢别处打字。
/// - 拦截跑在独立线程的 run loop 上，回调里只比较键码、查一次焦点；
///   点菜单、等剪贴板、写剪切队列都放到工作队列。
/// - 回调里绝不把按键翻译成字符：输入法接口只许在主线程调用。快捷键在主线程预先换算成键码。
/// - 不发合成按键：直接用辅助功能点访达「编辑」菜单，不受键盘布局影响，也不会被自己再拦一次。
final class FinderCutPasteInterceptor {

    static let shared = FinderCutPasteInterceptor()

    private static let finderBundleId = "com.apple.finder"
    /// 访达「编辑」菜单项按快捷键识别（标题随选中项变化，如「拷贝“a.txt”」）。
    /// AXMenuItemCmdModifiers：0 = 仅 ⌘，2 = ⌥⌘
    private static let copyItem = (char: "C", modifiers: 0)
    private static let moveHereItem = (char: "V", modifiers: 2)

    private let service = FinderRightService()
    private let workQueue = DispatchQueue(label: "com.finderright.app.cutpaste.takeover", qos: .userInteractive)
    private let cutQueue = CutQueueStore()

    /// 以下状态跨拦截线程、工作队列与主线程访问，统一由 lock 保护
    private let lock = NSLock()
    private var mirror = CutPasteboardMirror()
    private var finderPid: pid_t = 0
    private var finderApp: AXUIElement?
    private var finderIsFrontmost = false
    private var tapShouldBeEnabled = false
    private var cutChord: FinderCutPasteTakeover.KeyChord?
    private var pasteChord: FinderCutPasteTakeover.KeyChord?
    private var copyChord: FinderCutPasteTakeover.KeyChord?

    /// 只在主线程创建与开关
    private var tap: CFMachPort?

    private init() {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - 生命周期（主线程）

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        // 切换输入法 / 键盘布局后，同一字符可能落在别的键上，要重新换算键码
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        // 从系统设置授权后切回本 App
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    /// 首次运行本版本时补上默认的 ⌘X / ⌘V（规则见 FinderCutPasteTakeover.defaultsToApply）：
    /// 只填用户没设置的行，用户的快捷键升级后保持不变。只做一次：之后用户清空就是停用，不会再被补回。
    static func applyDefaultShortcutsIfNeeded() {
        let appliedKey = "cutPasteNativeShortcutsApplied"
        guard !UserDefaults.standard.bool(forKey: appliedKey) else { return }
        let config = SharedConfig.shared
        for (actionId, shortcut) in FinderCutPasteTakeover.defaultsToApply(current: config.shortcuts) {
            config.setShortcut(shortcut, forActionId: actionId)
        }
        UserDefaults.standard.set(true, forKey: appliedKey)
    }

    /// 至少设了一个剪切 / 粘贴快捷键且已授权：剪切时才把队列镜像到剪贴板
    var isActive: Bool {
        let shortcuts = SharedConfig.shared.shortcuts
        let hasShortcut = shortcuts[FinderCutPasteTakeover.cutActionId] != nil
            || shortcuts[FinderCutPasteTakeover.pasteActionId] != nil
        return hasShortcut && AXIsProcessTrusted()
    }

    /// 按快捷键设置、授权与访达是否在前台决定是否拦截。设置页改了快捷键也调用它。
    func refresh() {
        let front = NSWorkspace.shared.frontmostApplication
        let finderFront = front?.bundleIdentifier == Self.finderBundleId
        let shortcuts = SharedConfig.shared.shortcuts
        let cut = shortcuts[FinderCutPasteTakeover.cutActionId]
        let paste = shortcuts[FinderCutPasteTakeover.pasteActionId]
        let want = finderFront && (cut != nil || paste != nil) && AXIsProcessTrusted()
        if want, let front {
            updateFinder(pid: front.processIdentifier)
            if tap == nil { createTap() }
        }
        let chords = (cut: cut.flatMap(Self.chord(for:)), paste: paste.flatMap(Self.chord(for:)),
                      copy: Self.chord(for: FinderCutPasteTakeover.copyShortcut))
        let chordsChanged = locked { () -> Bool in
            let changed = cutChord != chords.cut || pasteChord != chords.paste || copyChord != chords.copy
            finderIsFrontmost = finderFront
            tapShouldBeEnabled = want && tap != nil
            cutChord = chords.cut
            pasteChord = chords.paste
            copyChord = chords.copy
            return changed
        }
        if chordsChanged {
            func describe(_ chord: FinderCutPasteTakeover.KeyChord?) -> String {
                chord.map { "\($0.keyCode)/\($0.modifiers)" } ?? "无"
            }
            ServicesProvider.trace("takeover: 键码 cut=\(describe(chords.cut)) paste=\(describe(chords.paste)) copy=\(describe(chords.copy))")
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: want) }
    }

    /// 访达重启后 pid 会变，辅助功能对象要重建
    private func updateFinder(pid: pid_t) {
        locked {
            guard pid != finderPid || finderApp == nil else { return }
            let app = AXUIElementCreateApplication(pid)
            // 回调里同步查焦点：设上限，访达无响应时宁可放行也不卡住全局按键
            AXUIElementSetMessagingTimeout(app, 0.2)
            finderPid = pid
            finderApp = app
        }
    }

    private func createTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                FinderCutPasteInterceptor.shared.handle(type: type, event: event)
            },
            userInfo: nil
        ) else {
            ServicesProvider.trace("takeover: 无法创建按键拦截（辅助功能未授权？）")
            return
        }
        CGEvent.tapEnable(tap: port, enable: false)
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "com.finderright.app.cutpaste.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ServicesProvider.trace("takeover: 按键拦截已创建")
    }

    // MARK: - 拦截回调（拦截线程）

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // 系统因回调超时停用了拦截：仍应启用时立即恢复
            let (port, should) = locked { (tap, tapShouldBeEnabled) }
            if should, let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let (cut, paste, copy) = locked { (cutChord, pasteChord, copyChord) }
        let command = FinderCutPasteTakeover.command(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            modifierFlags: event.flags.rawValue,
            cut: cut, paste: paste, copy: copy)
        guard let command else { return Unmanaged.passUnretained(event) }

        let (pid, app, finderFront) = locked { (finderPid, finderApp, finderIsFrontmost) }
        // 前台切换通知有延迟：目标进程已知且不是访达时一律放行
        let target = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        guard finderFront, let app, target == 0 || target == pid else {
            ServicesProvider.trace("takeover key: \(command) 放行（访达不在前台 front=\(finderFront) target=\(target) finder=\(pid)）")
            return Unmanaged.passUnretained(event)
        }

        let focusIsText = focusIsTextInput(app)
        let pasteboardIsCutMirror = command == .paste && isPasteboardCutMirror()
        let decision = FinderCutPasteTakeover.decide(
            command, focusIsText: focusIsText, pasteboardIsCutMirror: pasteboardIsCutMirror)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        ServicesProvider.trace("takeover key: \(command) decision=\(decision) text=\(focusIsText) mirror=\(pasteboardIsCutMirror) repeat=\(isRepeat)")

        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .copyThenCancelCut:
            if !isRepeat { scheduleCancelCutIfPasteboardReplaced() }
            return Unmanaged.passUnretained(event)
        case .cut:
            // 按住不放的重复按键也要吞掉，否则会落到访达手里（⌘V 会变成普通粘贴）
            if !isRepeat { workQueue.async { self.performCut() } }
            return nil
        case .paste:
            if !isRepeat { workQueue.async { self.performPaste() } }
            return nil
        }
    }

    /// 取不到焦点时按「在文字输入里」处理：宁可放行，也不在重命名时误移文件
    private func focusIsTextInput(_ app: AXUIElement) -> Bool {
        guard let focused = copyAttribute(app, kAXFocusedUIElementAttribute) else { return true }
        let element = focused as! AXUIElement
        return FinderCutPasteTakeover.isTextInput(
            role: copyAttribute(element, kAXRoleAttribute) as? String,
            subrole: copyAttribute(element, kAXSubroleAttribute) as? String)
    }

    private func isPasteboardCutMirror() -> Bool {
        let current = NSPasteboard.general.changeCount
        guard locked({ mirror.matches(currentChangeCount: current) }) else { return false }
        return !cutQueue.read().isEmpty
    }

    // MARK: - 动作（工作队列）

    private func performCut() {
        guard locked({ finderIsFrontmost }) else { return }
        let pasteboard = NSPasteboard.general
        let before = pasteboard.changeCount
        // 没有选中项时「拷贝」不可用，剪切键就什么也不做（与访达原生 ⌘X 一致）
        guard pressFinderEditItem(Self.copyItem) else {
            ServicesProvider.trace("takeover cut: 拷贝不可用")
            return
        }
        guard waitForPasteboardChange(from: before) else {
            ServicesProvider.trace("takeover cut: 剪贴板未变化")
            return
        }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else { return }
        // 写入剪切队列后由 cutFiles 调回 mirrorCutQueue 把整个队列放进剪贴板，并通知扩展打角标
        let response = service.handle(IPCRequest(
            id: UUID().uuidString,
            action: "cutFiles",
            payload: ["paths": .stringArray(urls.map(\.path))]))
        ServicesProvider.trace("takeover cut: items=\(urls.count) success=\(response.success)")
    }

    private func performPaste() {
        guard locked({ finderIsFrontmost }) else { return }
        // 访达把移动目标定为当前窗口所在目录，冲突、进度与撤销都由访达处理
        guard pressFinderEditItem(Self.moveHereItem) else {
            ServicesProvider.trace("takeover paste: 将项目移到这里不可用")
            return
        }
        locked { mirror.reset() }
        // 文件已交给访达移动：清空剪切队列与角标
        let response = service.handle(IPCRequest(id: UUID().uuidString, action: "cancelCut", payload: [:]))
        ServicesProvider.trace("takeover paste: success=\(response.success)")
    }

    /// ⌘C 放行给访达；稍后剪贴板若已不是剪切镜像（复制了别的），按 Windows 习惯取消剪切
    private func scheduleCancelCutIfPasteboardReplaced() {
        let before = NSPasteboard.general.changeCount
        guard locked({ mirror.matches(currentChangeCount: before) }) else { return }
        workQueue.asyncAfter(deadline: .now() + 0.5) {
            let current = NSPasteboard.general.changeCount
            guard current != before, self.locked({ self.mirror.matches(currentChangeCount: before) }) else { return }
            self.locked { self.mirror.reset() }
            _ = self.service.handle(IPCRequest(id: UUID().uuidString, action: "cancelCut", payload: [:]))
            ServicesProvider.trace("takeover copy: 剪贴板已替换，取消剪切")
        }
    }

    private func waitForPasteboardChange(from changeCount: Int) -> Bool {
        for _ in 0..<50 {
            if NSPasteboard.general.changeCount != changeCount { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    // MARK: - 剪贴板镜像

    /// 剪切队列更新后调用（任何来源：剪切键、右键、服务）：把整个队列放进剪贴板，
    /// 这样粘贴键交给访达移动时，移动的正是带角标的这些文件。
    func mirrorCutQueue(_ paths: [String]) {
        guard !paths.isEmpty, isActive else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(paths.map { NSURL(fileURLWithPath: $0) }) else { return }
        let changeCount = pasteboard.changeCount
        locked { mirror.record(changeCount: changeCount) }
    }

    // MARK: - 键码换算（主线程）

    /// 录制的快捷键 → 当前键盘布局下的键码。TIS / UCKeyTranslate 只在主线程调用。
    private static func chord(for shortcut: ActionShortcut) -> FinderCutPasteTakeover.KeyChord? {
        let character = shortcut.key.lowercased()
        guard let keyCode = FinderCutPasteTakeover.functionKeyCode(for: character) ?? keyCode(for: character) else {
            ServicesProvider.trace("takeover: 当前键盘布局里找不到按键「\(character)」")
            return nil
        }
        return FinderCutPasteTakeover.KeyChord(keyCode: keyCode, modifiers: shortcut.modifiers)
    }

    /// 逐个键码翻译（不带修饰键），找出产生该字符的键。与录制时 charactersIgnoringModifiers 的结果对应。
    /// 用键盘布局而不是当前输入法：中文输入法下取到的是其底层的 ABC 等布局。
    private static func keyCode(for character: String) -> Int? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> Int? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length > 0,
                   String(utf16CodeUnits: chars, count: length).lowercased() == character {
                    return code
                }
            }
            return nil
        }
    }

    // MARK: - 访达菜单

    /// 点击访达「编辑」菜单里指定快捷键的项。不可用时返回 false（点不可用的项 AXPress 也报成功，但不生效）。
    private func pressFinderEditItem(_ item: (char: String, modifiers: Int)) -> Bool {
        guard let app = locked({ finderApp }),
              let bar = copyAttribute(app, kAXMenuBarAttribute) else { return false }
        // 菜单栏顺序固定：苹果、访达、文件、编辑。标题本地化，不能按名字找
        let tops = children(bar as! AXUIElement)
        guard tops.count > 3, let menu = children(tops[3]).first else { return false }
        let target = children(menu).first {
            copyAttribute($0, kAXMenuItemCmdCharAttribute) as? String == item.char
                && (copyAttribute($0, kAXMenuItemCmdModifiersAttribute) as? Int) == item.modifiers
        }
        guard let target, copyAttribute(target, kAXEnabledAttribute) as? Bool == true else { return false }
        return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
