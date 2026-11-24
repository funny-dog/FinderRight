import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// 服务快捷键与撤销
enum ShortcutTests {
    static func run() {
        // MARK: - 服务快捷键同步

        let cmdBit = 1 << 20, optBit = 1 << 19, ctlBit = 1 << 18, sftBit = 1 << 17

        runTest("ServiceShortcuts key_equivalent 修饰符前缀与小写字符") {
            try assertEqual(ServiceShortcuts.keyEquivalent(for: ActionShortcut(key: "P", modifiers: cmdBit | optBit | ctlBit)), "@~^p")
            try assertEqual(ServiceShortcuts.keyEquivalent(for: ActionShortcut(key: "x", modifiers: ctlBit | cmdBit | sftBit)), "@^$x")
            try assertEqual(ServiceShortcuts.keyEquivalent(for: ActionShortcut(key: "k", modifiers: ctlBit | optBit)), "~^k")
        }

        runTest("ServiceShortcuts 映射与 Info.plist 的 NSServices 一致") {
            // Tests/FinderRightKitTests/xxx.swift → 仓库根目录
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let plistURL = root.appendingPathComponent("FinderRight/Info.plist")
            let data = try Data(contentsOf: plistURL)
            // Info.plist 含 $(VAR) 占位符，仍是合法 plist
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let services = (plist?["NSServices"] as? [[String: Any]]) ?? []
            let pairs = Set(services.compactMap { svc -> String? in
                guard let title = (svc["NSMenuItem"] as? [String: String])?["default"],
                      let message = svc["NSMessage"] as? String else { return nil }
                return "\(title)|\(message)"
            })
            try assertTrue(!pairs.isEmpty, "应能读到 NSServices")
            for b in ServiceShortcuts.bindings {
                try assertTrue(pairs.contains("\(b.menuTitle)|\(b.message)"), "Info.plist 缺少 \(b.menuTitle) / \(b.message)")
            }
            try assertTrue(!ServiceShortcuts.hasService(actionId: "shortcut.toggleHidden"), "切换隐藏文件没有对应服务")
        }

        runTest("ServiceShortcuts 合并只改本 App 条目的 key_equivalent") {
            let bid = "com.finderright.app"
            let cut = ServiceShortcuts.bindings.first { $0.actionId == "shortcut.cut" }!
            let paste = ServiceShortcuts.bindings.first { $0.actionId == "shortcut.paste" }!
            let cutKey = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: cut)
            let pasteKey = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: paste)
            try assertEqual(cutKey, "com.finderright.app - FinderRight: Cut - cutFiles")

            let existing: [String: Any] = [
                "other.app - Other - doIt": ["key_equivalent": "@~o"],
                cutKey: ["enabled_context_menu": false, "key_equivalent": "@~x"],
                pasteKey: ["key_equivalent": "@~v"],
            ]
            let copyPath = ServiceShortcuts.bindings.first { $0.actionId == "shortcut.copyPath" }!
            let copyPathKey = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: copyPath)
            let merged = ServiceShortcuts.mergedStatus(existing, bundleId: bid, shortcuts: [
                "shortcut.copyPath": ActionShortcut(key: "c", modifiers: cmdBit | ctlBit),
                "shortcut.cut": ActionShortcut(key: "x", modifiers: cmdBit | ctlBit),
            ])
            try assertEqual((merged[copyPathKey] as? [String: Any])?["key_equivalent"] as? String, "@^c")
            let cutEntry = merged[cutKey] as? [String: Any]
            try assertNil(cutEntry?["key_equivalent"], "剪切由按键拦截处理，不写服务快捷键")
            try assertEqual(cutEntry?["enabled_context_menu"] as? Bool, false, "保留用户的启用状态")
            try assertNil(merged[pasteKey], "清除快捷键后空条目应删除")
            try assertEqual((merged["other.app - Other - doIt"] as? [String: String])?["key_equivalent"], "@~o", "不碰其他 App")

            let reserved = ServiceShortcuts.mergedStatus([:], bundleId: bid, shortcuts: [
                "shortcut.paste": ActionShortcut(key: "v", modifiers: cmdBit),
            ])
            try assertNil(reserved[pasteKey], "与访达 ⌘V 冲突的旧快捷键不写入服务")
        }

        runTest("ServiceShortcuts 菜单开关覆盖全部服务并保留其他设置") {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let data = try Data(contentsOf: root.appendingPathComponent("FinderRight/Info.plist"))
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let services = (plist?["NSServices"] as? [[String: Any]]) ?? []
            try assertTrue(services.count > ServiceShortcuts.bindings.count, "开关也应覆盖没有快捷键的服务")
            let bid = "com.finderright.app"
            let binding = ServiceShortcuts.bindings.first { $0.actionId == "shortcut.copyPath" }!
            let key = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: binding)
            let shortcuts = ["shortcut.copyPath": ActionShortcut(key: "c", modifiers: cmdBit | ctlBit)]
            let otherKey = "other.app - Other - doIt"
            let existing: [String: Any] = [
                otherKey: ["enabled_context_menu": true],
                key: ["custom": "keep", "presentation_modes": ["CustomMode": true]],
            ]
            let untouched = ServiceShortcuts.mergedStatus(existing, bundleId: bid, shortcuts: shortcuts,
                                                         services: services)
            try assertNil((untouched[key] as? [String: Any])?["enabled_context_menu"], "未操作开关时不改系统显示偏好")
            var status = existing
            for enabled in [false, true] {
                status = ServiceShortcuts.mergedStatus(status, bundleId: bid, shortcuts: shortcuts,
                                                      services: services, showsInServicesMenu: enabled)
                for service in services {
                    let title = (service["NSMenuItem"] as! [String: String])["default"]!
                    let message = service["NSMessage"] as! String
                    let entry = status["\(bid) - \(title) - \(message)"] as? [String: Any]
                    try assertEqual(entry?["enabled_context_menu"] as? Bool, enabled)
                    try assertEqual(entry?["enabled_services_menu"] as? Bool, enabled)
                    let modes = entry?["presentation_modes"] as? [String: Any]
                    try assertEqual(modes?["ContextMenu"] as? Bool, enabled)
                    try assertEqual(modes?["ServicesMenu"] as? Bool, enabled)
                }
                let entry = status[key] as? [String: Any]
                try assertEqual(entry?["key_equivalent"] as? String, "@^c", "显示开关保留快捷键配置")
                try assertEqual(entry?["custom"] as? String, "keep")
                try assertEqual((entry?["presentation_modes"] as? [String: Any])?["CustomMode"] as? Bool, true)
                try assertEqual(status[otherKey] as? [String: Bool], ["enabled_context_menu": true])
            }
        }

        runTest("ServiceShortcuts 写入偏好域并可读回，无变化时不重复写") {
            // 固定域名 + 用后删文件，避免在 ~/Library/Preferences 堆积测试残留
            let domain = "com.finderright.tests.pbs"
            let clear = {
                CFPreferencesSetAppValue("NSServicesStatus" as CFString, nil, domain as CFString)
                CFPreferencesSetAppValue("ServicesShortcutsPresent" as CFString, nil, domain as CFString)
                CFPreferencesAppSynchronize(domain as CFString)
            }
            clear()
            defer {
                clear()
                let file = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Preferences/\(domain).plist")
                try? FileManager.default.removeItem(at: file)
            }
            let bid = "com.finderright.app"
            let shortcuts = ["shortcut.copyPath": ActionShortcut(key: "c", modifiers: cmdBit | ctlBit | optBit)]
            try assertTrue(ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, domain: domain), "首次写入应有变化")
            try assertEqual(ServiceShortcuts.storedKeyEquivalents(bundleId: bid, domain: domain), ["shortcut.copyPath": "@~^c"])
            try assertTrue(!ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, domain: domain), "相同内容不应重复写")
            try assertTrue(ServiceShortcuts.sync(shortcuts: [:], bundleId: bid, domain: domain))
            try assertEqual(ServiceShortcuts.storedKeyEquivalents(bundleId: bid, domain: domain), [:])
            let services: [[String: Any]] = [["NSMenuItem": ["default": "FinderRight: Copy Path"], "NSMessage": "copyPath"]]
            try assertTrue(ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, services: services,
                                                showsInServicesMenu: false, domain: domain))
            let status = CFPreferencesCopyAppValue("NSServicesStatus" as CFString, domain as CFString) as? [String: Any]
            let key = ServiceShortcuts.statusEntryKey(bundleId: bid, binding: ServiceShortcuts.bindings.first { $0.actionId == "shortcut.copyPath" }!)
            try assertEqual((status?[key] as? [String: Any])?["enabled_services_menu"] as? Bool, false)
            try assertTrue(!ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, services: services,
                                                 showsInServicesMenu: false, domain: domain), "关闭状态不重复写入")
            try assertTrue(ServiceShortcuts.sync(shortcuts: shortcuts, bundleId: bid, services: services,
                                                showsInServicesMenu: true, domain: domain))
        }

        runTest("FinderReservedShortcuts 拦截访达原生 ⌘X / ⌘V，放行带 ⌃ 的组合") {
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "x", modifiers: cmdBit))?.name, "剪切")
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: cmdBit))?.name, "粘贴")
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "c", modifiers: cmdBit | optBit))?.name, "拷贝路径名")
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "3", modifiers: cmdBit | sftBit))?.isSystem, true)
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "3", modifiers: cmdBit | sftBit))?.kind, .system)
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "x", modifiers: cmdBit | ctlBit)))
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: cmdBit | ctlBit)))
            // 多余的位（如 capsLock / 设备相关位）不影响判断
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: cmdBit | (1 << 16)))?.name, "粘贴")
        }

        runTest("FinderReservedShortcuts 解析文本编辑按键绑定，拦截 ⌃V（pageDown:）") {
            try assertEqual(FinderReservedShortcuts.parseBindingKey("^v"), .init(modifiers: ctlBit, key: "v"))
            try assertEqual(FinderReservedShortcuts.parseBindingKey("^A"), .init(modifiers: ctlBit | sftBit, key: "a"), "大写隐含 ⇧")
            try assertEqual(FinderReservedShortcuts.parseBindingKey("@~^\u{F701}"), .init(modifiers: cmdBit | optBit | ctlBit, key: "\u{F701}"))
            try assertNil(FinderReservedShortcuts.parseBindingKey("$\u{F700}"), "只含 ⇧ 的组合不可能被录制")
            try assertNil(FinderReservedShortcuts.parseBindingKey("a"))
            try assertEqual(FinderReservedShortcuts.parseBindingKey("^"), nil, "单独的 ^ 字符不是组合键")

            let bindings = FinderReservedShortcuts.parseBindings(["^v": "pageDown:", "^k": ["deleteToEndOfParagraph:", "x"], "^x": ["a": "b"]])
            let hit = FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: ctlBit), textBindings: bindings)
            try assertEqual(hit, .init(name: "pageDown:", kind: .textEditing))
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "k", modifiers: ctlBit), textBindings: bindings)?.name, "deleteToEndOfParagraph:")
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "x", modifiers: ctlBit), textBindings: bindings), "多键序列子字典忽略")

            // 真实系统绑定表：⌃V 必须被拦截，⌃X、⌃⌘V 放行
            try assertEqual(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: ctlBit))?.kind, .textEditing)
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "x", modifiers: ctlBit)))
            try assertNil(FinderReservedShortcuts.conflict(for: ActionShortcut(key: "v", modifiers: ctlBit | cmdBit)))
        }

        runTest("ServiceInvocationPolicy 被派发激活时按激活前的前台应用判定调用方") {
            let me = "com.finderright.app", finder = "com.apple.finder"
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: me, providerBundleId: me,
                            providerHasKeyWindow: false, previousFrontmostBundleId: finder), finder, "快捷键触发：系统先激活本 App")
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: me, providerBundleId: me,
                            providerHasKeyWindow: true, previousFrontmostBundleId: finder), me, "用户正在本 App 窗口里操作")
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: me, providerBundleId: me,
                            providerHasKeyWindow: false, previousFrontmostBundleId: nil), me)
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: finder, providerBundleId: me,
                            providerHasKeyWindow: false, previousFrontmostBundleId: "com.apple.mail"), finder, "访达在前时不改写")
            try assertEqual(ServiceInvocationPolicy.effectiveCaller(frontmostBundleId: me, providerBundleId: me,
                            providerHasKeyWindow: false, previousFrontmostBundleId: "com.example.evil"), "com.example.evil", "激活前是其他 App 仍会被拒")
        }

        runTest("FinderKeyTakeover 按键码与修饰键识别，修饰键须完全一致") {
            let cmd: UInt64 = 1 << 20, shift: UInt64 = 1 << 17, opt: UInt64 = 1 << 19, ctl: UInt64 = 1 << 18
            let capsLock: UInt64 = 1 << 16, numericPad: UInt64 = 1 << 21
            typealias T = FinderKeyTakeover
            // ANSI 布局：X=7 C=8 V=9
            let cmdX = T.KeyChord(keyCode: 7, modifiers: 1 << 20), cmdV = T.KeyChord(keyCode: 9, modifiers: 1 << 20)
            let cmdC = T.KeyChord(keyCode: 8, modifiers: 1 << 20)
            let chords = ["shortcut.cut": cmdX, "shortcut.paste": cmdV]
            try assertEqual(T.command(keyCode: 7, modifierFlags: cmd, chords: chords, copy: cmdC), .cut)
            try assertEqual(T.command(keyCode: 9, modifierFlags: cmd | capsLock | numericPad, chords: chords, copy: cmdC), .paste, "无关标志位不影响")
            try assertEqual(T.command(keyCode: 8, modifierFlags: cmd, chords: chords, copy: cmdC), .copy)
            try assertNil(T.command(keyCode: 9, modifierFlags: cmd | opt, chords: chords, copy: cmdC), "⌥⌘V 是访达自己的移动")
            try assertNil(T.command(keyCode: 9, modifierFlags: cmd | shift, chords: chords, copy: cmdC))
            try assertNil(T.command(keyCode: 0, modifierFlags: cmd, chords: chords, copy: cmdC))

            let ctlV = T.KeyChord(keyCode: 9, modifiers: 1 << 18)
            let ctlChords = ["shortcut.cut": cmdX, "shortcut.paste": ctlV]
            try assertEqual(T.command(keyCode: 9, modifierFlags: ctl, chords: ctlChords, copy: cmdC), .paste, "改成 ⌃V")
            try assertNil(T.command(keyCode: 9, modifierFlags: cmd, chords: ctlChords, copy: cmdC), "改键后 ⌘V 交还访达")
            try assertNil(T.command(keyCode: 7, modifierFlags: cmd, chords: ["shortcut.paste": cmdV], copy: cmdC), "清空即停用")

            // 其他行：⌥⌘C 是访达自己的「拷贝路径」，拦截后可以给复制路径用
            let optCmdC = T.KeyChord(keyCode: 8, modifiers: (1 << 20) | (1 << 19))
            let allChords = ["shortcut.cut": cmdX, "shortcut.copyPath": optCmdC, "shortcut.toggleHidden": T.KeyChord(keyCode: 47, modifiers: (1 << 20) | (1 << 17))]
            try assertEqual(T.command(keyCode: 8, modifierFlags: cmd | opt, chords: allChords, copy: cmdC), .action("shortcut.copyPath"))
            try assertEqual(T.command(keyCode: 47, modifierFlags: cmd | shift, chords: allChords, copy: cmdC), .action("shortcut.toggleHidden"))
            try assertEqual(T.command(keyCode: 8, modifierFlags: cmd, chords: allChords, copy: cmdC), .copy, "⌘C 仍识别为拷贝")
            try assertEqual(T.KeyChord(keyCode: 7, modifiers: (1 << 20) | (1 << 16)), cmdX, "构造时去掉无关位")

            try assertEqual(T.functionKeyCode(for: "\u{F708}"), 96, "F5")
            try assertEqual(T.functionKeyCode(for: "\u{F70B}"), 100, "F8")
            try assertEqual(T.functionKeyCode(for: "\u{F700}"), 126, "↑")
            try assertNil(T.functionKeyCode(for: "v"))
            try assertTrue(T.isFunctionKey("\u{F70B}"), "F8 是功能键")
            try assertTrue(!T.isFunctionKey("\u{F700}"), "方向键不算功能键")
            try assertEqual(T.functionKeyCharacter(forKeyCode: 100), "\u{F70B}", "键码 100 对应 F8")
            try assertEqual(T.displayKeyName(for: "\u{F70B}"), "F8", "F8 显示名")
            try assertEqual(T.displayKeyName(for: "\u{F700}"), "↑", "方向键显示名")
            try assertEqual(T.displayKeyName(for: "v"), "V")
        }

        runTest("FinderKeyTakeover 默认 ⌘X / ⌘V 只补空位、不覆盖用户设置，录制只拦系统全局快捷键") {
            typealias T = FinderKeyTakeover
            let cmd = 1 << 20, ctl = 1 << 18, shift = 1 << 17
            let cmdX = ActionShortcut(key: "x", modifiers: cmd), cmdV = ActionShortcut(key: "v", modifiers: cmd)
            let opt = 1 << 19
            let optCmdC = ActionShortcut(key: "c", modifiers: cmd | opt)
            let sftCmdDot = ActionShortcut(key: ".", modifiers: cmd | shift)
            let sftCmdG = ActionShortcut(key: "g", modifiers: cmd | shift)
            let sftCmd5 = ActionShortcut(key: "5", modifiers: cmd | shift)
            let cmdZ = ActionShortcut(key: "z", modifiers: cmd)
            let all = ["shortcut.cut": cmdX, "shortcut.paste": cmdV, "shortcut.copyPath": optCmdC,
                       "shortcut.toggleHidden": sftCmdDot, "shortcut.undo": cmdZ, "shortcut.goToDirectory": sftCmdG,
                       T.screenshotActionId: sftCmd5]
            try assertEqual(T.defaultShortcuts, all, "默认值与访达原生一致")
            try assertEqual(T.defaultShortcuts[T.goToDirectoryActionId], sftCmdG, "打开路径默认 ⇧⌘G")
            try assertEqual(T.defaultShortcuts[T.screenshotActionId], sftCmd5, "截图默认 ⇧⌘5")
            try assertEqual(T.defaultsToApply(current: [:], alreadyApplied: []), all, "全新安装")
            try assertEqual(T.defaultsToApply(current: [
                "shortcut.cut": ActionShortcut(key: "c", modifiers: ctl),
                "shortcut.paste": ActionShortcut(key: "v", modifiers: ctl),
                "shortcut.copyPath": ActionShortcut(key: "p", modifiers: cmd | ctl),
            ], alreadyApplied: []).keys.sorted(), ["shortcut.goToDirectory", "shortcut.screenshot", "shortcut.toggleHidden", "shortcut.undo"], "用户设置过的行一律保留")
            try assertEqual(T.defaultsToApply(current: ["shortcut.paste": ActionShortcut(key: "v", modifiers: cmd | ctl)],
                                              alreadyApplied: ["shortcut.copyPath", "shortcut.toggleHidden", "shortcut.undo", "shortcut.goToDirectory", "shortcut.screenshot"]),
                            ["shortcut.cut": cmdX], "只补没设置的那一行")
            try assertEqual(T.defaultsToApply(current: ["shortcut.openTerminal": ActionShortcut(key: "V", modifiers: cmd)],
                                              alreadyApplied: ["shortcut.copyPath", "shortcut.toggleHidden", "shortcut.undo", "shortcut.goToDirectory", "shortcut.screenshot"]),
                            ["shortcut.cut": cmdX], "⌘V 已被其他动作占用则不填")
            // 1.6.4 升级：剪切 / 粘贴补过（用户之后清空了剪切），新增默认只补空位
            let legacy = T.legacyAppliedActionIds(cutPasteApplied: true)
            try assertEqual(T.defaultsToApply(current: ["shortcut.paste": cmdV, "shortcut.copyPath": ActionShortcut(key: "p", modifiers: cmd | ctl)],
                                              alreadyApplied: legacy),
                            ["shortcut.toggleHidden": sftCmdDot, "shortcut.undo": cmdZ, "shortcut.goToDirectory": sftCmdG, "shortcut.screenshot": sftCmd5], "清空的剪切不补回，用户的复制路径不覆盖；升级时补上新增默认")
            let oldDefaults = Set(all.keys).subtracting([T.goToDirectoryActionId])
            try assertEqual(T.defaultsToApply(current: [:], alreadyApplied: oldDefaults),
                            [T.goToDirectoryActionId: sftCmdG], "升级时给打开路径补上 ⇧⌘G")
            try assertEqual(T.defaultsToApply(current: [T.goToDirectoryActionId: ActionShortcut(key: "g", modifiers: cmd | ctl)], alreadyApplied: oldDefaults),
                            [:], "保留用户自定义的打开路径组合")
            try assertEqual(T.defaultsToApply(current: ["shortcut.openTerminal": ActionShortcut(key: "G", modifiers: cmd | shift)], alreadyApplied: oldDefaults),
                            [:], "⇧⌘G 已被其他动作占用则不补打开路径")
            try assertEqual(T.defaultsToApply(current: ["shortcut.openTerminal": cmdZ], alreadyApplied: Set(all.keys).subtracting(["shortcut.undo"])),
                            [:], "⌘Z 已被用户占用则不补撤销")
            try assertEqual(T.defaultsToApply(current: [:], alreadyApplied: Set(all.keys)), [:], "补过的行清空后不再补回")
            try assertTrue(T.legacyAppliedActionIds(cutPasteApplied: false).isEmpty)
            try assertTrue(T.handlesAction("shortcut.cut") && T.handlesAction("shortcut.paste"))
            try assertTrue(!T.handlesAction("shortcut.copyPath"))
            try assertTrue(!ServiceShortcuts.syncsShortcut(actionId: "shortcut.cut"))
            try assertTrue(ServiceShortcuts.syncsShortcut(actionId: "shortcut.copyPath"))

            let ctlV = ActionShortcut(key: "v", modifiers: ctl)
            let bindings = FinderReservedShortcuts.parseBindings(["^v": "pageDown:"])
            let screenshot = ActionShortcut(key: "3", modifiers: cmd | shift)
            for available in [true, false] {
                try assertNil(T.recordingConflict(for: ctlV, actionId: "shortcut.paste", interceptorAvailable: available, textBindings: bindings), "粘贴行可用 ⌃V")
                try assertNil(T.recordingConflict(for: cmdV, actionId: "shortcut.paste", interceptorAvailable: available, textBindings: bindings), "粘贴行可用 ⌘V")
                try assertEqual(T.recordingConflict(for: screenshot, actionId: "shortcut.cut", interceptorAvailable: available, textBindings: bindings)?.kind, .system, "系统全局快捷键轮不到拦截")
                try assertEqual(T.recordingConflict(for: screenshot, actionId: "shortcut.copyPath", interceptorAvailable: available, textBindings: bindings)?.kind, .system)
                try assertEqual(T.recordingConflict(for: sftCmd5, actionId: "shortcut.cut", interceptorAvailable: available, textBindings: bindings)?.kind, .system)
                try assertNil(T.recordingConflict(for: sftCmd5, actionId: T.screenshotActionId, interceptorAvailable: available, textBindings: bindings), "截图行允许设为系统默认 ⇧⌘5")
            }
            // 已授权：其他行也由拦截处理，访达菜单 / 文本编辑组合都能用
            try assertNil(T.recordingConflict(for: ctlV, actionId: "shortcut.copyPath", interceptorAvailable: true, textBindings: bindings))
            try assertNil(T.recordingConflict(for: cmdV, actionId: "shortcut.copyPath", interceptorAvailable: true, textBindings: bindings))
            try assertNil(T.recordingConflict(for: ActionShortcut(key: ".", modifiers: cmd | shift), actionId: "shortcut.toggleHidden", interceptorAvailable: true, textBindings: bindings))
            // 未授权：其他行回退为服务快捷键，照样拦
            try assertEqual(T.recordingConflict(for: ctlV, actionId: "shortcut.copyPath", interceptorAvailable: false, textBindings: bindings)?.kind, .textEditing)
            try assertEqual(T.recordingConflict(for: cmdV, actionId: "shortcut.copyPath", interceptorAvailable: false, textBindings: bindings)?.kind, .finderMenu)
        }

        runTest("FinderKeyTakeover 焦点在文字输入里一律放行") {
            try assertTrue(FinderKeyTakeover.isTextInput(role: "AXTextField", subrole: nil), "重命名")
            try assertTrue(FinderKeyTakeover.isTextInput(role: "AXTextField", subrole: "AXSearchField"), "搜索框")
            try assertTrue(FinderKeyTakeover.isTextInput(role: "AXTextArea", subrole: nil))
            try assertTrue(!FinderKeyTakeover.isTextInput(role: "AXList", subrole: "AXCollectionList"), "图标视图")
            try assertTrue(!FinderKeyTakeover.isTextInput(role: "AXOutline", subrole: nil), "列表视图")
            try assertTrue(!FinderKeyTakeover.isTextInput(role: nil, subrole: nil))

            typealias T = FinderKeyTakeover
            try assertEqual(T.decide(.cut, focusIsText: false, pasteboardIsCutMirror: false), .cut)
            try assertEqual(T.decide(.cut, focusIsText: true, pasteboardIsCutMirror: true), .passThrough, "重命名时剪切文字")
            try assertEqual(T.decide(.paste, focusIsText: true, pasteboardIsCutMirror: true), .passThrough, "重命名时粘贴文字，不能移走文件")
            try assertEqual(T.decide(.paste, focusIsText: false, pasteboardIsCutMirror: true), .paste)
            try assertEqual(T.decide(.paste, focusIsText: false, pasteboardIsCutMirror: false), .passThrough, "剪贴板已换成别的内容：普通粘贴")
            try assertEqual(T.decide(.copy, focusIsText: false, pasteboardIsCutMirror: true), .copyThenCancelCut)
            try assertEqual(T.decide(nil, focusIsText: false, pasteboardIsCutMirror: true), .passThrough)
            try assertEqual(T.decide(.action("shortcut.copyPath"), focusIsText: false, pasteboardIsCutMirror: false), .runAction("shortcut.copyPath"))
            try assertEqual(T.decide(.action("shortcut.copyPath"), focusIsText: true, pasteboardIsCutMirror: false), .passThrough, "重命名时按键交给文字")

            let zh = ["FinderRight: Copy Path": "FinderRight：复制路径"]
            try assertEqual(T.serviceMenuTitles(menuTitle: "FinderRight: Copy Path", translations: [zh, [:]]),
                            ["FinderRight: Copy Path", "FinderRight：复制路径"], "英文原文 + 各语言译名")
        }

        runTest("CutPasteboardMirror 按 changeCount 判断剪贴板是否仍是剪切内容") {
            var mirror = CutPasteboardMirror()
            try assertTrue(!mirror.matches(currentChangeCount: 0), "未记录时不匹配")
            mirror.record(changeCount: 42)
            try assertTrue(mirror.matches(currentChangeCount: 42))
            try assertTrue(!mirror.matches(currentChangeCount: 43), "之后又复制了别的")
            mirror.reset()
            try assertTrue(!mirror.matches(currentChangeCount: 42))
        }

        // MARK: 撤销上一次操作

        runTest("UndoExecutor 移回原处并拒绝覆盖") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let a = src.appendingPathComponent("a.txt"), b = src.appendingPathComponent("b.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: b)
            let a2 = dst.appendingPathComponent("a.txt"), b2 = dst.appendingPathComponent("b.txt")
            try fm.moveItem(at: a, to: a2)
            try fm.moveItem(at: b, to: b2)
            let record = UndoRecord(kind: .move, name: "dst", items: [
                .init(current: a2, original: a, fingerprint: FileFingerprint.capture(a2)!),
                .init(current: b2, original: b, fingerprint: FileFingerprint.capture(b2)!)],
                cutQueueBefore: nil, finderSnapshot: nil)
            try Data("占位".utf8).write(to: b)   // 原位置被同名文件占用
            let outcome = UndoExecutor.run(record, trash: { _ in throw TestFailure(message: "不应进废纸篓") })
            try assertEqual(outcome.undone, [a])
            try assertEqual(outcome.skipped, [UndoOutcome.Skip(name: "b.txt", reason: .originalOccupied)])
            try assertEqual(outcome.status, .partial)
            try assertEqual(try String(contentsOf: b, encoding: .utf8), "占位", "绝不覆盖")
            try assertTrue(fm.fileExists(atPath: b2.path), "跳过的项保持原样")
        }

        runTest("UndoExecutor 被修改 / 已不存在 / 原文件夹没了 都跳过") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let src = root.appendingPathComponent("src"), gone = root.appendingPathComponent("gone")
            let dst = root.appendingPathComponent("dst")
            for dir in [src, gone, dst] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            let a = src.appendingPathComponent("a.txt"), b = src.appendingPathComponent("b.txt")
            let c = gone.appendingPathComponent("c.txt")
            for (url, text) in [(a, "a"), (b, "b"), (c, "c")] { try Data(text.utf8).write(to: url) }
            var items: [UndoRecord.Item] = []
            for url in [a, b, c] {
                let moved = dst.appendingPathComponent(url.lastPathComponent)
                try fm.moveItem(at: url, to: moved)
                items.append(.init(current: moved, original: url, fingerprint: FileFingerprint.capture(moved)!))
            }
            try Data("改过了，长度也变了".utf8).write(to: items[0].current)
            try fm.removeItem(at: items[1].current)
            try fm.removeItem(at: gone)
            let record = UndoRecord(kind: .move, name: "dst", items: items, cutQueueBefore: nil, finderSnapshot: nil)
            let outcome = UndoExecutor.run(record, trash: { _ in })
            try assertEqual(outcome.undone, [])
            try assertEqual(outcome.status, .failure)
            try assertEqual(outcome.skipped.map(\.reason), [.modified, .missing, .originalFolderMissing])
        }

        runTest("UndoExecutor 复制品进废纸篓，文件夹内新增文件视为已修改") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let dst = root.appendingPathComponent("dst"), trashDir = root.appendingPathComponent("trash")
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let file = dst.appendingPathComponent("a.txt"), folder = dst.appendingPathComponent("folder")
            try Data("a".utf8).write(to: file)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // 先把文件夹修改时间拨回过去，确保之后新增文件一定改变它
            try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: folder.path)
            let record = UndoRecord(kind: .copy, name: "dst", items: [
                .init(current: file, original: nil, fingerprint: FileFingerprint.capture(file)!),
                .init(current: folder, original: nil, fingerprint: FileFingerprint.capture(folder)!)],
                cutQueueBefore: nil, finderSnapshot: nil)
            try Data("new".utf8).write(to: folder.appendingPathComponent("added.txt"))
            var trashed: [URL] = []
            let outcome = UndoExecutor.run(record, trash: { url in
                try fm.moveItem(at: url, to: trashDir.appendingPathComponent(url.lastPathComponent))
                trashed.append(url)
            })
            try assertEqual(trashed, [file])
            try assertEqual(outcome.undone, [file])
            try assertEqual(outcome.skipped, [UndoOutcome.Skip(name: "folder", reason: .modified)])
            try assertEqual(outcome.status, .partial)
        }

        runTest("UndoExecutor 编辑已有嵌套文件后拒绝撤销整个目录") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            defer { try? fm.removeItem(at: root) }
            let folder = root.appendingPathComponent("folder")
            let nested = folder.appendingPathComponent("nested")
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            let edited = nested.appendingPathComponent("existing.txt")
            try Data("before".utf8).write(to: edited)
            let record = UndoRecord(kind: .copy, name: "folder", items: [
                .init(current: folder, original: nil, fingerprint: FileFingerprint.capture(folder)!)],
                cutQueueBefore: nil, finderSnapshot: nil)

            try Data("after".utf8).write(to: edited)
            var trashed = false
            let outcome = UndoExecutor.run(record, trash: { _ in trashed = true })

            try assertTrue(!trashed, "修改过的目录不能进入废纸篓")
            try assertEqual(outcome.skipped.map(\.reason), [.modified])
            try assertEqual(try String(contentsOf: edited, encoding: .utf8), "after")
        }

        runTest("UndoRecord 深层不可读时修订保留记录且只做浅检查") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let folder = root.appendingPathComponent("folder")
            let nested = folder.appendingPathComponent("nested")
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
                try? fm.removeItem(at: root)
            }
            let record = UndoRecord(kind: .copy, name: "folder", items: [
                .init(current: folder, original: nil, fingerprint: FileFingerprint.capture(folder)!)],
                cutQueueBefore: nil, finderSnapshot: nil)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)

            try assertEqual(record.pruningRemovedItems(cutQueue: []), record,
                            "修订只核对顶层身份，不能因子目录不可读而删除撤销记录")
        }

        runTest("UndoExecutor 深层不可读按已修改而非不存在处理") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let folder = root.appendingPathComponent("folder")
            let nested = folder.appendingPathComponent("nested")
            try fm.createDirectory(at: nested, withIntermediateDirectories: true)
            defer {
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: nested.path)
                try? fm.removeItem(at: root)
            }
            let record = UndoRecord(kind: .copy, name: "folder", items: [
                .init(current: folder, original: nil, fingerprint: FileFingerprint.capture(folder)!)],
                cutQueueBefore: nil, finderSnapshot: nil)
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: nested.path)
            var trashed = false

            let outcome = UndoExecutor.run(record, trash: { _ in trashed = true })

            try assertTrue(!trashed)
            try assertEqual(outcome.skipped.map(\.reason), [.modified])
        }

        runTest("UndoExecutor 符号链接按链接本身移回") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let src = root.appendingPathComponent("src"), dst = root.appendingPathComponent("dst")
            try fm.createDirectory(at: src, withIntermediateDirectories: true)
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            let link = src.appendingPathComponent("link")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/target")
            let moved = dst.appendingPathComponent("link")
            try fm.moveItem(at: link, to: moved)
            guard let fingerprint = FileFingerprint.capture(moved) else {
                throw TestFailure(message: "指向不存在目标的链接也要能取到指纹（不跟随链接）")
            }
            let record = UndoRecord(kind: .move, name: "dst",
                                    items: [.init(current: moved, original: link, fingerprint: fingerprint)],
                                    cutQueueBefore: nil, finderSnapshot: nil)
            let outcome = UndoExecutor.run(record, trash: { _ in })
            try assertEqual(outcome.status, .success)
            try assertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "/nonexistent/target")
        }

        runTest("UndoCenter 快照比较决定 ⌘Z 归属") {
            let center = UndoCenter(stateDirectory: makeTempDirectory())
            let snap = FinderUndoSnapshot(title: "撤销重命名", enabled: true)
            try assertEqual(center.shortcutDecision(finderSnapshot: snap), .passThrough, "无记录放行")
            center.register(UndoRecord(kind: .cut, name: "", items: [], cutQueueBefore: [], finderSnapshot: snap), displayCount: 1)
            try assertEqual(center.shortcutDecision(finderSnapshot: snap), .undo)
            try assertEqual(center.shortcutDecision(finderSnapshot: FinderUndoSnapshot(title: "撤销移动", enabled: true)),
                            .passThrough, "访达之后又有操作")
            try assertEqual(center.shortcutDecision(finderSnapshot: nil), .passThrough, "读不到访达菜单")
            try assertTrue(center.beginUndo() != nil)
            try assertEqual(center.shortcutDecision(finderSnapshot: snap), .ignore, "撤销中吞掉连按")
            try assertNil(center.beginUndo(), "撤销中不能再开始一次")
            center.endUndo()
            try assertEqual(center.shortcutDecision(finderSnapshot: snap), .passThrough, "撤销后记录已清空")
        }

        runTest("UndoCenter 记录快照为 nil 时 ⌘Z 一律放行") {
            let center = UndoCenter(stateDirectory: makeTempDirectory())
            center.register(UndoRecord(kind: .cut, name: "", items: [], cutQueueBefore: [], finderSnapshot: nil), displayCount: 1)
            try assertEqual(center.shortcutDecision(finderSnapshot: FinderUndoSnapshot(title: "撤销", enabled: false)), .passThrough)
            try assertEqual(center.shortcutDecision(finderSnapshot: nil), .passThrough)
            try assertTrue(center.beginUndo() != nil, "菜单入口仍能取到记录")
        }

        runTest("UndoCenter 状态文件随记录写入与清除，且不含路径") {
            let dir = makeTempDirectory()
            let center = UndoCenter(stateDirectory: dir)
            let fp = FileFingerprint(fileNumber: 1, device: 1, isDirectory: false, modificationDate: nil, size: 0)
            let move = UndoRecord(kind: .move, name: "Projects", items: [
                .init(current: URL(fileURLWithPath: "/tmp/Projects/a"), original: URL(fileURLWithPath: "/tmp/a"), fingerprint: fp),
                .init(current: URL(fileURLWithPath: "/tmp/Projects/b"), original: URL(fileURLWithPath: "/tmp/b"), fingerprint: fp)],
                cutQueueBefore: nil, finderSnapshot: nil)
            center.register(move)
            try assertEqual(UndoMenuState.read(from: dir), UndoMenuState(kind: .move, count: 2, name: "Projects"))
            let raw = try String(contentsOf: dir.appendingPathComponent(UndoMenuState.fileName), encoding: .utf8)
            try assertTrue(!raw.contains("/tmp"), "状态文件不能写路径")
            _ = center.beginUndo()
            try assertNil(UndoMenuState.read(from: dir), "开始撤销即清除状态")
            center.register(move)
            center.endUndo()
            try assertEqual(center.current, move, "撤销期间登记的新记录在 endUndo 后保留")
            center.invalidate(kind: .copy)
            try assertEqual(center.current, move, "类型不符不作废")
            center.invalidate(kind: .move)
            try assertNil(center.current)
            try assertNil(UndoMenuState.read(from: dir))
            center.register(move)
            center.clear()
            try assertNil(center.current)
            try assertNil(UndoMenuState.read(from: dir))
        }

        runTest("UndoRecord 移进废纸篓 / 改名 / 换成别的文件的项被剔除，只改了内容的保留") {
            let fm = FileManager.default
            let root = makeTempDirectory()
            let dst = root.appendingPathComponent("dst"), trashDir = root.appendingPathComponent("trash")
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
            try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
            let names = ["trashed.txt", "renamed.txt", "replaced.txt", "edited.txt"]
            var items: [UndoRecord.Item] = []
            for name in names {
                let url = dst.appendingPathComponent(name)
                try Data(name.utf8).write(to: url)
                items.append(.init(current: url, original: nil, fingerprint: FileFingerprint.capture(url)!))
            }
            let record = UndoRecord(kind: .copy, name: "dst", items: items, cutQueueBefore: nil,
                                    finderSnapshot: FinderUndoSnapshot(title: "撤销拷贝", enabled: true))
            try assertEqual(record.pruningRemovedItems(cutQueue: []), record, "都还在时原样返回")

            try fm.moveItem(at: items[0].current, to: trashDir.appendingPathComponent("trashed.txt"))
            try fm.moveItem(at: items[1].current, to: dst.appendingPathComponent("renamed 2.txt"))
            try fm.removeItem(at: items[2].current)
            try Data("新文件".utf8).write(to: items[2].current)
            try Data("改过了".utf8).write(to: items[3].current)
            guard let pruned = record.pruningRemovedItems(cutQueue: []) else {
                throw TestFailure(message: "还有项在原处，不应作废")
            }
            try assertEqual(pruned.items.map(\.current), [items[3].current], "只留下原处仍是同一个项目的")
            try assertEqual(pruned.count, 1, "菜单显示的项数随之减少")
            try assertEqual(pruned.finderSnapshot, record.finderSnapshot, "⌘Z 归属比对不受影响")

            try fm.moveItem(at: items[3].current, to: trashDir.appendingPathComponent("edited.txt"))
            try assertNil(record.pruningRemovedItems(cutQueue: []), "全部移走后作废")
        }

        runTest("UndoRecord 剪切新增的项都已离开剪切队列时作废") {
            let record = UndoRecord(kind: .cut, name: "", items: [], cutQueueBefore: ["/a", "/b"],
                                    finderSnapshot: nil, displayCount: 2)
            try assertEqual(record.pruningRemovedItems(cutQueue: ["/a", "/b", "/c", "/d"]), record, "都还在时不变")
            let pruned = record.pruningRemovedItems(cutQueue: ["/a", "/d"])
            try assertEqual(pruned?.count, 1, "新增项只剩一个")
            try assertEqual(pruned?.cutQueueBefore, ["/a"], "已移走的旧项撤销时不再写回队列")
            try assertNil(record.pruningRemovedItems(cutQueue: ["/a", "/b"]), "新增项全被移走")
            try assertNil(record.pruningRemovedItems(cutQueue: []))
        }

        runTest("UndoCenter 按修订结果更新或清除状态文件") {
            let dir = makeTempDirectory()
            let center = UndoCenter(stateDirectory: dir)
            try assertTrue(!center.revalidate { _ in nil }, "没有记录时无事可做")
            let fp = FileFingerprint(fileNumber: 1, device: 1, isDirectory: false, modificationDate: nil, size: 0)
            let a = UndoRecord.Item(current: URL(fileURLWithPath: "/tmp/dst/a"), original: nil, fingerprint: fp)
            let b = UndoRecord.Item(current: URL(fileURLWithPath: "/tmp/dst/b"), original: nil, fingerprint: fp)
            let copy = UndoRecord(kind: .copy, name: "dst", items: [a, b], cutQueueBefore: nil, finderSnapshot: nil)
            center.register(copy)
            try assertTrue(!center.revalidate { $0 }, "没变化时不重写")
            let one = UndoRecord(kind: .copy, name: "dst", items: [a], cutQueueBefore: nil, finderSnapshot: nil)
            try assertTrue(center.revalidate { _ in one })
            try assertEqual(center.current, one)
            try assertEqual(UndoMenuState.read(from: dir), UndoMenuState(kind: .copy, count: 1, name: "dst"))
            try assertTrue(center.revalidate { _ in nil })
            try assertNil(center.current)
            try assertNil(UndoMenuState.read(from: dir), "作废后扩展不再显示撤销项")
        }

        runTest("UndoText 菜单标题与提示文案") {
            let id: (String) -> String = { $0 }
            try assertEqual(UndoText.menuTitle(for: UndoMenuState(kind: .move, count: 3, name: "Projects"), localize: id),
                            "撤销移动到“Projects”（3 项）")
            try assertEqual(UndoText.menuTitle(for: UndoMenuState(kind: .cut, count: 2, name: ""), localize: id), "撤销剪切（2 项）")
            let fp = FileFingerprint(fileNumber: 1, device: 1, isDirectory: false, modificationDate: nil, size: 0)
            let item = UndoRecord.Item(current: URL(fileURLWithPath: "/x/a.txt"), original: nil, fingerprint: fp)
            let record = UndoRecord(kind: .move, name: "Projects", items: [item, item, item], cutQueueBefore: nil, finderSnapshot: nil)
            let two = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
            try assertEqual(UndoText.feedback(for: record, outcome: UndoOutcome(undone: two + [URL(fileURLWithPath: "/c")]), localize: id),
                            "已撤销：移动到“Projects”（3 项）")
            try assertEqual(UndoText.feedback(for: record, outcome: UndoOutcome(undone: two, skipped: [
                .init(name: "b.txt", reason: .modified), .init(name: "c.txt", reason: .missing)]), localize: id),
                            "已撤销 2 项，跳过 2 项：“b.txt”在操作后被修改等 1 项")
            try assertEqual(UndoText.feedback(for: record, outcome: UndoOutcome(skipped: [
                .init(name: "a.txt", reason: .originalOccupied)]), localize: id),
                            "无法撤销：“a.txt”原位置已有同名项目")
        }

        runTest("FinderKeyTakeover 撤销键按决策吞键或放行") {
            typealias T = FinderKeyTakeover
            try assertEqual(T.defaultShortcuts[T.undoActionId], ActionShortcut(key: "z", modifiers: 1 << 20), "默认 ⌘Z")
            try assertTrue(T.handlesAction(T.undoActionId))
            try assertEqual(T.decide(.undo, focusIsText: false, pasteboardIsCutMirror: false, undo: .undo), .undo)
            try assertEqual(T.decide(.undo, focusIsText: false, pasteboardIsCutMirror: false, undo: .ignore), .swallow)
            try assertEqual(T.decide(.undo, focusIsText: false, pasteboardIsCutMirror: false, undo: .passThrough), .passThrough)
            try assertEqual(T.decide(.undo, focusIsText: true, pasteboardIsCutMirror: false, undo: .undo), .passThrough, "重命名时放行")
            // ANSI 布局 Z=6；与现有按键测试一致，修饰键直接用 CGEventFlags 位（⌘ = 1 << 20）
            let chord = T.KeyChord(keyCode: 6, modifiers: 1 << 20)
            try assertEqual(T.command(keyCode: 6, modifierFlags: 1 << 20, chords: [T.undoActionId: chord], copy: nil), .undo)
        }

        runTest("MenuFeatureCatalog 显示大小与撤销排在最前且默认开启") {
            // 显示大小是一条状态行，排在所有操作之前；撤销是常用操作入口，紧随其后
            try assertEqual(MenuFeatureCatalog.all.first?.id, MenuFeatureCatalog.diskUsage)
            try assertEqual(MenuFeatureCatalog.all.dropFirst().first?.id, MenuFeatureCatalog.undo)
            try assertTrue(!MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.undo))
            try assertTrue(!MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.diskUsage),
                           "显示大小默认开启")
            let ordered = MenuFeatureCatalog.ordered(by: [MenuFeatureCatalog.newFile]).map(\.id)
            try assertEqual(ordered.first, MenuFeatureCatalog.diskUsage,
                            "老用户保存的顺序里没有它时也放最前")
            try assertEqual(ordered[1], MenuFeatureCatalog.undo, "撤销排在显示大小之后")
        }

        runTest("NewFileTemplateCatalog 内置项与默认顺序") {
            let items = NewFileTemplateCatalog.builtInItems
            try assertEqual(items.count, 13)
            try assertEqual(items.map(\.id), NewFileTemplateCatalog.defaultOrder)
            try assertTrue(items.contains(where: { $0.id == "txt" && !$0.isOffice && !$0.isCustom }))
            try assertTrue(items.contains(where: { $0.id == "docx" && $0.isOffice && !$0.isCustom }))
        }

        runTest("NewFileTemplateCatalog.resolvedTemplates 排序与合并") {
            let custom1 = FileTemplate(id: "c1", name: "Custom 1", fileExtension: "conf", content: "port=8080")
            let custom2 = FileTemplate(id: "c2", name: "Custom 2", fileExtension: "log", content: "")

            // 1. 空 order：返回默认内置 + 自定义项
            let defaultResolved = NewFileTemplateCatalog.resolvedTemplates(order: [], customTemplates: [custom1, custom2])
            try assertEqual(defaultResolved.count, 15)
            try assertEqual(defaultResolved.prefix(13).map(\.id), NewFileTemplateCatalog.defaultOrder)
            try assertEqual(defaultResolved.suffix(2).map(\.id), ["c1", "c2"])

            // 2. 自定义 order：按指定顺序排列，未提及的自动追加
            let customOrder = ["c1", "docx", "md"]
            let resolved = NewFileTemplateCatalog.resolvedTemplates(order: customOrder, customTemplates: [custom1, custom2])
            try assertEqual(resolved.count, 15)
            try assertEqual(Array(resolved.prefix(3).map(\.id)), ["c1", "docx", "md"])
            // 其余未列出的项应追加在后
            try assertTrue(resolved.contains(where: { $0.id == "c2" }))
            try assertTrue(resolved.contains(where: { $0.id == "txt" }))
        }

        runTest("剪贴板新建：文本与图片格式分别持久化") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: file)
            try assertNil(config.clipboardFileExtension(isImage: false))
            try assertNil(config.clipboardFileExtension(isImage: true))
            config.setClipboardFileExtension("md", isImage: false)
            config.setClipboardFileExtension("jpeg", isImage: true)
            config.setClipboardFileExtension("yaml", isImage: false)
            let reloaded = SharedConfig(fileURL: file)
            try assertEqual(reloaded.clipboardFileExtension(isImage: false), "yaml")
            try assertEqual(reloaded.clipboardFileExtension(isImage: true), "jpeg")
            try assertTrue(reloaded.newFileFromClipboard, "记忆格式不改变功能开关")
        }

        runTest("剪贴板新建：默认开启、开关持久化与菜单入口") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: file)
            try assertTrue(config.newFileFromClipboard)
            config.newFileFromClipboard = false
            try assertTrue(!SharedConfig(fileURL: file).newFileFromClipboard)
            config.newFileFromClipboard = true
            try assertTrue(SharedConfig(fileURL: file).newFileFromClipboard)

            var input = MenuBuildInput(location: .container, selection: .empty,
                                       enabledFeatureIds: [MenuFeatureCatalog.newFile])
            func children() -> [MenuDataNode] {
                let node = MenuTreeBuilder.buildMenuTree(input: input).first { $0.id == MenuFeatureCatalog.newFile }
                if case .submenu(let children) = node?.kind { return children }
                return []
            }
            try assertEqual(children().map(\.id), ["newFile.clipboard"], "没有启用模板时仍可从剪贴板新建")
            input.newFileFromClipboard = false
            try assertTrue(children().isEmpty)
            input.newFileFromClipboard = true
            input.enabledFeatureIds = []
            try assertTrue(children().isEmpty, "关闭新建功能后不暴露剪贴板入口")
        }

        runTest("剪贴板新建：文字、空内容、文件引用与损坏图片") {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            try assertThrows(ClipboardFileContent.ReadError.unsupported) { _ = try ClipboardFileContent.read(from: board) }
            let text = "你好 👋\n  保留空格\n"
            board.setString(text, forType: .string)
            let count = board.changeCount
            let result = try ClipboardFileContent.read(from: board)
            try assertEqual(result.fileExtension, "txt")
            try assertEqual(String(decoding: result.data, as: UTF8.self), text)
            try assertEqual(board.changeCount, count, "保存不得修改剪贴板")
            board.clearContents()
            board.setString("", forType: .string)
            try assertThrows(ClipboardFileContent.ReadError.unsupported) { _ = try ClipboardFileContent.read(from: board) }
            board.clearContents()
            board.setString("file:///tmp/photo.png", forType: .fileURL)
            board.setString("photo.png", forType: .string)
            try assertThrows(ClipboardFileContent.ReadError.unsupported) { _ = try ClipboardFileContent.read(from: board) }
            board.clearContents()
            board.setPropertyList(["/tmp/photo.png"], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            try assertThrows(ClipboardFileContent.ReadError.unsupported) { _ = try ClipboardFileContent.read(from: board) }
            board.clearContents()
            board.setData(Data("invalid".utf8), forType: .png)
            board.setString("fallback", forType: .string)
            try assertThrows(ClipboardFileContent.ReadError.invalidImage) { _ = try ClipboardFileContent.read(from: board) }
        }

        runTest("剪贴板新建：PNG 与 TIFF 输出 PNG，保留尺寸和透明度，优先图片") {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 0.5), atX: 0, y: 0)
            bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: 1, y: 0)
            for (format, type) in [(NSBitmapImageRep.FileType.png, NSPasteboard.PasteboardType.png), (.tiff, .tiff)] {
                board.clearContents()
                board.setData(bitmap.representation(using: format, properties: [:])!, forType: type)
                board.setString("image description", forType: .string)
                let result = try ClipboardFileContent.read(from: board)
                try assertEqual(result.fileExtension, "png")
                let source = CGImageSourceCreateWithData(result.data as CFData, nil)!
                try assertEqual(CGImageSourceGetType(source)! as String, "public.png")
                let decoded = NSBitmapImageRep(data: result.data)!
                try assertEqual(decoded.pixelsWide, 2)
                try assertEqual(decoded.pixelsHigh, 1)
                try assertTrue(abs(decoded.colorAt(x: 0, y: 0)!.alphaComponent - 0.5) < 0.01)
                try assertTrue(decoded.colorAt(x: 1, y: 0)!.alphaComponent < 0.01)
            }
        }

        runTest("剪贴板新建：实际导出 PNG、JPEG、HEIC，JPEG 透明区铺白底") {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<20 {
                for x in 0..<40 {
                    bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: x < 20 ? 0 : 1), atX: x, y: y)
                }
            }
            board.setData(bitmap.representation(using: .png, properties: [:])!, forType: .png)
            let content = try ClipboardFileContent.read(from: board)
            for format in ImageTargetFormat.allCases {
                let data = try content.encodedData(for: format.fileExtension)
                let source = CGImageSourceCreateWithData(data as CFData, nil)!
                try assertEqual(CGImageSourceGetType(source)! as String, format.utType as String)
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                try assertEqual(image.width, 40)
                try assertEqual(image.height, 20)
                if format == .jpeg {
                    let color = NSBitmapImageRep(cgImage: image).colorAt(x: 2, y: 10)!.usingColorSpace(.deviceRGB)!
                    try assertTrue(color.redComponent > 0.9 && color.greenComponent > 0.9 && color.blueComponent > 0.9,
                                   "JPEG 不支持透明度，透明区域应为白色")
                }
                if format == .png { try assertEqual(data, content.data, "PNG 不做重复编码") }
            }
            try assertThrows(ClipboardFileContent.ReadError.unsupported) { _ = try content.encodedData(for: "gif") }
            board.clearContents()
            board.setString("{\"ok\":true}", forType: .string)
            let text = try ClipboardFileContent.read(from: board)
            try assertEqual(try text.encodedData(for: "json"), text.data, "文本选择类型时保持原文")
        }

        runTest("剪贴板新建：Finder 复制单张图片、路径授权与非法文件") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 1,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.setColor(NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 0.5), atX: 0, y: 0)
            bitmap.setColor(NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0), atX: 1, y: 0)
            let file = root.appendingPathComponent("复制的图片.png")
            let original = bitmap.representation(using: .png, properties: [:])!
            try original.write(to: file)
            func copy(_ urls: [URL]) {
                board.clearContents()
                board.writeObjects(urls as [NSURL])
            }
            copy([file])
            let count = board.changeCount
            var checked: [URL] = []
            let content = try ClipboardFileContent.read(from: board, allowFile: { checked.append($0); return $0 == file })
            try assertEqual(checked, [file])
            try assertEqual(content.fileExtension, "png")
            try assertEqual(board.changeCount, count)
            try assertEqual(try Data(contentsOf: file), original, "原图保持不变")
            let decoded = NSBitmapImageRep(data: content.data)!
            try assertEqual(decoded.pixelsWide, 2)
            try assertEqual(decoded.pixelsHigh, 1)
            try assertTrue(abs(decoded.colorAt(x: 0, y: 0)!.alphaComponent - 0.5) < 0.01)
            try assertThrows(ClipboardFileContent.ReadError.unsupported) {
                _ = try ClipboardFileContent.read(from: board, allowFile: { _ in false })
            }
            copy([file, file])
            try assertThrows(ClipboardFileContent.ReadError.unsupported) {
                _ = try ClipboardFileContent.read(from: board, allowFile: { _ in true })
            }
            let text = root.appendingPathComponent("file.txt")
            try Data("text".utf8).write(to: text)
            for url in [root, text, root.appendingPathComponent("missing.png")] {
                copy([url])
                try assertThrows(ClipboardFileContent.ReadError.unsupported) {
                    _ = try ClipboardFileContent.read(from: board, allowFile: { _ in true })
                }
            }
            let broken = root.appendingPathComponent("broken.png")
            try Data("invalid".utf8).write(to: broken)
            copy([broken])
            try assertThrows(ClipboardFileContent.ReadError.invalidImage) {
                _ = try ClipboardFileContent.read(from: board, allowFile: { _ in true })
            }
            board.clearContents()
            board.setPropertyList([file.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            try assertEqual(try ClipboardFileContent.read(from: board, allowFile: { $0 == file }).fileExtension, "png")

            let jpeg = root.appendingPathComponent("rotated.jpg")
            let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, bitmap.cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
            try assertTrue(CGImageDestinationFinalize(destination))
            copy([jpeg])
            let rotated = try ClipboardFileContent.read(from: board, allowFile: { $0 == jpeg })
            let rotatedBitmap = NSBitmapImageRep(data: rotated.data)!
            try assertEqual(rotatedBitmap.pixelsWide, 1, "保存 JPEG 时应用 EXIF 方向")
            try assertEqual(rotatedBitmap.pixelsHigh, 2)
        }

        runTest("SharedConfig 新建文件模板顺序、隐藏与编辑持久化") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let configURL = tempDir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: configURL)

            try assertEqual(config.newFileOrder, [])
            try assertEqual(config.hiddenNewFileTemplates, Set())
            try assertTrue(config.isNewFileTemplateEnabled("txt"))

            config.newFileOrder = ["docx", "txt"]
            config.setNewFileTemplateEnabled("md", enabled: false)
            try assertTrue(!config.isNewFileTemplateEnabled("md"))
            try assertEqual(config.newFileOrder, ["docx", "txt"])
            try assertEqual(config.hiddenNewFileTemplates, ["md"])

            // 测试添加与更新自定义模板
            let tmpl = FileTemplate(id: "custom_tpl", name: "Old", fileExtension: "txt", content: "old")
            config.addFileTemplate(tmpl)
            try assertEqual(config.customFileTemplates.first?.name, "Old")

            let updatedTmpl = FileTemplate(id: "custom_tpl", name: "New", fileExtension: "txt", content: "new")
            config.updateFileTemplate(updatedTmpl)
            try assertEqual(config.customFileTemplates.first?.name, "New")
            try assertEqual(config.customFileTemplates.first?.content, "new")

            // 加入 order 和 hidden 后删除，测试自动清理
            config.newFileOrder = ["custom_tpl", "txt"]
            config.setNewFileTemplateEnabled("custom_tpl", enabled: false)
            config.removeFileTemplate(withId: "custom_tpl")
            try assertTrue(config.customFileTemplates.isEmpty)
            try assertEqual(config.newFileOrder, ["txt"])
            try assertTrue(!config.hiddenNewFileTemplates.contains("custom_tpl"))
        }

        runTest("SharedConfig 内置类型移除后不再显示，恢复后重新启用") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let configURL = tempDir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: configURL)

            config.removeBuiltInNewFileTemplate("csv")
            config.removeBuiltInNewFileTemplate("custom_tpl")
            try assertEqual(config.removedNewFileTemplates, ["csv"], "只接受内置类型")
            try assertTrue(!config.isNewFileTemplateEnabled("csv"), "移除即从菜单隐藏，菜单与服务只看隐藏集合")
            try assertEqual(SharedConfig(fileURL: configURL).removedNewFileTemplates, ["csv"], "写入磁盘")

            config.restoreBuiltInNewFileTemplate("csv")
            try assertEqual(config.removedNewFileTemplates, Set())
            try assertTrue(config.isNewFileTemplateEnabled("csv"), "恢复后为启用状态")
        }

        runTest("复制文件名：SharedConfig 默认值、持久化与未知值回退") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let configURL = tempDir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: configURL)

            // 1. 默认值
            try assertEqual(config.copyFileNameFormat, .full, "默认含扩展名")

            // 2. 持久化
            config.copyFileNameFormat = .withoutExtension
            try assertEqual(config.copyFileNameFormat, .withoutExtension)
            let reloaded = SharedConfig(fileURL: configURL)
            try assertEqual(reloaded.copyFileNameFormat, .withoutExtension, "磁盘重新加载保持 withoutExtension")

            // 3. 未知值回退到 full
            guard let data = try? Data(contentsOf: configURL),
                  var dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                throw TestFailure(message: "无法读取 plist")
            }
            dict["copyFileNameFormat"] = "unknown_invalid_format"
            let mutatedData = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try mutatedData.write(to: configURL)

            let fallbackConfig = SharedConfig(fileURL: configURL)
            try assertEqual(fallbackConfig.copyFileNameFormat, .full, "未知值应安全回退到 .full")
        }

        runTest("复制文件名：中文、多点文件名、普通文件与无扩展名") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fm = FileManager.default

            // 1. 中文多点普通文件
            let file1 = tempDir.appendingPathComponent("项目 汇报.2026.docx")
            fm.createFile(atPath: file1.path, contents: Data("test".utf8))
            try assertEqual(PathFormatter.fileName(for: file1, format: .full), "项目 汇报.2026.docx")
            try assertEqual(PathFormatter.fileName(for: file1, format: .withoutExtension), "项目 汇报.2026")

            // 2. 多点文件名 (report.tar.gz)
            let file2 = tempDir.appendingPathComponent("report.tar.gz")
            fm.createFile(atPath: file2.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: file2, format: .full), "report.tar.gz")
            try assertEqual(PathFormatter.fileName(for: file2, format: .withoutExtension), "report.tar")

            // 3. 普通单扩展名文件
            let file3 = tempDir.appendingPathComponent("notes.txt")
            fm.createFile(atPath: file3.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: file3, format: .full), "notes.txt")
            try assertEqual(PathFormatter.fileName(for: file3, format: .withoutExtension), "notes")

            // 4. 无扩展名文件
            let file4 = tempDir.appendingPathComponent("LICENSE")
            fm.createFile(atPath: file4.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: file4, format: .full), "LICENSE")
            try assertEqual(PathFormatter.fileName(for: file4, format: .withoutExtension), "LICENSE")

            let trailingDot = tempDir.appendingPathComponent("report.")
            try Data().write(to: trailingDot)
            try assertEqual(PathFormatter.fileName(for: trailingDot, format: .withoutExtension), "report.", "末尾单独的点不是扩展名")
        }

        runTest("复制文件名：点文件、带点目录、app 包与类型未知") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fm = FileManager.default

            // 1. 点文件 .gitignore (保留原名)
            let dot1 = tempDir.appendingPathComponent(".gitignore")
            fm.createFile(atPath: dot1.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: dot1, format: .full), ".gitignore")
            try assertEqual(PathFormatter.fileName(for: dot1, format: .withoutExtension), ".gitignore")

            // 2. 多点点文件 .env.local (去掉最后一段扩展名)
            let dot2 = tempDir.appendingPathComponent(".env.local")
            fm.createFile(atPath: dot2.path, contents: Data())
            try assertEqual(PathFormatter.fileName(for: dot2, format: .full), ".env.local")
            try assertEqual(PathFormatter.fileName(for: dot2, format: .withoutExtension), ".env")

            // 3. 带点目录 (保留全名)
            let dirWithDot = tempDir.appendingPathComponent("project.v2.dir")
            try fm.createDirectory(at: dirWithDot, withIntermediateDirectories: true)
            try assertEqual(PathFormatter.fileName(for: dirWithDot, format: .full), "project.v2.dir")
            try assertEqual(PathFormatter.fileName(for: dirWithDot, format: .withoutExtension), "project.v2.dir")

            // 4. app 包目录 (保留全名)
            let appBundle = tempDir.appendingPathComponent("DemoTool.app")
            try fm.createDirectory(at: appBundle, withIntermediateDirectories: true)
            try assertEqual(PathFormatter.fileName(for: appBundle, format: .full), "DemoTool.app")
            try assertEqual(PathFormatter.fileName(for: appBundle, format: .withoutExtension), "DemoTool.app")

            // 5. 类型未知 (不存在的路径，保留全名避免误截目录)
            let ghostFile = tempDir.appendingPathComponent("non_existent.dir.or.file.txt")
            try assertEqual(PathFormatter.fileName(for: ghostFile, format: .full), "non_existent.dir.or.file.txt")
            try assertEqual(PathFormatter.fileName(for: ghostFile, format: .withoutExtension), "non_existent.dir.or.file.txt")
        }

        runTest("复制文件名：多选格式化每行一项") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let fm = FileManager.default
            let f1 = tempDir.appendingPathComponent("文档.pdf")
            let f2 = tempDir.appendingPathComponent("data.tar.gz")
            let d3 = tempDir.appendingPathComponent("folder.bundle")
            fm.createFile(atPath: f1.path, contents: Data())
            fm.createFile(atPath: f2.path, contents: Data())
            try fm.createDirectory(at: d3, withIntermediateDirectories: true)

            let urls = [f1, f2, d3]

            let full = PathFormatter.fileNames(for: urls, format: .full)
            try assertEqual(full, "文档.pdf\ndata.tar.gz\nfolder.bundle")

            let withoutExt = PathFormatter.fileNames(for: urls, format: .withoutExtension)
            try assertEqual(withoutExt, "文档\ndata.tar\nfolder.bundle")
        }

        runTest("反馈链接：模板与字段预填、特殊字符编码") {
            let url = IssueLink.url(template: .bug, fields: [
                (id: "version", value: "1.11.0 (build 42)"),
                (id: "permissions", value: "辅助功能：已授权\na&b=c+d"),
                (id: "logs", value: "  \n"),
            ])
            try assertEqual(url.host, "github.com")
            try assertEqual(url.path, "/funny-dog/FinderRight/issues/new")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            try assertEqual(dict["template"], "bug_report.yml")
            try assertEqual(dict["version"], "1.11.0 (build 42)")
            // & = + 换行都必须被编码，否则会截断或拆出多余参数
            try assertEqual(dict["permissions"], "辅助功能：已授权\na&b=c+d")
            try assertTrue(!url.absoluteString.contains("+"), "加号未编码会被 GitHub 解析成空格")
            try assertEqual(dict["logs"], nil, "空字段应省略")
            try assertEqual(items.count, 3)
        }

        runTest("反馈链接：功能建议模板与超长字段截断") {
            let feature = IssueLink.url(template: .feature)
            try assertEqual(feature.query, "template=01-feature_request.yml")

            let long = String(repeating: "长", count: IssueLink.fieldLimit + 100)
            let url = IssueLink.url(template: .bug, fields: [(id: "logs", value: long)])
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "logs" }?.value ?? ""
            try assertEqual(value.count, IssueLink.fieldLimit + 1)
            try assertTrue(value.hasSuffix("…"))
        }

        runTest("图标缩略图：只保留目标 2x 位图、透明背景与模板标记，不修改原图") {
            let source = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
                NSColor.red.setFill()
                rect.insetBy(dx: 64, dy: 64).fill()
                return true
            }
            source.isTemplate = true
            for size in [16, 28] {
                guard let image = IconThumbnail.make(from: source, pointSize: size),
                      let bitmap = image.representations.first as? NSBitmapImageRep else {
                    throw TestFailure(message: "未生成图标位图")
                }
                try assertEqual(image.size, NSSize(width: size, height: size))
                try assertEqual(image.representations.count, 1)
                try assertEqual(bitmap.pixelsWide, size * 2)
                try assertEqual(bitmap.pixelsHigh, size * 2)
                try assertTrue(image.isTemplate)
                try assertTrue((bitmap.colorAt(x: size, y: size)?.alphaComponent ?? 0) > 0.9)
                let center = bitmap.colorAt(x: size, y: size)!.usingColorSpace(.sRGB)!
                try assertTrue(center.redComponent > 0.9 && center.greenComponent < 0.1)
                try assertEqual(bitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
                let data = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
                let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: data)
                try assertEqual(restored?.representations.count, 1)
                try assertTrue(restored?.isTemplate == true)
                try assertEqual(restored?.representations.first?.pixelsWide, size * 2)
            }
            try assertEqual(source.size, NSSize(width: 256, height: 256))
            source.isTemplate = false
            try assertTrue(IconThumbnail.make(from: source, pointSize: 16)?.isTemplate == false)
            try assertNil(IconThumbnail.make(from: source, pointSize: 0))
        }
    }
}
