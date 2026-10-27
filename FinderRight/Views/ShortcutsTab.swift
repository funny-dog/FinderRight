import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 快捷键 Tab

struct ShortcutsTab: View {

    private let actions: [(id: String, name: String, icon: String)] = [
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

    @FRState private var conflictMessage: String?
    /// 服务快捷键已写入系统，但运行中的访达要重启才会读取
    @FRState private var needsFinderRestart = ServiceShortcutSync.finderNeedsRelaunch
    /// 授权后所有快捷键由按键拦截处理；未授权时剪切 / 粘贴不可用，其他行退回服务快捷键
    @FRState private var hasAccessibility = AccessibilityChecker.check()
    /// 恢复默认后递增，让各行重新读取快捷键
    @FRState private var reloadToken = 0

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
                                     allActions: actions,
                                     interceptorAvailable: hasAccessibility,
                                     onConflict: { msg in
                                         conflictMessage = msg
                                     },
                                     onChange: { shortcutChanged(actionId: action.id) })
                        .id("\(action.id)-\(reloadToken)")
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
        }
        .onAppear {
            needsFinderRestart = ServiceShortcutSync.finderNeedsRelaunch
            hasAccessibility = AccessibilityChecker.check()
        }
        // 从系统设置授权后切回本 App 时刷新提示
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccessibility = AccessibilityChecker.check()
        }
        .onChange(of: conflictMessage) { message in
            guard let message else { return }
            showSheet(FRDialog(title: NSLocalizedString("快捷键冲突", comment: ""), message: message,
                               symbol: "exclamationmark.triangle", tone: .warning,
                               buttons: [NSLocalizedString("好", comment: "")])) { _ in conflictMessage = nil }
        }
    }

    /// 设置窗口内的弹窗以 sheet 显示；找不到窗口时退回模态
    private func showSheet(_ dialog: FRDialog, completion: @escaping (Int?) -> Void) {
        if let window = NSApp.keyWindow {
            dialog.beginSheet(for: window, completion: completion)
        } else {
            completion(dialog.runModal())
        }
    }

    /// 系统弹窗会把 FinderRight 加进辅助功能列表；再打开设置页，用户只需打开开关
    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func confirmRestoreDefaults() {
        let dialog = FRDialog(
            title: NSLocalizedString("恢复默认快捷键？", comment: ""),
            message: NSLocalizedString("你设置的快捷键会被替换为默认组合，没有默认组合的会被清空。", comment: ""),
            symbol: "arrow.counterclockwise", tone: .warning,
            buttons: [NSLocalizedString("恢复默认", comment: ""), NSLocalizedString("取消", comment: "")])
        showSheet(dialog) { if $0 == 0 { restoreDefaults() } }
    }

    /// 全部换成默认快捷键，并刷新各行、按键拦截与服务快捷键
    private func restoreDefaults() {
        FinderShortcutInterceptor.restoreDefaultShortcuts()
        reloadToken += 1
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
    let allActions: [(id: String, name: String, icon: String)]
    /// 已授权「辅助功能」：所有行由按键拦截处理
    let interceptorAvailable: Bool
    let onConflict: (String) -> Void
    let onChange: () -> Void

    @FRState private var shortcut: ActionShortcut?
    @FRState private var isRecording = false
    @FRState private var monitor: Any?

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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { isRecording ? cancelRecording() : startRecording() } label: {
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

            Button { finishRecording(nil) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(FRTheme.mute.opacity(0.7))
            }
            .buttonStyle(.plain)
            .opacity(shortcut != nil && !isRecording ? 1 : 0)
            .help("清除")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onAppear { shortcut = SharedConfig.shared.shortcut(forActionId: actionId) }
        .onDisappear {
            isRecording = false
            removeMonitor()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                self.cancelRecording()
            } else if event.keyCode == 51 || event.keyCode == 117 {
                self.finishRecording(nil)
            } else {
                let cleanMods = event.modifierFlags.intersection([.command, .option, .shift, .control])
                guard !cleanMods.intersection([.command, .option, .control]).isEmpty,
                      let chars = event.charactersIgnoringModifiers?.lowercased(),
                      !chars.isEmpty else { return nil }
                self.finishRecording(ActionShortcut(key: chars, modifiers: Int(cleanMods.rawValue)))
            }
            return nil
        }
    }

    private func cancelRecording() { isRecording = false; removeMonitor() }

    private func finishRecording(_ newShortcut: ActionShortcut?) {
        if let candidate = newShortcut {
            // 已授权：按键拦截抢在访达之前处理，只拦系统全局快捷键；未授权：除剪切 / 粘贴外退回服务快捷键，照旧拦截
            if let reserved = FinderKeyTakeover.recordingConflict(for: candidate, actionId: actionId,
                                                                   interceptorAvailable: interceptorAvailable) {
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
                cancelRecording()
                onConflict(message)
                return
            }
            for other in allActions where other.id != actionId {
                if let existing = SharedConfig.shared.shortcut(forActionId: other.id),
                   existing.key.lowercased() == candidate.key.lowercased(),
                   existing.modifiers == candidate.modifiers {
                    let otherTitle = NSLocalizedString(other.name, comment: "")
                    let msg = String(format: NSLocalizedString("该快捷键已被「%@」占用", comment: ""), otherTitle)
                    cancelRecording()
                    onConflict(msg)
                    return
                }
            }
        }
        isRecording = false
        shortcut = newShortcut
        SharedConfig.shared.setShortcut(newShortcut, forActionId: actionId)
        removeMonitor()
        onChange()
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func displayString(_ s: ActionShortcut) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(s.modifiers))
        var r = ""
        if flags.contains(.control) { r += "⌃" }
        if flags.contains(.option)  { r += "⌥" }
        if flags.contains(.shift)   { r += "⇧" }
        if flags.contains(.command) { r += "⌘" }
        r += s.key.uppercased()
        return r
    }
}

// MARK: - 服务快捷键同步

enum ServiceShortcutSync {
    /// 最近一次真正改写 pbs 的时间；访达早于它启动就说明还没读到新快捷键
    private static let syncedAtKey = "serviceShortcutsSyncedAt"

    /// 把设置里的快捷键写入系统服务快捷键，返回是否有变化
    @discardableResult
    static func run() -> Bool {
        guard let bundleId = Bundle.main.bundleIdentifier,
              ServiceShortcuts.sync(shortcuts: SharedConfig.shared.shortcuts, bundleId: bundleId) else { return false }
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
