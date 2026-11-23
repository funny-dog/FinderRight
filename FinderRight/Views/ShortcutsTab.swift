import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 快捷键 Tab

struct ShortcutsTab: View {

    private var actions: [(id: String, name: String, icon: String)] {
        let regular: [(id: String, name: String, icon: String)] = [
            ("shortcut.undo",         "撤销",           "arrow.uturn.backward"),
            ("shortcut.newFile",      "新建文件",       "doc.badge.plus"),
            ("shortcut.copyPath",     "复制路径",       "link"),
            ("shortcut.copyFileName", "复制文件名",     "character.cursor.ibeam"),
            ("shortcut.copyFileContent", "复制文件内容", "doc.plaintext"),
            ("shortcut.goToDirectory", "打开路径…",     "arrow.right.circle"),
            ("shortcut.openTerminal", "打开终端",       "terminal"),
            ("shortcut.openEditor",   "打开编辑器",     "curlybraces"),
            ("shortcut.cut",          "剪切",           "scissors"),
            ("shortcut.paste",        "粘贴",           "doc.on.clipboard"),
            ("shortcut.compress",     "压缩为 ZIP",     "doc.zipper"),
            ("shortcut.decompress",   "解压到当前目录", "shippingbox.and.arrow.backward"),
            ("shortcut.toggleHidden", "切换隐藏文件",   "eye"),
        ]
        return regular + (SharedConfig.shared.developerToolsEnabled ? [
            ("shortcut.copyProjectRelativePath", "复制项目相对路径", "point.topleft.down.curvedto.point.bottomright.up"),
            ("shortcut.copyDirectoryTree", "复制目录树", "list.bullet.indent")
        ] : [])
    }

    private let clipboardAction = (id: FinderKeyTakeover.clipboardActionId, name: "剪贴板", icon: "doc.on.clipboard")
    private let screenshotAction = (id: FinderKeyTakeover.screenshotActionId, name: "截图", icon: "camera.viewfinder")

    private var allShortcutActions: [(id: String, name: String, icon: String)] {
        actions + [clipboardAction, screenshotAction]
    }

    @FRState private var conflictMessage: String?
    /// 服务快捷键已写入系统，但运行中的访达要重启才会读取
    @FRState private var needsFinderRestart = ServiceShortcutSync.finderNeedsRelaunch
    /// 授权后所有快捷键由按键拦截处理；未授权时剪切 / 粘贴不可用，其他行退回服务快捷键
    @FRState private var hasAccessibility = AccessibilityChecker.check()
    @FRState private var shortcuts: [String: ActionShortcut] = SharedConfig.shared.shortcuts
    /// 全局仅允许同时录制一行快捷键，避免多行同时处于录制态
    @FRState private var recordingActionId: String?
    @FRState private var recordingMonitor: Any?
    @ObservedObject private var globalShortcut = GlobalDirectoryShortcut.shared
    @ObservedObject private var clipboardService = ClipboardHistoryService.shared
    @ObservedObject private var clipboardShortcut = GlobalClipboardShortcut.shared
    @ObservedObject private var screenshotService = ScreenshotService.shared

    private var clipboardShortcutSubtitle: String {
        if !clipboardService.isEnabled {
            return NSLocalizedString("需先在「功能 → 剪贴板」中开启", comment: "")
        }
        if let error = clipboardShortcut.errorMessage {
            return error
        }
        return NSLocalizedString("全局生效，可在任意应用中唤起剪贴板", comment: "")
    }

    private var screenshotShortcutSubtitle: String {
        if !screenshotService.isEnabled {
            return NSLocalizedString("需先在「功能 → 截图」中开启", comment: "")
        }
        if let error = screenshotService.errorMessage {
            return error
        }
        if screenshotService.mode == .snapshot {
            if !screenshotService.hasScreenCaptureAccess {
                return NSLocalizedString("需先在「功能 → 截图」中授权屏幕录制", comment: "")
            }
            return NSLocalizedString("全局生效，可在任意应用中定格屏幕并框选截图", comment: "")
        }
        return NSLocalizedString("全局生效，可在任意应用中唤起系统截图", comment: "")
    }

    var body: some View {
        FRPage(title: "快捷键", subtitle: "在访达中选中文件后直接按键，无需展开右键菜单") {
            FRSection("访达快捷键") {
                if !hasAccessibility {
                    FRCard {
                        FRRow(title: Text("快捷键需要「辅助功能」权限"),
                              subtitle: Text("授权后任意组合都能用、改完立即生效；未授权时剪切、粘贴不可用，其余快捷键要重启访达才生效。")) {
                            VStack(alignment: .trailing, spacing: 8) {
                                Button("授权辅助功能…") { requestAccessibility() }
                                    .buttonStyle(.frPrimary)
                                Button("前往权限与扩展") {
                                    SettingsNavigation.shared.selectedTab = .permissions
                                }
                                .buttonStyle(.frLink)
                            }
                        }
                    }
                }

                // 授权后按键拦截立即生效，不用重启；只有退回服务快捷键时才需要
                if needsFinderRestart && !hasAccessibility {
                    FRCard {
                        FRRow(title: Text("重启访达后新快捷键生效"),
                              subtitle: Text("访达只在启动时读取服务快捷键；重启会关闭所有访达窗口，可能中断正在进行的拷贝。")) {
                            Button("重启访达") {
                                FinderRelauncher.relaunch()
                                needsFinderRestart = false
                            }
                            .buttonStyle(.frPrimary)
                        }
                    }
                }

                FRCard {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { FRDivider() }
                        ShortcutCell(actionId: action.id,
                                     actionName: action.name,
                                     actionIcon: action.icon,
                                     shortcut: shortcuts[action.id],
                                     isRecording: recordingActionId == action.id,
                                     interceptorAvailable: interceptorAvailable(for: action.id),
                                     onToggleRecording: { toggleRecording(for: action.id) },
                                     onClear: { clearShortcut(for: action.id) })
                    }
                }

                FRCard {
                    FRRow(title: Text("恢复默认快捷键"),
                          subtitle: Text("恢复与访达一致的默认组合，没有默认的会清空。")) {
                        Button("恢复默认…") { confirmRestoreDefaults() }
                            .buttonStyle(.frSecondary)
                    }
                }

                FRFootnote(Text("点击按钮后按键录制，Delete 清除，ESC 取消。默认与访达一致，升级不会改动你的设置。\n除剪切、粘贴、切换隐藏文件、打开路径外，其余快捷键需先选中文件。"))
            }

            FRSection("全局快捷键") {
                FRCard {
                    ShortcutCell(actionId: clipboardAction.id,
                                 actionName: clipboardAction.name,
                                 actionIcon: clipboardAction.icon,
                                 shortcut: shortcuts[clipboardAction.id],
                                 isRecording: recordingActionId == clipboardAction.id,
                                 interceptorAvailable: true,
                                 subtitleOverride: clipboardShortcutSubtitle,
                                 subtitleIsWarning: clipboardService.isEnabled && clipboardShortcut.errorMessage != nil,
                                 onToggleRecording: { toggleRecording(for: clipboardAction.id) },
                                 onClear: { clearShortcut(for: clipboardAction.id) })

                    FRDivider()

                    ShortcutCell(actionId: screenshotAction.id,
                                 actionName: screenshotAction.name,
                                 actionIcon: screenshotAction.icon,
                                 shortcut: shortcuts[screenshotAction.id],
                                 isRecording: recordingActionId == screenshotAction.id,
                                 interceptorAvailable: true,
                                 subtitleOverride: screenshotShortcutSubtitle,
                                 subtitleIsWarning: screenshotService.isEnabled
                                     && (screenshotService.errorMessage != nil
                                         || (screenshotService.mode == .snapshot && !screenshotService.hasScreenCaptureAccess)),
                                 onToggleRecording: { toggleRecording(for: screenshotAction.id) },
                                 onClear: { clearShortcut(for: screenshotAction.id) })
                }

                FRFootnote(Text("全局快捷键在任意应用中均可使用，无需辅助功能权限，也无需重启访达。"))
            }
        }
        .onAppear {
            SharedConfig.shared.reload()
            shortcuts = SharedConfig.shared.shortcuts
            needsFinderRestart = ServiceShortcutSync.finderNeedsRelaunch
            hasAccessibility = AccessibilityChecker.check()
            screenshotService.refreshPermission()
        }
        .onDisappear {
            stopRecording()
        }
        // 从系统设置授权后切回本 App 时刷新提示
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = AccessibilityChecker.check()
            screenshotService.refreshPermission()
        }
        .onChange(of: conflictMessage) { message in
            guard let message else { return }
            FRDialog(title: NSLocalizedString("快捷键冲突", comment: ""), message: message,
                     symbol: "exclamationmark.triangle", tone: .warning,
                     buttons: [NSLocalizedString("好", comment: "")]).present { _ in conflictMessage = nil }
        }
    }

    private func interceptorAvailable(for actionId: String) -> Bool {
        if actionId == clipboardAction.id || actionId == screenshotAction.id {
            return true
        }
        return hasAccessibility || (actionId == FinderKeyTakeover.goToDirectoryActionId && globalShortcut.isEnabled)
    }

    private func toggleRecording(for actionId: String) {
        if recordingActionId == actionId {
            stopRecording()
            return
        }
        startRecording(for: actionId)
    }

    private func startRecording(for actionId: String) {
        stopRecording()
        recordingActionId = actionId
        GlobalDirectoryShortcut.shared.setRecording(true)
        GlobalClipboardShortcut.shared.setRecording(true)
        ScreenshotService.shared.setRecording(true)
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let targetId = self.recordingActionId else { return event }
            if event.keyCode == 53 {
                self.stopRecording()
            } else if event.keyCode == 51 || event.keyCode == 117 {
                self.finishRecording(nil, for: targetId)
            } else {
                let cleanMods = event.modifierFlags.intersection([.command, .option, .shift, .control])
                let keyFromCode = FinderKeyTakeover.functionKeyCharacter(forKeyCode: Int(event.keyCode))
                let rawChars = keyFromCode ?? event.charactersIgnoringModifiers?.lowercased()
                guard let chars = rawChars, !chars.isEmpty else { return nil }
                let hasPrimaryModifier = !cleanMods.intersection([.command, .option, .control]).isEmpty
                let allowFunctionKey = self.interceptorAvailable(for: targetId) && FinderKeyTakeover.isFunctionKey(chars)
                guard hasPrimaryModifier || allowFunctionKey else { return nil }
                self.finishRecording(ActionShortcut(key: chars, modifiers: Int(cleanMods.rawValue)), for: targetId)
            }
            return nil
        }
    }

    private func stopRecording() {
        recordingActionId = nil
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
            GlobalDirectoryShortcut.shared.setRecording(false)
            GlobalClipboardShortcut.shared.setRecording(false)
            ScreenshotService.shared.setRecording(false)
        }
    }

    private func clearShortcut(for actionId: String) {
        stopRecording()
        finishRecording(nil, for: actionId)
    }

    private func finishRecording(_ newShortcut: ActionShortcut?, for actionId: String) {
        if let candidate = newShortcut {
            let available = interceptorAvailable(for: actionId)
            // 已授权：按键拦截抢在访达之前处理，只拦系统全局快捷键；未授权：除剪切 / 粘贴外退回服务快捷键，照旧拦截
            if let reserved = FinderKeyTakeover.recordingConflict(for: candidate, actionId: actionId,
                                                                   interceptorAvailable: available) {
                var message: String
                switch reserved.kind {
                case .system:
                    message = String(format: NSLocalizedString("该快捷键已被系统「%@」占用，请换一个组合", comment: ""),
                                     NSLocalizedString(reserved.name, comment: ""))
                case .finderMenu:
                    message = String(format: NSLocalizedString("该快捷键是访达自带的「%@」，访达会优先响应，请换一个组合（例如加上 ⌃）", comment: ""),
                                     NSLocalizedString(reserved.name, comment: ""))
                case .textEditing:
                    message = String(format: NSLocalizedString("该快捷键是系统文本编辑按键（%@），访达会先拿去处理，请换一个组合（例如 ⌃⌘ 组合）", comment: ""),
                                     reserved.name)
                }
                if !reserved.isSystem {
                    message += "\n" + NSLocalizedString("授权「辅助功能」后可以使用这个组合。", comment: "")
                }
                stopRecording()
                conflictMessage = message
                return
            }
            for other in allShortcutActions where other.id != actionId {
                if let existing = shortcuts[other.id],
                   existing.key.lowercased() == candidate.key.lowercased(),
                   existing.modifiers == candidate.modifiers {
                    let otherTitle = NSLocalizedString(other.name, comment: "")
                    let msg = String(format: NSLocalizedString("该快捷键已被「%@」占用", comment: ""), otherTitle)
                    stopRecording()
                    conflictMessage = msg
                    return
                }
            }
        }
        SharedConfig.shared.setShortcut(newShortcut, forActionId: actionId)
        shortcuts = SharedConfig.shared.shortcuts
        stopRecording()
        shortcutChanged(actionId: actionId)
    }

    /// 系统弹窗会把 FinderRight 加进辅助功能列表；再打开设置页，用户只需打开开关
    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func confirmRestoreDefaults() {
        stopRecording()
        let dialog = FRDialog(
            title: NSLocalizedString("恢复默认快捷键？", comment: ""),
            message: NSLocalizedString("你设置的快捷键会被替换为默认组合，没有默认组合的会被清空。", comment: ""),
            symbol: "arrow.counterclockwise", tone: .warning,
            buttons: [NSLocalizedString("恢复默认", comment: ""), NSLocalizedString("取消", comment: "")])
        dialog.present { if $0 == 0 { restoreDefaults() } }
    }

    /// 全部换成默认快捷键，并刷新各行、按键拦截与服务快捷键
    private func restoreDefaults() {
        stopRecording()
        FinderShortcutInterceptor.restoreDefaultShortcuts()
        shortcuts = SharedConfig.shared.shortcuts
        FinderShortcutInterceptor.shared.refresh()
        guard ServiceShortcutSync.run() else { return }
        NSUpdateDynamicServices()
        needsFinderRestart = true
    }

    /// 按键拦截立即生效；其余行同时同步为系统服务快捷键（未授权时的回退），有变化时记下需重启访达
    private func shortcutChanged(actionId: String) {
        FinderShortcutInterceptor.shared.refresh()
        guard ServiceShortcutSync.run() else { return }
        NSUpdateDynamicServices()
        if ServiceShortcuts.syncsShortcut(actionId: actionId) { needsFinderRestart = true }
    }
}

// MARK: - 单行快捷键录制组件

struct ShortcutCell: View {
    let actionId: String
    let actionName: String
    let actionIcon: String
    let shortcut: ActionShortcut?
    let isRecording: Bool
    /// 已授权「辅助功能」：所有行由按键拦截处理
    let interceptorAvailable: Bool
    var subtitleOverride: String? = nil
    var subtitleIsWarning: Bool = false
    let onToggleRecording: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            FRIconChip(systemName: actionIcon)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(actionName))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                if let reserved = shortcut.flatMap({
                    FinderKeyTakeover.recordingConflict(for: $0, actionId: actionId, interceptorAvailable: interceptorAvailable)
                }) {
                    // 系统全局快捷键永远轮不到；访达 / 文本编辑组合在未授权（退回服务快捷键）时由访达或系统响应
                    Group {
                        switch reserved.kind {
                        case .system:
                            Text(String(format: NSLocalizedString("与系统「%@」冲突，不会生效，请重新录制", comment: ""),
                                        NSLocalizedString(reserved.name, comment: "")))
                        case .textEditing:
                            Text(String(format: NSLocalizedString("未授权「辅助功能」时被系统文本编辑按键（%@）占用", comment: ""),
                                        reserved.name))
                        case .finderMenu:
                            Text(String(format: NSLocalizedString("未授权「辅助功能」时由访达自带的「%@」响应", comment: ""),
                                        NSLocalizedString(reserved.name, comment: "")))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(FRTheme.warnText)
                } else if actionId == FinderKeyTakeover.pasteActionId {
                    Text("粘贴到当前窗口所在的文件夹，空白处也可以")
                        .font(.system(size: 11))
                        .foregroundColor(FRTheme.mute)
                } else if actionId == FinderKeyTakeover.toggleHiddenActionId && !interceptorAvailable {
                    Text("需要「辅助功能」权限，否则仅在右键菜单展开时生效")
                        .font(.system(size: 11))
                        .foregroundColor(FRTheme.mute)
                } else if let subtitleOverride {
                    Text(verbatim: subtitleOverride)
                        .font(.system(size: 11))
                        .foregroundColor(subtitleIsWarning ? FRTheme.warnText : FRTheme.mute)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggleRecording) {
                Group {
                    if isRecording {
                        Text("按下快捷键…")
                            .foregroundColor(FRTheme.accentText)
                    } else if let s = shortcut {
                        Text(displayString(s))
                            .fontWeight(.semibold)
                            .foregroundColor(FRTheme.text)
                    } else {
                        Text("未设置")
                            .foregroundColor(FRTheme.mute)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 84)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isRecording ? FRTheme.selection : FRTheme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isRecording ? FRTheme.accentText : FRTheme.fieldBorder, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isRecording)

            Button(action: onClear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(FRTheme.mute.opacity(0.7))
            }
            .buttonStyle(.plain)
            .opacity(shortcut != nil && !isRecording ? 1 : 0)
            .help("清除")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func displayString(_ s: ActionShortcut) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(s.modifiers))
        var r = ""
        if flags.contains(.control) { r += "⌃" }
        if flags.contains(.option)  { r += "⌥" }
        if flags.contains(.shift)   { r += "⇧" }
        if flags.contains(.command) { r += "⌘" }
        r += FinderKeyTakeover.displayKeyName(for: s.key)
        return r
    }
}

// MARK: - 服务快捷键同步

enum ServiceShortcutSync {
    static let showsServicesMenuKey = "showServicesMenu"
    static let defaultShowsServicesMenu = false
    /// 最近一次真正改写 pbs 的时间；访达早于它启动就说明还没读到新快捷键
    private static let syncedAtKey = "serviceShortcutsSyncedAt"

    /// 同步服务快捷键及菜单显示状态（默认在「服务」中隐藏），返回是否有变化。
    @discardableResult
    static func run() -> Bool {
        var shortcuts = SharedConfig.shared.shortcuts
        if SharedConfig.shared.globalOpenPathShortcut {
            // 全局热键独占入口，移除服务回退，避免同一组合触发两次。
            shortcuts.removeValue(forKey: FinderKeyTakeover.goToDirectoryActionId)
        }
        let showsMenu = (UserDefaults.standard.object(forKey: showsServicesMenuKey) as? Bool) ?? defaultShowsServicesMenu
        var developerVisibility: [String: Bool] = [:]
        for id in MenuFeatureCatalog.developerFeatureIds {
            let enabled = SharedConfig.shared.isActionEnabled(id)
            if !enabled { shortcuts.removeValue(forKey: id.replacingOccurrences(of: "feature.", with: "shortcut.")) }
            for service in MenuFeatureCatalog.feature(forId: id)?.serviceDeclarations ?? [] {
                developerVisibility[service.message] = enabled && showsMenu
            }
        }
        guard let bundleId = Bundle.main.bundleIdentifier,
              ServiceShortcuts.sync(
                shortcuts: shortcuts, bundleId: bundleId,
                services: Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]] ?? [],
                showsInServicesMenu: showsMenu,
                serviceVisibility: developerVisibility
              ) else { return false }
        UserDefaults.standard.set(Date(), forKey: syncedAtKey)
        return true
    }

    /// 访达是否在最近一次同步之前启动（需要重启才能用上新快捷键）
    static var finderNeedsRelaunch: Bool {
        guard let syncedAt = UserDefaults.standard.object(forKey: syncedAtKey) as? Date,
              let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let started = processStartDate(pid: finder.processIdentifier) else { return false }
        return started < syncedAt
    }

    /// 访达由 launchd 拉起，NSRunningApplication.launchDate 为 nil，改从内核读进程启动时间
    private static func processStartDate(pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }
}
