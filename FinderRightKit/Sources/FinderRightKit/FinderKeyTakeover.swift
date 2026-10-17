import Foundation

/// 设置页快捷键在访达里的按键拦截：纯决策逻辑（拦截与菜单驱动在主 App 的 FinderShortcutInterceptor）。
///
/// 授权「辅助功能」后，所有行都由按键拦截处理：拦截排在访达之前，任意组合（含 ⌘X / ⌘V、⌃V）都能用，
/// 改键立即生效，不用重启访达。
/// - 剪切：用辅助功能点访达「拷贝」拿到选中文件，记入剪切队列；
/// - 粘贴：点访达「将项目移到这里」，由访达自己移动（空白处可用、支持撤销），目标是当前窗口所在目录；
/// - 其他有系统服务的动作：点访达「服务」子菜单里对应的 FinderRight 项，访达把选中项交给服务（仍需选中项）；
/// - 切换隐藏文件：直接执行。
/// 未授权时剪切 / 粘贴不可用，其他动作回退为系统服务快捷键（见 ServiceShortcuts.syncsShortcut）。
public enum FinderKeyTakeover {

    public static let cutActionId = "shortcut.cut"
    public static let pasteActionId = "shortcut.paste"
    public static let toggleHiddenActionId = "shortcut.toggleHidden"
    public static let copyPathActionId = "shortcut.copyPath"
    public static let goToDirectoryActionId = "shortcut.goToDirectory"

    public enum Command: Equatable {
        case cut, copy, paste
        /// 其他动作（服务或切换隐藏文件），关联设置页 action ID
        case action(String)
    }

    public enum Decision: Equatable {
        /// 原样交给访达
        case passThrough
        /// 吞掉剪切键，改为拷贝后记入剪切队列
        case cut
        /// 放行 ⌘C；之后剪贴板若被换掉，取消剪切
        case copyThenCancelCut
        /// 吞掉粘贴键，改为「将项目移到这里」
        case paste
        /// 吞掉按键，执行该动作
        case runAction(String)
    }

    /// 默认快捷键与访达原生一致；用户可改成别的组合，清空即停用。
    /// 未授权「辅助功能」时这些组合照旧由访达自己响应，效果相同。
    /// 打开路径不设默认：⇧⌘G 会把访达自带的「前往文件夹」换成 FinderRight 的输入框，改变用户已有习惯。
    public static let defaultShortcuts: [String: ActionShortcut] = {
        let cmd = ModifierBits.commandBit, opt = ModifierBits.optionBit, sft = ModifierBits.shiftBit
        return [
            cutActionId: ActionShortcut(key: "x", modifiers: cmd),
            pasteActionId: ActionShortcut(key: "v", modifiers: cmd),
            copyPathActionId: ActionShortcut(key: "c", modifiers: cmd | opt),        // 访达「拷贝路径名」
            toggleHiddenActionId: ActionShortcut(key: ".", modifiers: cmd | sft),    // 访达「显示隐藏文件」
        ]
    }()

    /// 只能由按键拦截处理的动作（没有可用的服务快捷键回退）。剪切 / 粘贴的服务版本需要选中项、
    /// 粘贴还进选中文件夹，与访达原生行为不一致，所以这两行不同步为服务快捷键。
    public static func handlesAction(_ actionId: String) -> Bool {
        actionId == cutActionId || actionId == pasteActionId
    }

    /// 启动时要补上的默认快捷键。每行的默认值只补一次（alreadyApplied 记录补过的行），且只填空位：
    /// - 用户设置过的组合（包括旧版本录的）一律保留，升级不能覆盖用户的选择；
    /// - 补过之后用户清空就是停用，以后的版本也不再补回；
    /// - 新版本新增的默认值只补给还没设置的行；默认组合若已被其他行占用也不填，避免两行显示同一组合。
    /// 调用方补完后应把 defaultShortcuts 的所有行记为已补。
    public static func defaultsToApply(current: [String: ActionShortcut],
                                       alreadyApplied: Set<String>) -> [String: ActionShortcut] {
        defaultShortcuts.filter { actionId, shortcut in
            !alreadyApplied.contains(actionId)
                && current[actionId] == nil
                && !current.values.contains { sameShortcut($0, shortcut) }
        }
    }

    /// 旧版本（1.6.4）只记一个「剪切 / 粘贴已补」的总标记，换算成按行记录
    public static func legacyAppliedActionIds(cutPasteApplied: Bool) -> Set<String> {
        cutPasteApplied ? [cutActionId, pasteActionId] : []
    }

    static func sameShortcut(_ a: ActionShortcut, _ b: ActionShortcut) -> Bool {
        a.key.lowercased() == b.key.lowercased()
            && ModifierBits.normalized(a.modifiers) == ModifierBits.normalized(b.modifiers)
    }

    /// 录制时要拦下的冲突。
    /// - 按键拦截可用（已授权）：拦截抢在访达之前，只有系统全局快捷键（截屏、切换 App 等）轮不到；
    /// - 未授权：剪切 / 粘贴同上（授权后才生效，由页面顶部提示）；其他动作回退为服务快捷键，
    ///   访达菜单与文本编辑按键都会先被访达拿走，照旧拦截。
    public static func recordingConflict(for shortcut: ActionShortcut, actionId: String,
                                         interceptorAvailable: Bool,
                                         textBindings: [FinderReservedShortcuts.BindingKey: String]? = nil) -> FinderReservedShortcuts.Reserved? {
        let conflict = textBindings.map { FinderReservedShortcuts.conflict(for: shortcut, textBindings: $0) }
            ?? FinderReservedShortcuts.conflict(for: shortcut)
        guard let conflict else { return nil }
        if conflict.isSystem { return conflict }
        return interceptorAvailable || handlesAction(actionId) ? nil : conflict
    }

    /// 按键在当前键盘布局下的物理键码 + 修饰键。
    ///
    /// 拦截回调跑在独立线程，不能在那里把按键翻译成字符：NSEvent.charactersIgnoringModifiers
    /// 遇到 ⌃ 组合会调用输入法接口，而它们只许在主线程调用（实测直接断言崩溃）。
    /// 所以先在主线程把录制的字符换算成键码，回调里只比较键码和修饰键。
    public struct KeyChord: Hashable {
        public let keyCode: Int
        public let modifiers: Int

        public init(keyCode: Int, modifiers: Int) {
            self.keyCode = keyCode
            self.modifiers = ModifierBits.normalized(modifiers)
        }
    }

    /// 访达原生 ⌘C 的字符，用来在剪切后取消剪切
    public static let copyShortcut = ActionShortcut(key: "c", modifiers: ModifierBits.commandBit)

    /// 按换算好的各行快捷键（键为 action ID）与 ⌘C 识别按键。修饰键必须完全一致
    /// （⌥⌘V 是访达自己的移动，不能当成 ⌘V）。设置页保证各行快捷键互不重复。
    public static func command(keyCode: Int, modifierFlags: UInt64,
                               chords: [String: KeyChord], copy: KeyChord?) -> Command? {
        let pressed = KeyChord(keyCode: keyCode, modifiers: Int(truncatingIfNeeded: modifierFlags))
        if let actionId = chords.first(where: { $0.value == pressed })?.key {
            switch actionId {
            case cutActionId: return .cut
            case pasteActionId: return .paste
            default: return .action(actionId)
            }
        }
        return pressed == copy ? .copy : nil
    }

    /// 功能键与方向键：录制时得到的是 NSEvent 私有区字符，键盘布局换算不出来，按固定键码处理
    public static func functionKeyCode(for character: String) -> Int? {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return nil }
        let table: [UInt32: Int] = [
            0xF700: 126, 0xF701: 125, 0xF702: 123, 0xF703: 124,             // ↑ ↓ ← →
            0xF704: 122, 0xF705: 120, 0xF706: 99, 0xF707: 118,               // F1–F4
            0xF708: 96, 0xF709: 97, 0xF70A: 98, 0xF70B: 100,                 // F5–F8
            0xF70C: 101, 0xF70D: 109, 0xF70E: 103, 0xF70F: 111,              // F9–F12
        ]
        return table[scalar.value]
    }

    /// 焦点在文字输入里（重命名、搜索框、路径输入框）时，快捷键是编辑文字用的，必须放行。
    /// 实测：重命名 AXTextField，搜索框 AXTextField + AXSearchField。
    public static func isTextInput(role: String?, subrole: String?) -> Bool {
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if let role, textRoles.contains(role) { return true }
        if let subrole, subrole == "AXSearchField" || subrole == "AXSecureTextField" { return true }
        return false
    }

    /// - focusIsText: 焦点在文字输入里；取不到焦点时调用方应传 true，宁可放行也不误操作文件
    /// - pasteboardIsCutMirror: 剪切队列非空，且剪贴板仍是剪切时写入的那份
    public static func decide(_ command: Command?, focusIsText: Bool, pasteboardIsCutMirror: Bool) -> Decision {
        guard let command, !focusIsText else { return .passThrough }
        switch command {
        case .cut: return .cut
        case .copy: return .copyThenCancelCut
        case .paste: return pasteboardIsCutMirror ? .paste : .passThrough
        case .action(let actionId): return .runAction(actionId)
        }
    }

    /// 服务菜单项的候选标题：Info.plist 里的英文原文，加上各语言 ServicesMenu.strings 的译名。
    /// 访达按系统语言显示服务标题，项的 AXIdentifier 都是 `_processRequest:`，只能按标题认。
    public static func serviceMenuTitles(menuTitle: String, translations: [[String: String]]) -> Set<String> {
        var titles: Set<String> = [menuTitle]
        for table in translations {
            if let localized = table[menuTitle] { titles.insert(localized) }
        }
        return titles
    }
}

/// 记录剪切时写入剪贴板的 changeCount，用来判断剪贴板是否还是那份剪切内容。
///
/// 不能比对剪贴板里的路径：访达移动后，剪贴板里的文件引用会自动指向新位置（实测）。
public struct CutPasteboardMirror: Equatable {
    public private(set) var changeCount: Int?

    public init(changeCount: Int? = nil) {
        self.changeCount = changeCount
    }

    public mutating func record(changeCount: Int) {
        self.changeCount = changeCount
    }

    public mutating func reset() {
        changeCount = nil
    }

    public func matches(currentChangeCount: Int) -> Bool {
        changeCount == currentChangeCount
    }
}
