import Foundation
import CoreFoundation

/// 把设置页录制的快捷键同步为 macOS「服务」快捷键 —— 让快捷键在访达里选中文件后直接生效，无需展开右键菜单。
///
/// ## 为什么不能只靠右键菜单的 keyEquivalent
/// FinderSync 扩展的菜单只在右键展开那一刻存在；菜单收起后扩展进程收不到任何按键。
/// 系统「服务」快捷键则由 AppKit 在访达进程内匹配：访达把当前选中项写入剪贴板、派发给主 App 的
/// Service 处理器（`ServicesProvider`），与右键菜单是否展开无关。
///
/// ## 存储格式（实测）
/// `~/Library/Preferences/pbs.plist` → `NSServicesStatus` 字典，
/// 键为 `"<bundleId> - <Info.plist 里 NSMenuItem.default 原文> - <NSMessage>"`，
/// 值里的 `key_equivalent` 为修饰符前缀 + 小写字符：`@`=⌘ `~`=⌥ `^`=⌃ `$`=⇧，如 `"@~^p"`。
/// 写入后新启动的 App 立即读到；已运行的 App（访达）须重启才会重新读取。
///
/// ## 优先级
/// 访达自身菜单栏的快捷键优先于服务快捷键，被访达占用的组合永远轮不到服务，
/// 因此录制时用 `FinderReservedShortcuts` 拦截。授权「辅助功能」后所有行改由按键拦截处理
/// （FinderKeyTakeover），服务快捷键只是未授权时的回退；剪切 / 粘贴没有回退，见 `syncsShortcut`。
public enum ServiceShortcuts {

    /// 设置页 action ID 与 Info.plist 中某个 NSServices 条目的对应关系
    public struct Binding: Equatable {
        public let actionId: String
        /// Info.plist 里 `NSMenuItem.default` 的原文（英文），pbs 以它拼键，不受界面语言影响
        public let menuTitle: String
        /// Info.plist 里的 `NSMessage`
        public let message: String
    }

    /// 能同步为服务快捷键的动作。「切换隐藏文件」没有对应服务，只在右键菜单里生效。
    /// 标题 / 消息名必须与 FinderRight/Info.plist 完全一致（单测会逐条核对）。
    public static let bindings: [Binding] = [
        Binding(actionId: "shortcut.newFile",         menuTitle: "FinderRight: New File in This Folder…", message: "newFile"),
        Binding(actionId: "shortcut.copyPath",        menuTitle: "FinderRight: Copy Path",                message: "copyPath"),
        Binding(actionId: "shortcut.copyFileName",    menuTitle: "FinderRight: Copy File Name",           message: "copyFileName"),
        Binding(actionId: "shortcut.copyFileContent", menuTitle: "FinderRight: Copy File Content",        message: "copyFileContent"),
        Binding(actionId: "shortcut.goToDirectory",   menuTitle: "FinderRight: Go to Folder…",            message: "goToDirectory"),
        Binding(actionId: "shortcut.openTerminal",    menuTitle: "FinderRight: Open in Terminal",         message: "openTerminal"),
        Binding(actionId: "shortcut.openEditor",      menuTitle: "FinderRight: Open in Editor",           message: "openEditor"),
        Binding(actionId: "shortcut.cut",             menuTitle: "FinderRight: Cut",                      message: "cutFiles"),
        Binding(actionId: "shortcut.paste",           menuTitle: "FinderRight: Paste into This Folder",   message: "pasteFiles"),
        Binding(actionId: "shortcut.compress",        menuTitle: "FinderRight: Compress to ZIP",          message: "compressZip"),
        Binding(actionId: "shortcut.decompress",      menuTitle: "FinderRight: Extract Here",             message: "decompress"),
    ]

    public static let pbsDomain = "pbs"
    static let statusKey = "NSServicesStatus"
    static let shortcutsPresentKey = "ServicesShortcutsPresent"
    static let keyEquivalentKey = "key_equivalent"

    /// 该动作是否有对应的系统服务（可脱离右键菜单直接按键触发）
    public static func hasService(actionId: String) -> Bool {
        bindings.contains { $0.actionId == actionId }
    }

    /// 该动作的快捷键是否同步为服务快捷键（未授权「辅助功能」时的回退）。授权后按键拦截先拿到按键并吞掉，
    /// 服务快捷键不会再触发，所以一直同步也不会重复执行。
    /// 剪切 / 粘贴只由按键拦截处理（FinderKeyTakeover），不写入：服务版本的行为与访达原生不一致。
    public static func syncsShortcut(actionId: String) -> Bool {
        hasService(actionId: actionId) && !FinderKeyTakeover.handlesAction(actionId)
    }

    /// pbs.plist 中 NSServicesStatus 的条目键
    public static func statusEntryKey(bundleId: String, binding: Binding) -> String {
        "\(bundleId) - \(binding.menuTitle) - \(binding.message)"
    }

    /// ActionShortcut → pbs 的 key_equivalent 字符串（修饰符前缀 + 小写字符）
    public static func keyEquivalent(for shortcut: ActionShortcut) -> String {
        let m = ModifierBits(shortcut.modifiers)
        var s = ""
        if m.command { s += "@" }
        if m.option  { s += "~" }
        if m.control { s += "^" }
        if m.shift   { s += "$" }
        return s + shortcut.key.lowercased()
    }

    /// 合并本 App 的快捷键；指定 showsInServicesMenu 时，同时设置全部声明服务的菜单显示状态。
    /// 未指定显示状态时保留系统设置，也不碰其他 App 的条目。
    /// 与访达 / 系统保留键冲突的快捷键（多为旧版本录入的 ⌘X、⌘V）不写入：它们永远不会触发服务。
    public static func mergedStatus(_ status: [String: Any],
                                    bundleId: String,
                                    shortcuts: [String: ActionShortcut],
                                    services: [[String: Any]] = [],
                                    showsInServicesMenu: Bool? = nil) -> [String: Any] {
        var result = status
        for binding in bindings {
            let key = statusEntryKey(bundleId: bundleId, binding: binding)
            var entry = (result[key] as? [String: Any]) ?? [:]
            if syncsShortcut(actionId: binding.actionId),
               let shortcut = shortcuts[binding.actionId],
               FinderReservedShortcuts.conflict(for: shortcut) == nil {
                entry[keyEquivalentKey] = keyEquivalent(for: shortcut)
            } else {
                entry.removeValue(forKey: keyEquivalentKey)
            }
            result[key] = entry.isEmpty ? nil : entry
        }
        if let enabled = showsInServicesMenu {
            for service in services {
                guard let title = (service["NSMenuItem"] as? [String: String])?["default"],
                      let message = service["NSMessage"] as? String else { continue }
                let key = "\(bundleId) - \(title) - \(message)"
                var entry = (result[key] as? [String: Any]) ?? [:]
                entry["enabled_context_menu"] = enabled
                entry["enabled_services_menu"] = enabled
                var modes = (entry["presentation_modes"] as? [String: Any]) ?? [:]
                modes["ContextMenu"] = enabled
                modes["ServicesMenu"] = enabled
                entry["presentation_modes"] = modes
                result[key] = entry
            }
        }
        return result
    }

    /// 把 shortcuts 写入指定偏好域（默认 pbs）。返回 true 表示内容有变化并已写入。
    /// 仅限非沙箱进程调用（主 App）；沙箱扩展无权写 pbs 域。
    @discardableResult
    public static func sync(shortcuts: [String: ActionShortcut],
                            bundleId: String,
                            services: [[String: Any]] = [],
                            showsInServicesMenu: Bool? = nil,
                            domain: String = pbsDomain) -> Bool {
        let appId = domain as CFString
        CFPreferencesAppSynchronize(appId)
        let current = (CFPreferencesCopyAppValue(statusKey as CFString, appId) as? [String: Any]) ?? [:]
        let merged = mergedStatus(current, bundleId: bundleId, shortcuts: shortcuts,
                                  services: services, showsInServicesMenu: showsInServicesMenu)
        guard !NSDictionary(dictionary: current).isEqual(to: merged) else { return false }

        let value: CFPropertyList? = merged.isEmpty ? nil : merged as CFDictionary
        CFPreferencesSetAppValue(statusKey as CFString, value, appId)
        // 系统设置写入服务快捷键时会同时置位此标记；有任一服务快捷键时保持为 true
        if !shortcuts.isEmpty {
            CFPreferencesSetAppValue(shortcutsPresentKey as CFString, kCFBooleanTrue, appId)
        }
        CFPreferencesAppSynchronize(appId)
        return true
    }

    /// 读取指定偏好域里本 App 各动作当前生效的 key_equivalent（调试 / 单测用）
    public static func storedKeyEquivalents(bundleId: String, domain: String = pbsDomain) -> [String: String] {
        let appId = domain as CFString
        CFPreferencesAppSynchronize(appId)
        let status = (CFPreferencesCopyAppValue(statusKey as CFString, appId) as? [String: Any]) ?? [:]
        var out: [String: String] = [:]
        for binding in bindings {
            let entry = status[statusEntryKey(bundleId: bundleId, binding: binding)] as? [String: Any]
            if let ke = entry?[keyEquivalentKey] as? String { out[binding.actionId] = ke }
        }
        return out
    }
}

/// NSEvent.ModifierFlags 的原始位（Kit 不依赖 AppKit，手写常量）
struct ModifierBits {
    static let shiftBit   = 1 << 17
    static let controlBit = 1 << 18
    static let optionBit  = 1 << 19
    static let commandBit = 1 << 20

    let shift: Bool, control: Bool, option: Bool, command: Bool

    init(_ raw: Int) {
        shift   = raw & Self.shiftBit != 0
        control = raw & Self.controlBit != 0
        option  = raw & Self.optionBit != 0
        command = raw & Self.commandBit != 0
    }

    /// 只保留 ⌘⌥⌃⇧ 四个位，便于比较
    static func normalized(_ raw: Int) -> Int {
        raw & (shiftBit | controlBit | optionBit | commandBit)
    }
}

/// 访达菜单栏、系统全局与文本编辑按键绑定已占用的快捷键。服务快捷键与它们相撞时永远不会被触发
/// （访达 / 系统 / 文件视图先处理），录制时直接拦截并提示换键。
public enum FinderReservedShortcuts {

    public enum Kind: Equatable {
        /// 访达菜单栏快捷键
        case finderMenu
        /// 系统全局快捷键
        case system
        /// AppKit 文本编辑按键绑定（StandardKeyBinding.dict / 用户 DefaultKeyBinding.dict）。
        /// 实测 ⌃V（pageDown:）会被访达文件视图当作翻页吃掉，服务收不到。
        case textEditing
    }

    /// 命中的保留快捷键；`name` 为中文菜单名（界面经 NSLocalizedString 本地化），
    /// textEditing 时为绑定的选择器名（如 "pageDown:"），原样显示
    public struct Reserved: Equatable {
        public let name: String
        public let kind: Kind
        public var isSystem: Bool { kind == .system }
        public init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }
    }

    private static let cmd = ModifierBits.commandBit
    private static let opt = ModifierBits.optionBit
    private static let ctl = ModifierBits.controlBit
    private static let sft = ModifierBits.shiftBit

    // 方向键 / 删除键等在 charactersIgnoringModifiers 里是私有区字符
    private static let up = "\u{F700}", down = "\u{F701}", left = "\u{F702}", right = "\u{F703}"
    private static let backspace = "\u{7F}"

    /// (修饰位, 小写字符, 菜单名, 是否系统全局)
    private static let table: [(Int, String, String, Bool)] = [
        // 文件
        (cmd, "n", "新建访达窗口", false),
        (cmd | sft, "n", "新建文件夹", false),
        (cmd | ctl, "n", "用所选项新建文件夹", false),
        (cmd | opt, "n", "新建智能文件夹", false),
        (cmd, "t", "新建标签页", false),
        (cmd, "o", "打开", false),
        (cmd, "w", "关闭窗口", false),
        (cmd | opt, "w", "关闭全部窗口", false),
        (cmd, "i", "显示简介", false),
        (cmd | opt, "i", "显示检查器", false),
        (cmd | ctl, "i", "显示摘要信息", false),
        (cmd, "d", "创建副本", false),
        (cmd | ctl, "a", "制作替身", false),
        (cmd, "r", "显示原身", false),
        (cmd | ctl, "t", "添加到边栏", false),
        (cmd, "y", "快速查看", false),
        (cmd | opt, "y", "幻灯片显示", false),
        (cmd, "p", "打印", false),
        (cmd, "e", "推出", false),
        (cmd, "f", "查找", false),
        (cmd, backspace, "移到废纸篓", false),
        (cmd | sft, backspace, "清倒废纸篓", false),
        (cmd | opt | sft, backspace, "立即清倒废纸篓", false),
        (cmd | opt, backspace, "立即删除", false),
        // 编辑
        (cmd, "z", "撤销", false),
        (cmd | sft, "z", "重做", false),
        (cmd, "x", "剪切", false),
        (cmd, "c", "拷贝", false),
        (cmd, "v", "粘贴", false),
        (cmd | opt, "v", "将项目移到这里", false),
        (cmd, "a", "全选", false),
        (cmd | opt, "a", "取消全选", false),
        (cmd | opt, "c", "拷贝路径名", false),
        (cmd | sft, ".", "显示隐藏文件", false),
        (cmd | sft, ">", "显示隐藏文件", false),
        (cmd | ctl, " ", "表情与符号", false),
        // 显示
        (cmd, "1", "图标视图", false),
        (cmd, "2", "列表视图", false),
        (cmd, "3", "分栏视图", false),
        (cmd, "4", "画廊视图", false),
        (cmd, "j", "显示视图选项", false),
        (cmd | opt, "p", "显示路径栏", false),
        (cmd, "/", "显示状态栏", false),
        (cmd | opt, "s", "显示边栏", false),
        (cmd | sft, "p", "显示预览", false),
        (cmd | sft, "t", "显示标签页栏", false),
        (cmd | sft, "\\", "显示所有标签页", false),
        (cmd | opt, "t", "隐藏工具栏", false),
        (cmd | ctl, "f", "进入全屏幕", false),
        // 前往
        (cmd, "[", "返回", false),
        (cmd, "]", "前进", false),
        (cmd, up, "上层文件夹", false),
        (cmd, down, "打开所选项", false),
        (cmd | ctl, up, "在新窗口中打开上层文件夹", false),
        (cmd | sft, "f", "最近使用", false),
        (cmd | sft, "o", "文稿", false),
        (cmd | sft, "d", "桌面", false),
        (cmd | opt, "l", "下载", false),
        (cmd | sft, "h", "个人", false),
        (cmd | sft, "c", "电脑", false),
        (cmd | sft, "r", "隔空投送", false),
        (cmd | sft, "k", "网络", false),
        (cmd | sft, "i", "iCloud 云盘", false),
        (cmd | sft, "s", "共享的", false),
        (cmd | sft, "a", "应用程序", false),
        (cmd | sft, "u", "实用工具", false),
        (cmd | sft, "l", "资源库", false),
        (cmd | sft, "g", "前往文件夹", false),
        (cmd, "k", "连接服务器", false),
        // 窗口 / 应用
        (cmd, "m", "最小化", false),
        (cmd, "`", "循环浏览窗口", false),
        (cmd, ",", "设置", false),
        (cmd, "h", "隐藏访达", false),
        (cmd | opt, "h", "隐藏其他", false),
        (cmd | sft, "/", "帮助", false),
        (cmd | sft, "?", "帮助", false),
        // 系统全局
        (cmd, " ", "聚焦搜索", true),
        (cmd | opt, " ", "访达搜索窗口", true),
        (ctl, " ", "切换输入法", true),
        (cmd, "\t", "切换应用", true),
        (cmd, "q", "退出应用", true),
        (cmd | sft, "q", "退出登录", true),
        (cmd | ctl, "q", "锁定屏幕", true),
        (cmd | opt, "\u{1B}", "强制退出", true),
        (cmd | sft, "3", "截屏", true),
        (cmd | sft, "4", "截取所选部分", true),
        (cmd | sft, "5", "截屏与录屏", true),
        (cmd | opt, "d", "隐藏程序坞", true),
        (ctl, up, "调度中心", true),
        (ctl, down, "应用程序窗口", true),
        (ctl, left, "向左移动一个空间", true),
        (ctl, right, "向右移动一个空间", true),
    ]

    /// 若 shortcut 与访达、系统或文本编辑按键绑定冲突，返回冲突项
    public static func conflict(for shortcut: ActionShortcut) -> Reserved? {
        conflict(for: shortcut, textBindings: textBindings)
    }

    /// 可注入按键绑定表的版本（单测用）
    public static func conflict(for shortcut: ActionShortcut, textBindings: [BindingKey: String]) -> Reserved? {
        let mods = ModifierBits.normalized(shortcut.modifiers)
        let key = shortcut.key.lowercased()
        if let hit = table.first(where: { $0.0 == mods && $0.1 == key }) {
            return Reserved(name: hit.2, kind: hit.3 ? .system : .finderMenu)
        }
        if let selector = textBindings[BindingKey(modifiers: mods, key: key)] {
            return Reserved(name: selector, kind: .textEditing)
        }
        return nil
    }

    // MARK: - 文本编辑按键绑定

    public struct BindingKey: Hashable {
        public let modifiers: Int
        public let key: String
        public init(modifiers: Int, key: String) {
            self.modifiers = ModifierBits.normalized(modifiers)
            self.key = key
        }
    }

    /// 解析按键绑定字典的键：修饰符前缀（^⌃ ~⌥ @⌘ $⇧ #小键盘）+ 单个字符；大写字母隐含 ⇧。
    /// 只收录含 ⌘ / ⌥ / ⌃ 的组合（录制要求至少含其一，其余不可能冲突）。
    public static func parseBindingKey(_ raw: String) -> BindingKey? {
        var mods = 0
        var chars = Array(raw)
        while chars.count > 1, let c = chars.first, "^~@$#".contains(c) {
            switch c {
            case "^": mods |= ModifierBits.controlBit
            case "~": mods |= ModifierBits.optionBit
            case "@": mods |= ModifierBits.commandBit
            case "$": mods |= ModifierBits.shiftBit
            default: break
            }
            chars.removeFirst()
        }
        guard chars.count == 1, let ch = chars.first,
              mods & (ModifierBits.controlBit | ModifierBits.optionBit | ModifierBits.commandBit) != 0 else { return nil }
        let s = String(ch)
        if s != s.lowercased() { mods |= ModifierBits.shiftBit }
        return BindingKey(modifiers: mods, key: s.lowercased())
    }

    /// 解析整个按键绑定字典；值为选择器名或选择器数组（取第一个），子字典（多键序列）忽略
    public static func parseBindings(_ dict: [String: Any]) -> [BindingKey: String] {
        var out: [BindingKey: String] = [:]
        for (raw, value) in dict {
            guard let key = parseBindingKey(raw) else { continue }
            if let sel = value as? String { out[key] = sel }
            else if let sels = value as? [String], let first = sels.first { out[key] = first }
        }
        return out
    }

    /// 系统标准绑定 + 用户 ~/Library/KeyBindings/DefaultKeyBinding.dict（后者覆盖前者）。
    /// 进程内只读一次：设置页录制时调用，改了 DefaultKeyBinding.dict 需重开 App 才生效，可以接受。
    private static let textBindings: [BindingKey: String] = {
        let standard = URL(fileURLWithPath: "/System/Library/Frameworks/AppKit.framework/Resources/StandardKeyBinding.dict")
        let user = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/KeyBindings/DefaultKeyBinding.dict")
        var result: [BindingKey: String] = [:]
        for url in [standard, user] {
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
            result.merge(parseBindings(dict)) { _, new in new }
        }
        return result
    }()
}
