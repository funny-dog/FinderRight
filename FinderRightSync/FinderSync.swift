import Cocoa
import FinderSync
import FinderRightKit
import os.log

private let log = OSLog(subsystem: "com.finderright.app.sync", category: "FinderSync")

// MARK: - 剪切队列（文件 IPC，跨沙箱共享）

private var cutQueueFileURL: URL {
    IPCBridge.rootDirectory.appendingPathComponent("cut-queue.json")
}

private func normalizePath(_ path: String) -> String {
    var p = URL(fileURLWithPath: path).standardizedFileURL.path
    if p.hasPrefix("/System/Volumes/Data") {
        p = String(p.dropFirst("/System/Volumes/Data".count))
    }
    return p
}

/// 获取当前待剪切队列中的所有源文件路径集合
private func currentCutQueuePaths() -> Set<String> {
    guard let data = try? Data(contentsOf: cutQueueFileURL),
          let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else {
        return []
    }
    return Set(paths.map { normalizePath($0) })
}

private let cutBadgeIdentifier = "com.finderright.badge.cut"

/// 生成高辨识度剪切状态文件角标（32x32 Retina，深灰半透明圆底 + 白色高光边框 + 白色剪刀）
private func createCutBadgeImage() -> NSImage {
    let size = NSSize(width: 32, height: 32)
    let img = NSImage(size: size, flipped: false) { rect in
        let bg = NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
        NSColor(calibratedWhite: 0.15, alpha: 0.88).setFill()
        bg.fill()

        bg.lineWidth = 1.5
        NSColor(calibratedWhite: 1.0, alpha: 0.95).setStroke()
        bg.stroke()

        if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            let scImg = scissors.withSymbolConfiguration(config) ?? scissors
            let iconRect = NSRect(x: 7.5, y: 7.5, width: 17, height: 17)
            NSColor.white.setFill()
            scImg.draw(in: iconRect)
        }
        return true
    }
    return img
}

// MARK: - 日志

private let logQueue = DispatchQueue(label: "com.finderright.app.sync.log", qos: .utility)
private let logDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return df
}()

private func logToFile(_ message: String) {
    // 1. 系统统一 OSLog（主线程毫秒级开销）
    os_log("%{public}@", log: log, type: .default, message)

    // 2. 本地调试文件：异步串行派发到后台队列，避免主线程磁盘 I/O 阻塞
    let timestamp = logDateFormatter.string(from: Date())
    logQueue.async {
        let fm = FileManager.default
        // appex 沙箱内 urls(for: .documentDirectory) 会返回空数组（扩展无 Documents 概念），
        // 用 NSHomeDirectory()（沙箱下指向容器路径）兜底，否则文件日志被静默吞掉
        let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        // 沙箱容器内 Documents 目录可能尚不存在，不先创建则写入被静默吞掉
        try? fm.createDirectory(at: docDir, withIntermediateDirectories: true)
        let logFile = docDir.appendingPathComponent("debug.log")
        let oldLogFile = docDir.appendingPathComponent("debug.log.1")
        let maxBytes: UInt64 = 1024 * 1024 // 1MB

        if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size >= maxBytes {
            try? fm.removeItem(at: oldLogFile)
            try? fm.moveItem(at: logFile, to: oldLogFile)
        }

        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logFile.path) {
            if let h = try? FileHandle(forWritingTo: logFile) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

// MARK: - FinderSync

class FinderSync: FIFinderSync {

    // MARK: - 静态图标与资源缓存（零 I/O、零解析延迟）
    private static var symbolCache: [String: NSImage] = [:]
    private static let cacheQueue = DispatchQueue(label: "com.finderright.app.sync.cache", qos: .utility)

    private static func getSymbolImage(named name: String) -> NSImage? {
        if let img = symbolCache[name] { return img }
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            img.isTemplate = true
            symbolCache[name] = img
            return img
        }
        return nil
    }

    private static func preloadSymbols() {
        let symbols = [
            "doc.badge.plus", "doc.on.doc", "terminal", "curlybraces",
            "scissors", "doc.on.clipboard", "archivebox", "eye", "xmark.circle",
            "doc.text", "doc.richtext", "tablecells", "chevron.left.forwardslash.chevron.right"
        ]
        for s in symbols {
            _ = getSymbolImage(named: s)
        }
    }

    /// 冷启动打点：init 入口时间（进程被拉起后尽早记录）
    private static var initStartUptime: TimeInterval = 0
    private var didDeferredSetup = false

    override init() {
        Self.initStartUptime = ProcessInfo.processInfo.systemUptime
        super.init()

        // init 路径刻意保持极简：只有 directoryURLs 注册是扩展工作的前提。
        // 符号预热、卷挂载监听等全部延后到首次 menu(for:) 之后（见 deferredSetupIfNeeded），
        // 让系统回收扩展后的首次右键等待时间降到最低。
        let dirs = Self.buildMonitoredDirectories()
        FIFinderSyncController.default().directoryURLs = dirs

        // 注册剪切状态文件角标徽章（Finder 文件图标右下角显示）
        FIFinderSyncController.default().setBadgeImage(createCutBadgeImage(), label: "已剪切", forBadgeIdentifier: cutBadgeIdentifier)

        // 后台预热编辑器与图标（派发即返回，不阻塞 init）
        Self.refreshInstalledEditorsAsync()

        let initMs = (ProcessInfo.processInfo.systemUptime - Self.initStartUptime) * 1000
        logToFile("init done: \(String(format: "%.1f", initMs))ms monitoredDirs=\(dirs.count)")
    }

    // MARK: - 文件角标徽章回调

    override func requestBadgeIdentifier(for url: URL) {
        let normPath = normalizePath(url.path)
        let cutPaths = currentCutQueuePaths()
        if cutPaths.contains(normPath) {
            logToFile("requestBadgeIdentifier: MATCH cut badge for \(url.lastPathComponent)")
            FIFinderSyncController.default().setBadgeIdentifier(cutBadgeIdentifier, for: url)
        } else {
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
        }
    }

    /// 首次菜单构建之后执行的一次性延后初始化（冷启动瘦身的一部分）
    private func deferredSetupIfNeeded() {
        guard !didDeferredSetup else { return }
        didDeferredSetup = true

        // SF Symbols 预热（getSymbolImage 本身带懒缓存兜底，这里只是提前摊销）
        Self.preloadSymbols()

        // 卷挂载监听延后注册：init 时的 buildMonitoredDirectories 已包含当前已挂载卷，
        // 首次菜单前新挂载卷的漏监听窗口极小，可接受
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumeDidMount(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeDidUnmount(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)
        logToFile("deferredSetup done")
    }

    @objc func volumeDidMount(_ n: Notification) { updateMonitoredDirectories() }
    @objc func volumeDidUnmount(_ n: Notification) { updateMonitoredDirectories() }

    private func updateMonitoredDirectories() {
        let dirs = Self.buildMonitoredDirectories()
        FIFinderSyncController.default().directoryURLs = dirs
        logToFile("updateMonitoredDirectories count: \(dirs.count)")
    }

    /// 构建需要监控的目录集合：用户主目录 + 已挂载卷。
    ///
    /// FIFinderSync 只有当 Finder 当前目录在 directoryURLs 集合内（或其子目录内）时，
    /// 才会触发右键菜单回调。
    ///
    /// 注意：iCloud Drive、Google Drive 等云盘是 macOS 的 **File Provider 域**，系统把右键
    /// 菜单 / 徽章扩展点保留给域自身的 File Provider 扩展，会**静默忽略**第三方 Finder Sync
    /// 对这些路径的 directoryURLs 注册（实测 `beginObservingDirectory` / `menu(for:)` 回调
    /// 永不触发，且与完全磁盘访问无关 —— 那是文件权限，这是扩展点路由）。
    /// 因此这里不再尝试注册云盘路径；云盘文件夹的右键操作改由主 App 的 macOS Services 提供
    /// （见主 App 的 `ServicesProvider`）。
    private static func buildMonitoredDirectories() -> Set<URL> {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        var dirs: Set<URL> = [home]

        if let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first {
            dirs.insert(desktop)
        }

        // 已挂载的物理 / 网络卷（/Volumes/E 等外接硬盘）
        if let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            dirs.formUnion(volumes)
        }

        return dirs
    }

    // MARK: - 上下文

    private func currentContext() -> (directory: URL?, selectedItems: [URL]) {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        let target = FIFinderSyncController.default().targetedURL()
        let dir = target ?? selected.first?.deletingLastPathComponent()
        return (dir, selected)
    }

    private func resolveWorkingDirectory() -> URL? {
        let (target, selected) = currentContext()
        if let first = selected.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                return first
            }
        }
        return target
    }

    // MARK: - Directory Observation (诊断用)

    /// Finder 开始显示某个受监控目录时调用，记录原始 URL 供排查
    override func beginObservingDirectory(at url: URL) {
        logToFile("beginObserving: \(url.lastPathComponent)")
    }

    override func endObservingDirectory(at url: URL) {
        logToFile("endObserving: \(url.lastPathComponent)")
    }

    // MARK: - Context Menu

    /// 判断是否为可解压的压缩包（兼容 .tar.gz / .tar.bz2 等复合后缀）
    private func isArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        let suffixes = [".zip", ".tar", ".gz", ".tgz", ".bz2", ".tbz",
                        ".xz", ".txz", ".7z", ".rar"]
        return suffixes.contains { name.hasSuffix($0) }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menuStart = ProcessInfo.processInfo.systemUptime
        // 读取主 App 设置界面最新写入的功能开关 / 终端 / 编辑器偏好
        SharedConfig.shared.reload()

        let (directory, selected) = currentContext()
        let hasSelection = !selected.isEmpty
        let exts = selected.prefix(10).map { $0.pathExtension.lowercased() }.joined(separator: ",")
            + (selected.count > 10 ? "..." : "")
        logToFile("menu(for:) kind=\(menuKind.rawValue) selected=\(selected.count) exts=[\(exts)] dir=\(directory?.lastPathComponent ?? "nil")")

        let menu = NSMenu(title: "FinderRight")
        let style = SharedConfig.shared.menuIconStyle

        // 功能开关：默认开启，用户在设置里关闭后对应菜单项隐藏
        func featureOn(_ id: String) -> Bool { SharedConfig.shared.isActionEnabled(id) }

        let isContainerLike = menuKind == .contextualMenuForContainer
            || menuKind == .contextualMenuForSidebar
            || !hasSelection

        // 新建文件 —— 容器/侧边栏/空选中时
        if featureOn(MenuFeatureCatalog.newFile), isContainerLike {
            menu.addItem(makeSubmenuItem(titleKey: "新建文件", emoji: "📄", systemImage: "doc.badge.plus", shortcutId: "shortcut.newFile", style: style, build: { self.buildNewFileMenu(style: style) }))
        }

        if featureOn(MenuFeatureCatalog.copyPath), hasSelection {
            menu.addItem(makeItem(titleKey: "复制路径", emoji: "📋", systemImage: "doc.on.doc", action: #selector(copyPath(_:)), shortcutId: "shortcut.copyPath", style: style))
        }

        if featureOn(MenuFeatureCatalog.openTerminal) {
            menu.addItem(makeItem(titleKey: "打开终端", emoji: "💻", systemImage: "terminal", action: #selector(openTerminal(_:)), shortcutId: "shortcut.openTerminal", style: style))
        }

        if featureOn(MenuFeatureCatalog.openEditor), hasSelection {
            let editors = installedEditors()
            if !editors.isEmpty {
                menu.addItem(makeSubmenuItem(titleKey: "打开编辑器", emoji: "✏️", systemImage: "curlybraces", shortcutId: "shortcut.openEditor", style: style, build: { self.buildEditorMenu(editors, style: style) }))
            }
        }

        // 剪切 / 粘贴
        let cutPaths = currentCutQueuePaths()
        let hasCut = !cutPaths.isEmpty

        if featureOn(MenuFeatureCatalog.cut), hasSelection {
            let selectedPaths = Set(selected.map { normalizePath($0.path) })
            let alreadyCut = !selectedPaths.isEmpty && selectedPaths.isSubset(of: cutPaths)
            let cutTitleKey = alreadyCut ? "剪切 (已在剪切队列)" : "剪切"
            menu.addItem(makeItem(titleKey: cutTitleKey, emoji: "✂️", systemImage: "scissors", action: #selector(cutFiles(_:)), shortcutId: "shortcut.cut", style: style))
        }
        if featureOn(MenuFeatureCatalog.paste) {
            if hasCut || isContainerLike {
                let pasteTitleKey: String
                if hasCut {
                    // 统一用带 %d 的格式化 key：原实现按 1 / N 分支，而 strings 里只有「1 项」，
                    // 英文界面下 N>1 会回落成中文。先本地化再格式化；configureMenuItem 对
                    // 已本地化的字符串二次 L() 会原样返回，无副作用。
                    let fmt = L("粘贴 (已剪切 %d 项)")
                    pasteTitleKey = String(format: fmt, cutPaths.count)
                } else {
                    pasteTitleKey = "粘贴"
                }
                let pasteItem = makeItem(titleKey: pasteTitleKey, emoji: "📋", systemImage: "doc.on.clipboard", action: #selector(pasteFiles(_:)), shortcutId: "shortcut.paste", style: style)
                pasteItem.isEnabled = hasCut
                menu.addItem(pasteItem)
            }
        }
        // 队列非空时提供清空入口：连续剪切保持累加语义，用户需要显式「取消剪切」
        // （挂在 feature.cut 开关下，不新增 MenuFeatureCatalog 条目）
        if featureOn(MenuFeatureCatalog.cut), hasCut {
            menu.addItem(makeItem(titleKey: "取消剪切", emoji: "🚫", systemImage: "xmark.circle", action: #selector(cancelCut(_:)), shortcutId: nil, style: style))
        }

        // 压缩解压
        if featureOn(MenuFeatureCatalog.compress), hasSelection {
            menu.addItem(makeItem(titleKey: "压缩为 ZIP", emoji: "📦", systemImage: "archivebox", action: #selector(archiveOperation(_:)), shortcutId: "shortcut.compress", tag: 0, style: style))
        }
        if featureOn(MenuFeatureCatalog.decompress), hasSelection, selected.contains(where: isArchive) {
            menu.addItem(makeItem(titleKey: "解压到当前目录", emoji: "📂", systemImage: "archivebox", action: #selector(archiveOperation(_:)), shortcutId: "shortcut.decompress", tag: 2, style: style))
        }

        if featureOn(MenuFeatureCatalog.toggleHidden) {
            // 无状态固定文案：CGEvent 切换是 fire-and-forget（无回执），
            // 跨进程读 com.apple.finder 偏好又命中 cfprefsd 客户端缓存，
            // 不存在可靠的状态通道——「显示/隐藏」状态文案曾两轮实测反转，改固定文案后永不撒谎。
            menu.addItem(makeItem(titleKey: "切换隐藏文件", emoji: "👁", systemImage: "eye", action: #selector(toggleHiddenFiles(_:)), shortcutId: "shortcut.toggleHidden", style: style))
        }

        // 冷启动打点：仅首次菜单记录 init→首菜单间隔与菜单构建耗时，之后执行延后初始化
        if !didDeferredSetup {
            let sinceInitMs = (menuStart - Self.initStartUptime) * 1000
            let buildMs = (ProcessInfo.processInfo.systemUptime - menuStart) * 1000
            logToFile("coldStart: initToFirstMenu=\(String(format: "%.1f", sinceInitMs))ms firstMenuBuild=\(String(format: "%.1f", buildMs))ms")
        }
        deferredSetupIfNeeded()
        return menu
    }

    // MARK: - 菜单构建辅助

    /// 本地化菜单标题（中文做 key，en.lproj 提供英文）。
    ///
    /// 尊重设置里的「语言」选项：选 English 时直接查 en.lproj 的 Bundle，
    /// 运行时即时生效（menu(for:) 每次构建前都会 reload SharedConfig）；
    /// 选中文时直接返回 key（key 本身即中文）；跟随系统走 NSLocalizedString 默认行为。
    private static let englishBundle: Bundle? = {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    private func L(_ title: String) -> String {
        switch SharedConfig.shared.appLanguage {
        case "en":
            return Self.englishBundle?.localizedString(forKey: title, value: nil, table: nil) ?? title
        case "zh-Hans":
            return title
        default:
            return NSLocalizedString(title, comment: "menu item")
        }
    }

    /// 根据配置的图标风格（简洁 / 彩色 Emoji / 无图标）设置菜单项的标题与图标
    private func configureMenuItem(
        _ item: NSMenuItem,
        titleKey: String,
        emoji: String,
        systemImage: String?,
        style: MenuIconStyle
    ) {
        switch style {
        case .modern:
            item.title = L(titleKey)
            if let systemImage = systemImage {
                item.image = Self.getSymbolImage(named: systemImage)
            } else {
                item.image = nil
            }
        case .classic:
            let prefix = emoji.isEmpty ? "" : "\(emoji) "
            let localizedWithEmoji = L("\(prefix)\(titleKey)")
            if localizedWithEmoji != "\(prefix)\(titleKey)" {
                item.title = localizedWithEmoji
            } else {
                item.title = "\(prefix)\(L(titleKey))"
            }
            item.image = nil
        case .none:
            item.title = L(titleKey)
            item.image = nil
        }
    }

    /// 构建通用菜单项（支持快捷键、tag 与图标风格自适应）
    private func makeItem(
        titleKey: String,
        emoji: String,
        systemImage: String?,
        action: Selector? = nil,
        shortcutId: String? = nil,
        tag: Int = 0,
        style: MenuIconStyle
    ) -> NSMenuItem {
        let sc = shortcutId.flatMap { SharedConfig.shared.shortcut(forActionId: $0) }
        let key = sc?.key ?? ""
        let i = NSMenuItem(title: "", action: action, keyEquivalent: key)
        i.target = self
        i.tag = tag
        if let sc = sc, !key.isEmpty {
            i.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(sc.modifiers))
        }
        configureMenuItem(i, titleKey: titleKey, emoji: emoji, systemImage: systemImage, style: style)
        return i
    }

    private func makeSubmenuItem(
        titleKey: String,
        emoji: String,
        systemImage: String?,
        shortcutId: String? = nil,
        style: MenuIconStyle,
        build: () -> NSMenu
    ) -> NSMenuItem {
        let i = makeItem(titleKey: titleKey, emoji: emoji, systemImage: systemImage, shortcutId: shortcutId, style: style)
        i.submenu = build()
        return i
    }

    private func buildNewFileMenu(style: MenuIconStyle) -> NSMenu {
        let m = NSMenu(title: L("新建文件"))
        let types: [(nameKey: String, emoji: String, symbol: String, tag: Int)] = [
            ("文本文件 (.txt)", "📝", "doc.text", 0),
            ("Markdown (.md)", "📖", "doc.richtext", 1),
            ("HTML (.html)", "🌐", "chevron.left.forwardslash.chevron.right", 2),
            ("Python (.py)", "🐍", "terminal", 3),
            ("Shell (.sh)", "🔧", "terminal", 4),
            ("JSON (.json)", "📊", "curlybraces", 5),
            ("XML (.xml)", "📃", "doc.text", 6),
            ("CSV (.csv)", "📈", "tablecells", 7),
            ("Swift (.swift)", "🍎", "curlybraces", 8),
            ("JavaScript (.js)", "🟨", "curlybraces", 9),
        ]
        for t in types {
            let item = makeItem(titleKey: t.nameKey, emoji: t.emoji, systemImage: t.symbol, action: #selector(newFile(_:)), tag: t.tag, style: style)
            m.addItem(item)
        }

        // 自定义文件模板（D1）
        let customTemplates = SharedConfig.shared.customFileTemplates
        if !customTemplates.isEmpty {
            m.addItem(.separator())
            for (index, tmpl) in customTemplates.enumerated() {
                let tag = 1000 + index
                let title = tmpl.name.isEmpty ? ".\(tmpl.fileExtension)" : "\(tmpl.name) (.\(tmpl.fileExtension))"
                let item = makeItem(titleKey: title, emoji: "📄", systemImage: "doc.badge.plus", action: #selector(newFile(_:)), tag: tag, style: style)
                m.addItem(item)
            }
        }

        return m
    }

    // MARK: - Actions

    @objc func newFile(_ sender: NSMenuItem) {
        guard let dir = currentContext().directory else {
            logToFile("newFile: no directory"); return
        }
        let (ext, content): (String, String)
        if sender.tag >= 1000 {
            let idx = sender.tag - 1000
            let customs = SharedConfig.shared.customFileTemplates
            guard idx >= 0, idx < customs.count else {
                logToFile("newFile: custom template index out of bounds (\(idx))"); return
            }
            let tmpl = customs[idx]
            ext = tmpl.fileExtension
            content = tmpl.content
        } else {
            (ext, content) = newFileTypeInfo(for: sender.tag)
        }
        logToFile("newFile ipc (async) → dir=\(dir.lastPathComponent) tag=\(sender.tag) ext=\(ext)")
        IPCClient.shared.callAsync(action: "createFile", payload: [
            "directory": .string(dir.path),
            "baseName": .string("untitled"),
            "ext": .string(ext),
            "content": .string(content)
        ]) { r in
            logToFile("newFile ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("copyPath: no items"); return }
        let path = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        logToFile("copyPath ok: count=\(urls.count)")
    }

    @objc func openTerminal(_ sender: NSMenuItem) {
        guard let dir = resolveWorkingDirectory() else {
            logToFile("openTerminal: no dir"); return
        }
        // 使用 SharedConfig 中配置的终端
        let bundleId = SharedConfig.shared.preferredTerminal
        logToFile("openTerminal ipc (async) → dir=\(dir.lastPathComponent) bundle=\(bundleId)")
        IPCClient.shared.callAsync(action: "openTerminal", payload: [
            "directory": .string(dir.path),
            "bundleId": .string(bundleId)
        ]) { r in
            logToFile("openTerminal ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    // MARK: - 编辑器探测与图标缓存（零等待内存快照 + 后台静默刷新）
    //
    // 线程模型：快照整体由 editorCacheLock 保护（持锁时间仅为字典读写，纳秒级），
    // 耗时的 LaunchServices 查询与 icns 读取一律在 cacheQueue 串行队列的锁外完成，
    // 主线程 menu(for:) 只取快照，绝不被后台刷新阻塞。
    private struct EditorCacheSnapshot {
        var editors: [(name: String, catalogIndex: Int)] = []
        var icons: [String: NSImage] = [:]
        var lastCheckTime: TimeInterval = 0
        /// 区分「还没检测过」与「检测结果为空」——否则一台没装任何编辑器的机器
        /// 会让每次右键都走 8 次同步 LaunchServices 探测
        var hasChecked = false
    }

    private static let editorCacheLock = NSLock()
    private static var editorCache = EditorCacheSnapshot()
    /// 仅允许在 cacheQueue 串行队列上访问
    private static var isRefreshingEditors = false

    private static func editorSnapshot() -> EditorCacheSnapshot {
        editorCacheLock.lock()
        defer { editorCacheLock.unlock() }
        return editorCache
    }

    /// 启动时或后台静默刷新编辑器与图标（绝不阻塞主线程）
    static func refreshInstalledEditorsAsync() {
        cacheQueue.async {
            guard !isRefreshingEditors else { return }
            isRefreshingEditors = true
            defer { isRefreshingEditors = false }

            let existingIcons = editorSnapshot().icons
            var fresh: [(name: String, catalogIndex: Int)] = []
            var freshIcons: [String: NSImage] = [:]

            for (idx, ed) in EditorCatalog.all.enumerated() {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ed.id) {
                    fresh.append((ed.name, idx))
                    if existingIcons[ed.id] == nil {
                        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                        icon.size = NSSize(width: 16, height: 16)
                        freshIcons[ed.id] = icon
                    }
                }
            }

            editorCacheLock.lock()
            editorCache.editors = fresh
            for (k, v) in freshIcons {
                editorCache.icons[k] = v
            }
            editorCache.lastCheckTime = ProcessInfo.processInfo.systemUptime
            editorCache.hasChecked = true
            editorCacheLock.unlock()
        }
    }

    /// 检测系统已安装的编辑器：主线程 100% 只读内存快照，0ms 立即返回。
    /// 超过 5 分钟未检查时派发后台异步静默刷新，主线程绝不等待。
    private func installedEditors() -> [(name: String, catalogIndex: Int)] {
        let snap = Self.editorSnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        if !snap.hasChecked {
            // 极早触发（后台预热尚未完成）：做一次仅查 bundle 的极速同步检测，
            // 并触发异步刷新补全图标；hasChecked 置位后不再走此路径
            let fallback = EditorCatalog.all.enumerated().compactMap { idx, ed in
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: ed.id) != nil
                    ? (ed.name, idx) : nil
            }
            Self.editorCacheLock.lock()
            if !Self.editorCache.hasChecked {
                Self.editorCache.editors = fallback
                Self.editorCache.lastCheckTime = now
                Self.editorCache.hasChecked = true
            }
            let current = Self.editorCache
            Self.editorCacheLock.unlock()
            Self.refreshInstalledEditorsAsync()
            return current.editors
        }
        if now - snap.lastCheckTime > 300.0 {
            Self.refreshInstalledEditorsAsync()
        }
        return snap.editors
    }

    /// 构建「打开编辑器」子菜单。
    ///
    /// 注意：FIFinderSync 的菜单会跨进程传给 Finder 渲染，NSMenuItem 的
    /// `representedObject`（Any）在跨进程序列化时会丢失，因此必须用 `tag`（Int）
    /// 携带数据 —— 这里 tag = 编辑器在 EditorCatalog.all 中的下标。
    private func buildEditorMenu(_ editors: [(name: String, catalogIndex: Int)], style: MenuIconStyle) -> NSMenu {
        let m = NSMenu(title: L("打开编辑器"))
        let icons = style == .modern ? Self.editorSnapshot().icons : [:]
        for ed in editors {
            let item = NSMenuItem(title: ed.name, action: #selector(openEditorWith(_:)), keyEquivalent: "")
            item.target = self
            item.tag = ed.catalogIndex
            if style == .modern {
                let bundleId = EditorCatalog.all[ed.catalogIndex].id
                item.image = icons[bundleId]
            }
            m.addItem(item)
        }
        return m
    }

    @objc func openEditorWith(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard idx >= 0, idx < EditorCatalog.all.count else {
            logToFile("openEditorWith: bad tag \(idx)"); return
        }
        let bundleId = EditorCatalog.all[idx].id
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("openEditorWith: no items"); return }
        let paths = urls.map(\.path)
        logToFile("openEditorWith ipc (async) → bundle=\(bundleId) count=\(paths.count)")
        IPCClient.shared.callAsync(action: "openWithApp", payload: [
            "paths": .stringArray(paths),
            "bundleId": .string(bundleId)
        ]) { r in
            logToFile("openEditorWith ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func cutFiles(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("cutFiles: no items"); return }
        let paths = urls.map { $0.path }
        logToFile("cutFiles ipc (async) → count=\(paths.count)")

        // 立即给选中的文件打上剪切角标，提供即时视觉反馈
        for url in urls {
            FIFinderSyncController.default().setBadgeIdentifier(cutBadgeIdentifier, for: url)
        }

        IPCClient.shared.callAsync(action: "cutFiles", payload: [
            "paths": .stringArray(paths)
        ]) { r in
            logToFile("cutFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
            if r.success {
                DispatchQueue.main.async {
                    for url in urls {
                        FIFinderSyncController.default().setBadgeIdentifier(cutBadgeIdentifier, for: url)
                    }
                }
            }
        }
    }

    @objc func cancelCut(_ sender: NSMenuItem) {
        // 先清掉队列里所有文件的角标，再让主 App 删除 cut-queue.json
        let cutPaths = currentCutQueuePaths()
        logToFile("cancelCut ipc (async) → clearing \(cutPaths.count) badges")
        for path in cutPaths {
            FIFinderSyncController.default().setBadgeIdentifier("", for: URL(fileURLWithPath: path))
        }
        IPCClient.shared.callAsync(action: "cancelCut", payload: [:]) { r in
            logToFile("cancelCut ipc result: success=\(r.success) msg=\(r.message ?? "")")
            if r.success {
                DispatchQueue.main.async {
                    for path in cutPaths {
                        FIFinderSyncController.default().setBadgeIdentifier("", for: URL(fileURLWithPath: path))
                    }
                }
            }
        }
    }

    @objc func pasteFiles(_ sender: NSMenuItem) {
        // 粘贴目标始终是 Finder 当前正在浏览的目录（targetedURL），
        // 而不是选中的项——否则当用户选中一个子文件夹时会错误地粘贴进去。
        guard let destDir = FIFinderSyncController.default().targetedURL() else {
            logToFile("pasteFiles: no destination directory"); return
        }
        let cutPaths = currentCutQueuePaths()
        logToFile("pasteFiles ipc (async) → destDir=\(destDir.lastPathComponent) pendingCutCount=\(cutPaths.count)")

        // 立即清除待粘贴源文件的剪切角标
        for path in cutPaths {
            let u = URL(fileURLWithPath: path)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u)
        }

        IPCClient.shared.callAsync(action: "pasteFiles", payload: [
            "destination": .string(destDir.path)
        ]) { r in
            logToFile("pasteFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func archiveOperation(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("archiveOperation: no items"); return }
        let paths = urls.map(\.path)
        logToFile("archiveOperation ipc (async) → tag=\(sender.tag) count=\(paths.count)")

        switch sender.tag {
        case 0:
            IPCClient.shared.callAsync(action: "compressZip", payload: ["items": .stringArray(paths)], timeout: 30) { r in
                logToFile("compressZip ipc result: success=\(r.success) msg=\(r.message ?? "")")
            }
        case 2:
            DispatchQueue.global(qos: .userInitiated).async {
                var firstErr: String?
                for p in paths {
                    let one = IPCClient.shared.call(action: "decompress",
                                                    payload: ["archive": .string(p)],
                                                    timeout: 30)
                    if !one.success, firstErr == nil { firstErr = one.message }
                }
                logToFile("decompress ipc result: success=\(firstErr == nil) msg=\(firstErr ?? "")")
            }
        default:
            return
        }
    }

    @objc func toggleHiddenFiles(_ sender: NSMenuItem) {
        logToFile("toggleHiddenFiles clicked (async)")
        IPCClient.shared.callAsync(action: "toggleHiddenFiles", payload: [:]) { r in
            logToFile("toggleHiddenFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    // MARK: - Utility

    private func newFileTypeInfo(for tag: Int) -> (ext: String, content: String) {
        switch tag {
        case 0: return ("txt", "")
        case 1: return ("md", "# Untitled\n\n")
        case 2: return ("html", "<!DOCTYPE html>\n<html lang=\"en\">\n<head><meta charset=\"UTF-8\"><title>Untitled</title></head>\n<body>\n</body>\n</html>\n")
        case 3: return ("py", "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\n\n")
        case 4: return ("sh", "#!/bin/bash\n\n")
        case 5: return ("json", "{\n    \n}\n")
        case 6: return ("xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n</root>\n")
        case 7: return ("csv", "")
        case 8: return ("swift", "import Foundation\n\n")
        case 9: return ("js", "\"use strict\";\n\n")
        default: return ("txt", "")
        }
    }
}
