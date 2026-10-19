import AppKit
import ApplicationServices
import Carbon
import FinderRightKit

/// 在访达里处理设置页的所有快捷键（需「辅助功能」权限）。决策规则见 Kit 的 FinderKeyTakeover。
/// 剪切 / 粘贴默认 ⌘X / ⌘V，可改，清空即停用；切换隐藏文件、打开路径直接执行；
/// 其他行点访达「服务」子菜单里的 FinderRight 项（没有选中项时按键交还访达）。
/// 未授权时剪切 / 粘贴不可用，其他行回退为系统服务快捷键（ServiceShortcutSync 一直在同步）。
///
/// - 只在访达处于前台时启用按键拦截：看不到其他 App 的按键，本 App 卡顿也不会拖慢别处打字。
/// - 拦截跑在独立线程的 run loop 上，回调里只比较键码、查一次焦点；
///   点菜单、等剪贴板、写剪切队列都放到工作队列。
/// - 回调里绝不把按键翻译成字符：输入法接口只许在主线程调用。快捷键在主线程预先换算成键码。
/// - 不发合成按键：直接用辅助功能点访达菜单，不受键盘布局影响，也不会被自己再拦一次。
final class FinderShortcutInterceptor {

    static let shared = FinderShortcutInterceptor()

    private static let finderBundleId = "com.apple.finder"
    /// 访达「编辑」菜单项按快捷键识别（标题随选中项变化，如「拷贝“a.txt”」）。
    /// AXMenuItemCmdModifiers：0 = 仅 ⌘，2 = ⌥⌘
    private static let copyItem = (char: "C", modifiers: 0)
    private static let moveHereItem = (char: "V", modifiers: 2)

    private let service = FinderRightService()
    private let workQueue = DispatchQueue(label: "com.finderright.app.shortcut.takeover", qos: .userInteractive)
    private let cutQueue = CutQueueStore()

    /// 以下状态跨拦截线程、工作队列与主线程访问，统一由 lock 保护
    private let lock = NSLock()
    private var mirror = CutPasteboardMirror()
    private var finderPid: pid_t = 0
    private var finderApp: AXUIElement?
    private var finderIsFrontmost = false
    private var tapShouldBeEnabled = false
    /// 各行快捷键换算出的键码，键为设置页 action ID
    private var chords: [String: FinderKeyTakeover.KeyChord] = [:]
    private var copyChord: FinderKeyTakeover.KeyChord?

    /// 只在主线程创建与开关
    private var tap: CFMachPort?
    /// 打开「打开路径」输入框（AppDelegate 提供），只在主线程调用
    private var showDirectoryPrompt: (() -> Void)?

    private init() {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - 生命周期（主线程）

    func start(showDirectoryPrompt: @escaping () -> Void) {
        self.showDirectoryPrompt = showDirectoryPrompt
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

    /// 每行补过默认快捷键的 action ID（规则见 FinderKeyTakeover.defaultsToApply）
    private static let appliedDefaultsKey = "appliedDefaultShortcutIds"
    /// 1.6.4 的总标记，只用来换算成按行记录
    private static let legacyAppliedKey = "cutPasteNativeShortcutsApplied"

    /// 启动时补上默认快捷键：每行只补一次、只填空位，用户的快捷键升级后保持不变，清空的行也不会被补回
    static func applyDefaultShortcutsIfNeeded() {
        let defaults = UserDefaults.standard
        let applied = Set(defaults.stringArray(forKey: appliedDefaultsKey) ?? [])
            .union(FinderKeyTakeover.legacyAppliedActionIds(cutPasteApplied: defaults.bool(forKey: legacyAppliedKey)))
        let config = SharedConfig.shared
        let toApply = FinderKeyTakeover.defaultsToApply(current: config.shortcuts, alreadyApplied: applied)
        for (actionId, shortcut) in toApply {
            config.setShortcut(shortcut, forActionId: actionId)
        }
        markDefaultsApplied(applied)
        if !toApply.isEmpty {
            ServicesProvider.trace("takeover: 补上默认快捷键 \(toApply.keys.sorted())")
        }
    }

    /// 恢复默认快捷键：全部换成默认值，没有默认值的行清空
    static func restoreDefaultShortcuts() {
        SharedConfig.shared.shortcuts = FinderKeyTakeover.defaultShortcuts
        markDefaultsApplied([])
    }

    private static func markDefaultsApplied(_ applied: Set<String>) {
        let all = applied.union(FinderKeyTakeover.defaultShortcuts.keys)
        UserDefaults.standard.set(all.sorted(), forKey: appliedDefaultsKey)
    }

    /// 至少设了一个剪切 / 粘贴快捷键且已授权：剪切时才把队列镜像到剪贴板
    var isActive: Bool {
        let shortcuts = SharedConfig.shared.shortcuts
        let hasShortcut = shortcuts[FinderKeyTakeover.cutActionId] != nil
            || shortcuts[FinderKeyTakeover.pasteActionId] != nil
        return hasShortcut && AXIsProcessTrusted()
    }

    /// 按快捷键设置、授权与访达是否在前台决定是否拦截。设置页改了快捷键也调用它。
    func refresh() {
        let front = NSWorkspace.shared.frontmostApplication
        let finderFront = front?.bundleIdentifier == Self.finderBundleId
        var newChords: [String: FinderKeyTakeover.KeyChord] = [:]
        for (actionId, shortcut) in SharedConfig.shared.shortcuts where Self.canHandle(actionId) {
            newChords[actionId] = Self.chord(for: shortcut)
        }
        let newCopy = Self.chord(for: FinderKeyTakeover.copyShortcut)
        let want = finderFront && !newChords.isEmpty && AXIsProcessTrusted()
        if want, let front {
            updateFinder(pid: front.processIdentifier)
            if tap == nil { createTap() }
        }
        let chordsChanged = locked { () -> Bool in
            let changed = chords != newChords || copyChord != newCopy
            finderIsFrontmost = finderFront
            tapShouldBeEnabled = want && tap != nil
            chords = newChords
            copyChord = newCopy
            return changed
        }
        if chordsChanged {
            let described = newChords.sorted { $0.key < $1.key }
                .map { "\($0.key.replacingOccurrences(of: "shortcut.", with: ""))=\($0.value.keyCode)/\($0.value.modifiers)" }
                .joined(separator: " ")
            ServicesProvider.trace("takeover: 键码 \(described) copy=\(newCopy.map { "\($0.keyCode)/\($0.modifiers)" } ?? "无")")
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: want) }
    }

    /// 拦截能执行的动作：剪切、粘贴、切换隐藏文件，以及有对应系统服务的动作
    private static func canHandle(_ actionId: String) -> Bool {
        FinderKeyTakeover.handlesAction(actionId)
            || actionId == FinderKeyTakeover.toggleHiddenActionId
            || ServiceShortcuts.hasService(actionId: actionId)
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
                FinderShortcutInterceptor.shared.handle(type: type, event: event)
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
        thread.name = "com.finderright.app.shortcut.tap"
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

        // 局部变量别与属性同名：旧版编译器（CI 的 Xcode 16）会把闭包里的 chords 当成正在声明的局部变量
        let (currentChords, copy) = locked { (self.chords, self.copyChord) }
        let command = FinderKeyTakeover.command(
            keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
            modifierFlags: event.flags.rawValue,
            chords: currentChords, copy: copy)
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
        // 只有撤销键才读访达撤销项：与操作完成时记下的样子相同，说明之后访达没做过可撤销的操作
        var undoNote = ""
        var undo = UndoShortcutDecision.passThrough
        if command == .undo {
            let snapshot = FinderUndoMenu.snapshot(app: app)
            undo = UndoCenter.shared.shortcutDecision(finderSnapshot: snapshot)
            undoNote = " undo=\(undo) finder=\(snapshot.map { "\($0.title)/\($0.enabled)" } ?? "nil")"
        }
        let decision = FinderKeyTakeover.decide(
            command, focusIsText: focusIsText, pasteboardIsCutMirror: pasteboardIsCutMirror, undo: undo)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        ServicesProvider.trace("takeover key: \(command) decision=\(decision) text=\(focusIsText) mirror=\(pasteboardIsCutMirror) repeat=\(isRepeat)\(undoNote)")

        switch decision {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .undo:
            if !isRepeat {
                workQueue.async {
                    let response = self.service.handle(IPCRequest(id: UUID().uuidString, action: "undoLast", payload: [:]))
                    ServicesProvider.trace("takeover undo: success=\(response.success)")
                }
            }
            return nil
        case .swallow:
            // 撤销进行中：不重复执行，也不能落到访达手里撤销别的东西
            return nil
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
        case .runAction(let actionId):
            if let titles = Self.serviceTitles[actionId] {
                // 服务行：访达只在有选中项时列出 FinderRight 的服务。不可用就把按键交还访达，
                // 默认组合（如 ⌥⌘C）这时由访达原生功能响应；查找有超时上限（见 updateFinder）
                guard let item = findFinderServiceItem(titles: titles) else {
                    ServicesProvider.trace("takeover action: \(actionId) 服务不可用，交还访达")
                    return Unmanaged.passUnretained(event)
                }
                if !isRepeat { workQueue.async { self.pressServiceItem(item, actionId: actionId) } }
            } else if !isRepeat {
                workQueue.async { self.performAction(actionId) }
            }
            return nil
        }
    }

    /// 取不到焦点时按「在文字输入里」处理：宁可放行，也不在重命名时误移文件
    private func focusIsTextInput(_ app: AXUIElement) -> Bool {
        guard let focused = copyAttribute(app, kAXFocusedUIElementAttribute) else { return true }
        let element = focused as! AXUIElement
        return FinderKeyTakeover.isTextInput(
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
        // 文件已交给访达移动：清空剪切队列与角标。keepUndo：这次移动由访达自己记撤销，
        // FinderRight 的旧撤销记录保持不动（⌘Z 时访达撤销项已变，自然交还访达）
        let response = service.handle(IPCRequest(id: UUID().uuidString, action: "cancelCut", payload: ["keepUndo": .bool(true)]))
        ServicesProvider.trace("takeover paste: success=\(response.success)")
    }

    /// 不经服务的动作：切换隐藏文件、打开路径（两者都不需要选中项）
    private func performAction(_ actionId: String) {
        guard locked({ finderIsFrontmost }) else { return }
        switch actionId {
        case FinderKeyTakeover.toggleHiddenActionId:
            let response = service.handle(IPCRequest(id: UUID().uuidString, action: "toggleHiddenFiles", payload: [:]))
            ServicesProvider.trace("takeover action: toggleHidden success=\(response.success)")
        case FinderKeyTakeover.goToDirectoryActionId:
            DispatchQueue.main.async {
                SharedConfig.shared.reload()
                guard SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.goToDirectory) else {
                    NSSound.beep()
                    return
                }
                self.showDirectoryPrompt?()
            }
            ServicesProvider.trace("takeover action: goToDirectory")
        default:
            break
        }
    }

    /// 有服务的动作：点访达「服务」子菜单里对应的项，访达会像按服务快捷键一样把选中项交给 ServicesProvider
    private func pressServiceItem(_ item: AXUIElement, actionId: String) {
        guard locked({ finderIsFrontmost }) else { return }
        let ok = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
        ServicesProvider.trace("takeover action: \(actionId) 点服务菜单 success=\(ok)")
        if !ok { DispatchQueue.main.async { NSSound.beep() } }
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
    private static func chord(for shortcut: ActionShortcut) -> FinderKeyTakeover.KeyChord? {
        let character = shortcut.key.lowercased()
        guard let keyCode = FinderKeyTakeover.functionKeyCode(for: character) ?? keyCode(for: character) else {
            ServicesProvider.trace("takeover: 当前键盘布局里找不到按键「\(character)」")
            return nil
        }
        return FinderKeyTakeover.KeyChord(keyCode: keyCode, modifiers: shortcut.modifiers)
    }

    /// 逐个键码翻译，找出产生该字符的键。与录制时 charactersIgnoringModifiers 的结果对应：
    /// 它保留 ⇧ 的效果，⇧⌘. 录到的是「>」，所以先按不带修饰键翻译，找不到再按带 ⇧ 翻译。
    /// 用键盘布局而不是当前输入法：中文输入法下取到的是其底层的 ABC 等布局。
    private static func keyCode(for character: String) -> Int? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { buffer -> Int? in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            let shiftState = UInt32((shiftKey >> 8) & 0xFF)
            for modifierState in [0, shiftState] {
                for code in 0..<128 {
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), modifierState,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                                &deadKeyState, chars.count, &length, &chars)
                    if status == noErr, length > 0,
                       String(utf16CodeUnits: chars, count: length).lowercased() == character {
                        return code
                    }
                }
            }
            return nil
        }
    }

    // MARK: - 访达菜单

    /// 各动作在访达「服务」子菜单里可能显示的标题（英文原文 + 本 App 各语言译名）。
    /// 服务标题跟随系统语言，菜单项标识都是 `_processRequest:`，只能按标题认。
    private static let serviceTitles: [String: Set<String>] = {
        let translations = Bundle.main.paths(forResourcesOfType: "lproj", inDirectory: nil).compactMap { lproj in
            NSDictionary(contentsOfFile: (lproj as NSString).appendingPathComponent("ServicesMenu.strings")) as? [String: String]
        }
        var result: [String: Set<String>] = [:]
        // 打开路径只是打开输入框，不需要选中项，直接调用，不走服务
        for binding in ServiceShortcuts.bindings
        where !FinderKeyTakeover.handlesAction(binding.actionId) && binding.actionId != FinderKeyTakeover.goToDirectoryActionId {
            result[binding.actionId] = FinderKeyTakeover.serviceMenuTitles(menuTitle: binding.menuTitle, translations: translations)
        }
        return result
    }()

    /// 找访达「访达」菜单 →「服务」子菜单里标题匹配且可用的项。子菜单不展开也能枚举（实测 2–9ms）。
    /// 无选中项时 FinderRight 的服务不出现，返回 nil。
    private func findFinderServiceItem(titles: Set<String>) -> AXUIElement? {
        guard let app = locked({ finderApp }),
              let bar = copyAttribute(app, kAXMenuBarAttribute) else { return nil }
        // 菜单栏第 2 项是「访达」菜单，其中只有「服务」带子菜单；标题本地化，按子菜单内容找
        let tops = children(bar as! AXUIElement)
        guard tops.count > 1, let appMenu = children(tops[1]).first else { return nil }
        for item in children(appMenu) {
            guard let submenu = children(item).first else { continue }
            let target = children(submenu).first { (copyAttribute($0, kAXTitleAttribute) as? String).map(titles.contains) == true }
            guard let target else { continue }
            return copyAttribute(target, kAXEnabledAttribute) as? Bool == true ? target : nil
        }
        return nil
    }

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
