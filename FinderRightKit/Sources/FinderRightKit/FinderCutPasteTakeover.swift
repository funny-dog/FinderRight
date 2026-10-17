import Foundation

/// 设置页「剪切」「粘贴」快捷键的纯决策逻辑（按键拦截与菜单驱动在主 App 的 FinderCutPasteInterceptor）。
///
/// 这两行不走系统服务快捷键，而是由按键拦截处理：拦截排在访达之前，⌘X / ⌘V、⌃V 等任意组合都能用。
/// 剪切键用辅助功能点访达「拷贝」拿到选中文件，记入剪切队列；粘贴键点访达「将项目移到这里」，
/// 由访达自己移动（空白处可用、支持撤销与冲突处理），目标是当前窗口所在目录。
/// 剪切队列有内容时，剪贴板镜像为整个队列，右键剪切后按粘贴键也能移动。
public enum FinderCutPasteTakeover {

    public static let cutActionId = "shortcut.cut"
    public static let pasteActionId = "shortcut.paste"

    /// 默认与系统一致：⌘X / ⌘V；用户可改成别的组合，清空即停用
    public static let defaultShortcuts: [String: ActionShortcut] = [
        cutActionId: ActionShortcut(key: "x", modifiers: ModifierBits.commandBit),
        pasteActionId: ActionShortcut(key: "v", modifiers: ModifierBits.commandBit),
    ]

    /// 该动作的快捷键由按键拦截处理（不同步为系统服务快捷键）
    public static func handlesAction(_ actionId: String) -> Bool {
        actionId == cutActionId || actionId == pasteActionId
    }

    /// 首次运行本版本时要补上的默认快捷键：只填剪切 / 粘贴里用户还没设置的那一行。
    /// 用户设置过的组合（包括旧版本录的）一律保留，升级不能覆盖用户的选择；
    /// 默认组合若已被其他动作占用也不填，避免两行显示同一组合。
    public static func defaultsToApply(current: [String: ActionShortcut]) -> [String: ActionShortcut] {
        func same(_ a: ActionShortcut, _ b: ActionShortcut) -> Bool {
            a.key.lowercased() == b.key.lowercased()
                && ModifierBits.normalized(a.modifiers) == ModifierBits.normalized(b.modifiers)
        }
        return defaultShortcuts.filter { actionId, shortcut in
            current[actionId] == nil && !current.values.contains { same($0, shortcut) }
        }
    }

    /// 录制时要拦下的冲突。剪切 / 粘贴由拦截抢在访达之前处理，只有系统全局快捷键（截屏、切换 App 等）
    /// 轮不到我们；其他动作走系统服务，访达菜单与文本编辑按键也都会先被访达拿走。
    public static func recordingConflict(for shortcut: ActionShortcut, actionId: String,
                                         textBindings: [FinderReservedShortcuts.BindingKey: String]? = nil) -> FinderReservedShortcuts.Reserved? {
        let conflict = textBindings.map { FinderReservedShortcuts.conflict(for: shortcut, textBindings: $0) }
            ?? FinderReservedShortcuts.conflict(for: shortcut)
        guard let conflict else { return nil }
        return handlesAction(actionId) && !conflict.isSystem ? nil : conflict
    }

    public enum Command: Equatable {
        case cut, copy, paste
    }

    public enum Decision: Equatable {
        /// 原样交给访达
        case passThrough
        /// 吞掉 ⌘X，改为拷贝后记入剪切队列
        case cut
        /// 放行 ⌘C；之后剪贴板若被换掉，取消剪切
        case copyThenCancelCut
        /// 吞掉 ⌘V，改为「将项目移到这里」
        case paste
    }

    /// 按键在当前键盘布局下的物理键码 + 修饰键。
    ///
    /// 拦截回调跑在独立线程，不能在那里把按键翻译成字符：NSEvent.charactersIgnoringModifiers
    /// 遇到 ⌃ 组合会调用输入法接口，而它们只许在主线程调用（实测直接断言崩溃）。
    /// 所以先在主线程把录制的字符换算成键码，回调里只比较键码和修饰键。
    public struct KeyChord: Equatable {
        public let keyCode: Int
        public let modifiers: Int

        public init(keyCode: Int, modifiers: Int) {
            self.keyCode = keyCode
            self.modifiers = ModifierBits.normalized(modifiers)
        }
    }

    /// 访达原生 ⌘C 的字符，用来在剪切后取消剪切
    public static let copyShortcut = ActionShortcut(key: "c", modifiers: ModifierBits.commandBit)

    /// 按换算好的剪切 / 粘贴 / 拷贝键识别按键。修饰键必须完全一致（⌥⌘V 是访达自己的移动，不能当成 ⌘V）。
    public static func command(keyCode: Int, modifierFlags: UInt64,
                               cut: KeyChord?, paste: KeyChord?, copy: KeyChord?) -> Command? {
        let pressed = KeyChord(keyCode: keyCode, modifiers: Int(truncatingIfNeeded: modifierFlags))
        if pressed == cut { return .cut }
        if pressed == paste { return .paste }
        if pressed == copy { return .copy }
        return nil
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

    /// 焦点在文字输入里（重命名、搜索框、路径输入框）时，⌘X / ⌘V 是剪切粘贴文字，必须放行。
    /// 实测：重命名 AXTextField，搜索框 AXTextField + AXSearchField。
    public static func isTextInput(role: String?, subrole: String?) -> Bool {
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
        if let role, textRoles.contains(role) { return true }
        if let subrole, subrole == "AXSearchField" || subrole == "AXSecureTextField" { return true }
        return false
    }

    /// - focusIsText: 焦点在文字输入里；取不到焦点时调用方应传 true，宁可放行也不误移文件
    /// - pasteboardIsCutMirror: 剪切队列非空，且剪贴板仍是剪切时写入的那份
    public static func decide(_ command: Command?, focusIsText: Bool, pasteboardIsCutMirror: Bool) -> Decision {
        guard let command, !focusIsText else { return .passThrough }
        switch command {
        case .cut: return .cut
        case .copy: return .copyThenCancelCut
        case .paste: return pasteboardIsCutMirror ? .paste : .passThrough
        }
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
