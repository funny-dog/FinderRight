import Foundation

/// 在访达中接管 ⌘X / ⌘V 的纯决策逻辑（按键拦截与菜单驱动在主 App 的 FinderCutPasteInterceptor）。
///
/// 做法：⌘X 用辅助功能点访达「拷贝」拿到选中文件，记入剪切队列；⌘V 点访达「将项目移到这里」，
/// 由访达自己移动（空白处可用、支持撤销与冲突处理），目标是当前窗口所在目录。
/// 剪切队列有内容时，剪贴板镜像为整个队列，右键剪切后按 ⌘V 也能移动。
public enum FinderCutPasteTakeover {

    /// UserDefaults 开关，默认关闭
    public static let enabledKey = "finderCutPasteTakeover"

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

    /// 设置页「剪切」「粘贴」两行对应的接管按键。系统服务绑不了这两个键，录到时引导用户改用开关。
    public static func takeoverShortcut(forActionId actionId: String) -> ActionShortcut? {
        switch actionId {
        case "shortcut.cut": return ActionShortcut(key: "x", modifiers: ModifierBits.commandBit)
        case "shortcut.paste": return ActionShortcut(key: "v", modifiers: ModifierBits.commandBit)
        default: return nil
        }
    }

    public static func isTakeoverShortcut(_ shortcut: ActionShortcut, forActionId actionId: String) -> Bool {
        guard let expected = takeoverShortcut(forActionId: actionId) else { return false }
        return shortcut.key.lowercased() == expected.key && ModifierBits.normalized(shortcut.modifiers) == expected.modifiers
    }

    /// 只认纯 ⌘ 加 X / C / V。带 ⇧⌥⌃ 的组合（如 ⌥⌘V、⌥⌘C）是访达自己的功能，不碰。
    /// `characters` 取 charactersIgnoringModifiers，按当前键盘布局的字符判断，不按物理键码。
    public static func command(characters: String?, modifierFlags: UInt64) -> Command? {
        let flags = Int(truncatingIfNeeded: modifierFlags)
        let mask = ModifierBits.commandBit | ModifierBits.shiftBit | ModifierBits.optionBit | ModifierBits.controlBit
        guard flags & mask == ModifierBits.commandBit else { return nil }
        switch characters?.lowercased() {
        case "x": return .cut
        case "c": return .copy
        case "v": return .paste
        default: return nil
        }
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
