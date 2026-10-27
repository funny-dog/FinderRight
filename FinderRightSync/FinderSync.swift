import Cocoa
import FinderSync
import FinderRightKit

// MARK: - FinderSync

class FinderSync: FIFinderSync {

    // MARK: - 静态图标与资源缓存（零 I/O、零解析延迟）
    static let cacheQueue = DispatchQueue(label: "com.finderright.app.sync.cache", qos: .utility)

    private static func getSymbolImage(named name: String) -> NSImage? {
        MenuIconRenderer.image(symbol: name, tint: .graphite, style: .modern)
    }

    private static func preloadSymbols() {
        let symbols = [
            "doc.badge.plus", "link", "character.cursor.ibeam", "arrow.right.circle",
            "terminal", "curlybraces", "scissors", "doc.on.clipboard", "xmark.circle",
            "arrowshape.turn.up.right", "plus.square.on.square", "doc.zipper",
            "shippingbox.and.arrow.backward", "eye", "number", "link.badge.plus"
        ]
        for s in symbols {
            _ = getSymbolImage(named: s)
        }
    }

    /// 冷启动打点：init 入口时间（进程被拉起后尽早记录）
    private static var initStartUptime: TimeInterval = 0
    private var didDeferredSetup = false
    /// 当前构建的新建文件菜单项缓存，供 newFile(_ sender:) 按 tag 索引
    var activeNewFileTemplates: [NewFileTemplateItem] = []
    static let favoriteAvailability = FavoriteDirectoryAvailability()

    override init() {
        Self.initStartUptime = ProcessInfo.processInfo.systemUptime
        super.init()

        // init 路径刻意保持极简：只有 directoryURLs 注册是扩展工作的前提。
        // 符号预热等全部延后到首次 menu(for:) 之后（见 deferredSetupIfNeeded），
        // 让系统回收扩展后的首次右键等待时间降到最低。
        let dirs = Self.buildMonitoredDirectories()
        FIFinderSyncController.default().directoryURLs = dirs

        // 注册剪切状态文件角标徽章（Finder 文件图标右下角显示）。
        // label 只是角标的辅助功能描述，界面上不可见，用字面量即可；菜单文案的本地化走 L()。
        logToFile("setBadgeImage registering: \(cutBadgeIdentifier)")
        FIFinderSyncController.default().setBadgeImage(createCutBadgeImage(), label: "已剪切", forBadgeIdentifier: cutBadgeIdentifier)
        logToFile("setBadgeImage registered for \(cutBadgeIdentifier)")

        // 服务快捷键剪切 / 粘贴由主 App 直接处理，扩展只能靠这条通知得知队列变化。
        // 必须在 init 注册：只用快捷键、从不展开右键菜单时，延后初始化永远不会执行。
        CutQueueChangeNotifier.observe { [weak self] in self?.handleCutQueueChanged() }

        // 后台预热编辑器与图标（派发即返回，不阻塞 init）
        Self.refreshInstalledEditorsAsync()
        DispatchQueue.global(qos: .utility).async {
            _ = Self.favoriteAvailability.unavailablePaths(in: SharedConfig.shared.favoriteDirectories)
        }

        let initMs = (ProcessInfo.processInfo.systemUptime - Self.initStartUptime) * 1000
        // 版本号写进日志：排查角标/回调问题时必须能区分「装的是哪一版扩展」
        let extVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        logToFile("init done: pid=\(getpid()) v\(extVersion) \(String(format: "%.1f", initMs))ms monitoredDirs=\(dirs.map(\.path).sorted())")
    }

    // MARK: - 文件角标徽章回调

    /// ⚠️ 角标归属权：同一个目录被多个 Finder Sync 扩展注册时，Finder 只把
    /// requestBadgeIdentifier 交给**最先注册**该目录的扩展（即使它根本不用角标），
    /// 其余扩展只收到 beginObserving / 菜单回调，setBadgeIdentifier 也不会显示。
    /// 各扩展随 Finder 启动并发注册，先后顺序不确定，于是表现为「同一二进制有的会话
    /// 0 次回调、有的会话 200+ 次」。参考：Keka issue #608、FB7711264、Apple DTS 答复
    /// （Finder Sync 按「一个目录一个后备扩展」设计，重叠时归属不可靠）。
    ///
    /// 2026-10-02 实测：Keka 的 MonitoredURLs 与本扩展完全重叠（~/Desktop、~/Documents、
    /// ~/Downloads、/Volumes），是角标时有时无的直接原因；本扩展进程重启（例如重复
    /// `pluginkit -a`）会让我们成为最后注册者，重叠目录全部失去归属。
    ///
    /// 应对：收到本回调即证明持有该目录归属（记入 badgeProbe）；观察了目录却收不到时，
    /// 请主 App 短暂重启其他扩展取回归属（见 requestBadgeReclaimIfNeeded）。
    override func requestBadgeIdentifier(for url: URL) {
        withBadgeProbe { $0.recordBadgeRequest(itemPath: url.path) }
        // 热路径：大目录会为每个可见文件回调一次。不逐项写日志（性能 + 不留浏览记录）
        if currentCutQueuePaths().contains(normalizePath(url.path)) {
            logToFile("requestBadgeIdentifier: 剪切项 \(url.lastPathComponent)")
            setCutBadge(for: url)
            return
        }
        // 本进程从未打过剪切角标时，Finder 上不可能有我们的旧角标，无需逐个发清除消息
        cutBadgeLock.lock()
        let mayHaveStaleBadge = didSetCutBadge
        cutBadgeLock.unlock()
        if mayHaveStaleBadge {
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
        }
    }

    /// 首次菜单回调返回后执行一次，避免预热和卷枚举阻塞菜单交付。
    private func deferredSetupIfNeeded() {
        guard !didDeferredSetup else { return }
        didDeferredSetup = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // SF Symbols 预热（getSymbolImage 本身带懒缓存兜底，这里只是提前摊销）
            Self.preloadSymbols()

            // 卷挂载监听延后注册，并补并一次 init 之后、监听注册之前挂载的卷（集合未变化时不会重设）。
            // 只监听挂载、不监听卸载（见 volumeDidMount）。
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(volumeDidMount(_:)),
                name: NSWorkspace.didMountNotification, object: nil)
            self.mergeMountedVolumes()
            logToFile("deferredSetup done")
        }
    }

    /// 新卷挂载：把新卷并入监控集合。
    ///
    /// 重新设置 directoryURLs 等于重新注册，会让本扩展排到重叠扩展之后、可能丢失角标归属，
    /// 所以：只并入、不剔除（卸载卷的残留路径无害，不为它重设）；集合未变化时不重设；
    /// 重设后开启新的探测轮次，由归属探测 / 剪切兜底按需重新抢回。
    @objc func volumeDidMount(_ n: Notification) {
        mergeMountedVolumes()
    }

    private func mergeMountedVolumes() {
        let current = FIFinderSyncController.default().directoryURLs ?? []
        let merged = current.union(Self.buildMonitoredDirectories())
        guard merged != current else { return }
        FIFinderSyncController.default().directoryURLs = merged
        withBadgeProbe { $0.beginNewRegistrationEpoch() }
        logToFile("mergeMountedVolumes: directoryURLs 重新注册 count=\(merged.count)，开启新一轮角标归属探测")
    }

    /// 构建需要监控的目录集合：用户主目录 + 桌面/下载/文稿 + 已挂载卷。
    ///
    /// ⚠️ 外接卷必须逐个注册：2026-10-02 实测只注册 `/Volumes` 时，Finder 对 `/Volumes/E`
    /// 等卷内目录**不会**回调 beginObserving / menu(for:)（目录匹配按卷进行，不跨卷继承）。
    /// 这也是挂载新卷时不得不重新设置 directoryURLs 的原因（见 volumeDidMount）。
    ///
    /// FIFinderSync 只有当 Finder 当前目录在 directoryURLs 集合内（或其子目录内）时，
    /// 才会触发右键菜单与 requestBadgeIdentifier 回调。
    ///
    /// 这里显式列出 Desktop / Downloads / Documents 的真实路径，而不用
    /// `FileManager.urls(for:in:)`：沙箱 appex 里后者返回的是容器内私有路径
    /// （实测：…/Library/Containers/com.finderright.app.sync/Data/Desktop，且该目录并不存在），
    /// 注册等于没注册。真实目录本已被 home 覆盖，显式再列一次是无害的兜底。
    /// 注意：精确注册这些目录**不能**帮我们赢得角标归属 —— 其他扩展（如 Keka）注册了
    /// 完全相同的路径时仍是先注册者胜出（见 requestBadgeIdentifier 处的说明）。
    ///
    /// 注意：iCloud Drive、Google Drive 等云盘是 macOS 的 **File Provider 域**，目录归提供者
    /// 自己的扩展。Apple DTS 说明 Finder Sync 按「一个目录只归属一个扩展」设计，第三方扩展
    /// 本就不应期望在其中生效（https://github.com/aonez/Keka/issues/1327 中转述的 DTS 答复）。
    /// 实测：对这些路径的 directoryURLs 注册（含经安全书签授予目录访问后）不会触发
    /// `beginObservingDirectory` / `menu(for:)` 回调，且与完全磁盘访问无关 —— 那是文件权限，
    /// 这是扩展点按目录归属的路由。
    /// 因此这里不再尝试注册云盘路径；云盘文件夹的右键操作改由主 App 的 macOS Services 提供
    /// （见主 App 的 `ServicesProvider`）。
    private static func buildMonitoredDirectories() -> Set<URL> {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        var dirs: Set<URL> = [
            home,
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Documents")
        ]

        // 已挂载的物理 / 网络卷（/Volumes/E 等外接硬盘；也可能是 ~/OrbStack 这类挂载点）。
        // 不包含启动卷 /：系统目录的右键操作由 Services 覆盖。
        if let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            for vol in volumes {
                let p = vol.path
                if p != "/" && !p.hasPrefix("/System") && !p.hasPrefix("/private") {
                    dirs.insert(vol)
                }
            }
        }

        return dirs
    }

    // MARK: - 上下文

    func currentContext() -> (directory: URL?, selectedItems: [URL]) {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        let target = FIFinderSyncController.default().targetedURL()
        let dir = target ?? selected.first?.deletingLastPathComponent()
        return (dir, selected)
    }

    func resolveWorkingDirectory() -> URL? {
        let (target, selected) = currentContext()
        if let first = selected.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                return first
            }
        }
        return target
    }

    // MARK: - Directory Observation

    /// Finder 开始显示某个受监控目录时调用。目录内有剪切项、且本进程首次观察该目录时，顺带做一次角标归属探测：
    /// 持有归属的扩展会在同一秒内收到目录内可见项的 requestBadgeIdentifier，收不到则可能已丢失。
    override func beginObservingDirectory(at url: URL) {
        logToFile("beginObserving: \(url.path)")
        let dir = url.path
        // 只为确实含有剪切项的目录探测归属：没有剪切项就不需要角标，不应为此重启其他扩展
        guard BadgeOwnershipProbe.directory(dir, containsAnyOf: currentCutQueuePaths()) else { return }
        guard withBadgeProbe({ $0.beginProbe(directory: dir) }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + badgeProbeDelay) { [weak self] in
            // 等待期间可能已粘贴或取消剪切，届时同样不再需要抢回
            guard BadgeOwnershipProbe.directory(dir, containsAnyOf: currentCutQueuePaths()) else { return }
            self?.requestBadgeReclaimIfNeeded(directory: dir, reason: "probe")
        }
    }

    /// 剪切队列被主 App 改写：对齐角标；快捷键剪切与右键剪切一样，需为新剪切项所在目录兜底抢回角标归属，
    /// 否则目录归属在别的 Finder Sync 扩展手里时角标根本不显示，看起来像「剪切没生效」。
    private func handleCutQueueChanged() {
        let added = reconcileCutBadgesWithQueue()
        let parents = Set(added.map { ($0 as NSString).deletingLastPathComponent })
        for dir in parents {
            requestBadgeReclaimIfNeeded(directory: dir, reason: "cut")
        }
    }

    override func endObservingDirectory(at url: URL) {
        logToFile("endObserving: \(url.path)")
    }

    // MARK: - 角标归属抢回

    /// 目录归属未确认时，请主 App 短暂重启其他 Finder Sync 扩展以取回角标归属。
    ///
    /// - reason `probe`：目录观察后的被动探测。主 App 未运行时不发（IPC 会唤醒主 App，
    ///   不应因被动探测拉起用户主动退出的 App），留给剪切时兜底。
    /// - reason `cut`：剪切时兜底，剪切本身就会唤醒主 App。
    ///
    /// 配额与并发由 BadgeOwnershipProbe 约束：每进程至多受理一次、同一时刻一个在途请求；
    /// 探测撞上在途请求时稍后重试，确保同时观察的多个目录不会被漏判。
    func requestBadgeReclaimIfNeeded(directory: String, reason: String) {
        let (owned, inFlight, allowed) = withBadgeProbe {
            ($0.isOwned(directory: directory), $0.reclaimInFlight, $0.canRequestReclaim(directory: directory))
        }
        if owned {
            if reason == "probe" { logToFile("badgeProbe dir=\(directory) owned") }
            return
        }
        if inFlight {
            if reason == "probe" {
                DispatchQueue.main.asyncAfter(deadline: .now() + badgeProbeDelay) { [weak self] in
                    self?.requestBadgeReclaimIfNeeded(directory: directory, reason: reason)
                }
            }
            return
        }
        guard allowed else { return }

        SharedConfig.shared.reload()
        guard SharedConfig.shared.badgeOwnershipReclaim else {
            logToFile("badgeProbe dir=\(directory) lost（自动解决角标冲突已关闭）")
            return
        }
        if reason == "probe",
           NSRunningApplication.runningApplications(withBundleIdentifier: IPCBridge.mainAppBundleIdentifier).isEmpty {
            logToFile("badgeProbe dir=\(directory) lost（主 App 未运行，留待剪切时兜底）")
            return
        }

        withBadgeProbe { $0.noteReclaimAttempt() }
        logToFile("badgeReclaim request reason=\(reason) dir=\(directory)")
        IPCClient.shared.callAsync(action: BadgeReclaimIPC.action, payload: [
            "directory": .string(directory),
            "requester": .string(withBadgeProbe { $0.requesterId(pid: getpid()) }),
            "reason": .string(reason)
        ], timeout: 5) { r in
            let outcome = BadgeReclaimOutcome(success: r.success, message: r.message)
            withBadgeProbe { $0.noteReclaimResponse(directory: directory, outcome: outcome) }
            guard outcome == .accepted else {
                logToFile("badgeReclaim rejected dir=\(directory) msg=\(r.message ?? "")")
                return
            }
            logToFile("badgeReclaim accepted dir=\(directory)")
            DispatchQueue.main.asyncAfter(deadline: .now() + badgeReclaimVerifyDelay) {
                let regained = withBadgeProbe { $0.isOwned(directory: directory) }
                logToFile(regained
                    ? "badgeReclaim verified dir=\(directory)"
                    : "badgeReclaim still lost dir=\(directory)（可能来自 File Provider 域等无法处理的接管）")
            }
        }
    }

    // MARK: - Context Menu

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

        // 在窗口空白处右键（容器菜单）时，Finder 会把当前目录本身放进 selectedItemURLs()，
        // hasSelection 因此为真。复制路径、打开编辑器作用于当前目录无害且有用，照常显示；
        // 但剪切 / 移动到 / 复制到 / 压缩会改动当前目录本身，必须是用户真正选中了条目才显示
        let hasExplicitSelection = hasSelection && menuKind != .contextualMenuForContainer

        // 剪切队列状态：剪切 / 粘贴 / 取消剪切的显示与文案都依赖它
        let cutPaths = currentCutQueuePaths()
        let hasCut = !cutPaths.isEmpty

        // 兜底刷新角标：对仍处于剪切队列的选中项再推一次角标标识，覆盖重绘时序问题。
        // 注意这只在本扩展持有该目录角标归属时有效；归属被其他扩展占走时推多少次都不会显示
        // （见 requestBadgeIdentifier 处的说明）。
        // 上限 50 项，避免「全选大目录」时拖慢菜单构建。
        if hasSelection, hasCut {
            var pushed = 0
            for url in selected.prefix(50) where cutPaths.contains(normalizePath(url.path)) {
                setCutBadge(for: url)
                pushed += 1
            }
            if pushed > 0 { logToFile("menu(for:) badge refresh: \(pushed) cut item(s)") }
        }

        let cancelCutItem = { self.makeItem(titleKey: "取消剪切", tint: .red, systemImage: "xmark.circle", action: #selector(self.cancelCut(_:)), shortcutId: nil, style: style) }

        // 每个功能一个构建闭包，按用户在设置里拖拽排好的顺序依次添加。
        // 显示条件与功能开关在闭包内判断；「取消剪切」没有独立开关，依附在剪切之后、随剪切一起排序
        let builders: [String: () -> Void] = [
            MenuFeatureCatalog.undo: {
                // 主 App 有可撤销的记录时才写这个状态文件；文件里只有显示信息，不含路径
                guard let state = UndoMenuState.read() else { return }
                let item = self.makeItem(titleKey: "撤销", tint: .gray, systemImage: "arrow.uturn.backward", action: #selector(self.undoLast(_:)), shortcutId: "shortcut.undo", style: style)
                item.title = UndoText.menuTitle(for: state, localize: self.L)
                menu.addItem(item)
            },
            MenuFeatureCatalog.newFile: {
                // 新建文件 —— 容器/侧边栏/空选中时
                guard isContainerLike else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "新建文件", tint: .blue, systemImage: "doc.badge.plus", shortcutId: "shortcut.newFile", style: style, build: { self.buildNewFileMenu(style: style) }))
            },
            MenuFeatureCatalog.copyPath: {
                guard hasSelection else { return }
                menu.addItem(self.makeItem(titleKey: "复制路径", tint: .indigo, systemImage: "link", action: #selector(self.copyPath(_:)), shortcutId: "shortcut.copyPath", style: style))
            },
            MenuFeatureCatalog.copyFileName: {
                guard hasSelection else { return }
                menu.addItem(self.makeItem(titleKey: "复制文件名", tint: .indigo, systemImage: "character.cursor.ibeam", action: #selector(self.copyFileName(_:)), shortcutId: "shortcut.copyFileName", style: style))
            },
            MenuFeatureCatalog.copyFileContent: {
                // 仅单选普通文本文件且在大小限制内时显示
                guard selected.count == 1, let url = selected.first else { return }
                guard FileContentReader.isEligible(url: url, maxBytes: SharedConfig.shared.copyFileContentMaxBytes) else { return }
                menu.addItem(self.makeItem(titleKey: "复制文件内容", tint: .teal, systemImage: "doc.plaintext", action: #selector(self.copyFileContent(_:)), shortcutId: "shortcut.copyFileContent", style: style))
            },
            MenuFeatureCatalog.copyFileHash: {
                // 至少有一个普通文件才显示；只看前 50 项，避免全选大目录时拖慢菜单
                guard hasSelection, selected.prefix(50).contains(where: FileHasher.isRegularFile) else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "复制哈希", tint: .teal, systemImage: "number", shortcutId: nil, style: style, build: { self.buildHashMenu() }))
            },
            MenuFeatureCatalog.goToDirectory: {
                menu.addItem(self.makeItem(titleKey: "打开路径…", tint: .cyan, systemImage: "arrow.right.circle", action: #selector(self.goToDirectory(_:)), shortcutId: "shortcut.goToDirectory", style: style))
            },
            MenuFeatureCatalog.openTerminal: {
                let config = SharedConfig.shared
                let terminals = TerminalCatalog.menuTerminals(
                    selected: config.selectedTerminals, preferred: config.preferredTerminal,
                    order: config.terminalOrder)
                guard !terminals.isEmpty else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "打开终端", tint: .graphite, systemImage: "terminal", shortcutId: "shortcut.openTerminal", style: style, build: { self.buildTerminalMenu(terminals, style: style) }))
            },
            MenuFeatureCatalog.openEditor: {
                guard hasSelection else { return }
                let editors = self.installedEditors()
                guard !editors.isEmpty else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "打开编辑器", tint: .purple, systemImage: "curlybraces", shortcutId: "shortcut.openEditor", style: style, build: { self.buildEditorMenu(editors, style: style) }))
            },
            MenuFeatureCatalog.cut: {
                if hasExplicitSelection {
                    let selectedPaths = Set(selected.map(\.path))
                    let alreadyCut = !selectedPaths.isEmpty && selectedPaths.isSubset(of: cutPaths)
                    let cutTitleKey = alreadyCut ? "剪切 (已在剪切队列)" : "剪切"
                    menu.addItem(self.makeItem(titleKey: cutTitleKey, tint: .orange, systemImage: "scissors", action: #selector(self.cutFiles(_:)), shortcutId: "shortcut.cut", style: style))
                }
                if hasCut {
                    menu.addItem(cancelCutItem())
                }
            },
            MenuFeatureCatalog.paste: {
                if hasCut || isContainerLike {
                    let pasteTitleKey = hasCut
                        ? String(format: self.L("粘贴 (已剪切 %d 项)"), cutPaths.count)
                        : "粘贴"
                    let pasteItem = self.makeItem(titleKey: pasteTitleKey, tint: .orange, systemImage: "doc.on.clipboard", action: #selector(self.pasteFiles(_:)), shortcutId: "shortcut.paste", style: style)
                    pasteItem.isEnabled = hasCut
                    menu.addItem(pasteItem)
                }
            },
            MenuFeatureCatalog.moveTo: {
                guard hasExplicitSelection else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "移动到", tint: .green, systemImage: "arrowshape.turn.up.right", shortcutId: nil, style: style, build: { self.buildFavoritesMenu(mode: .move, selected: selected, style: style) }))
            },
            MenuFeatureCatalog.copyTo: {
                guard hasExplicitSelection else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "复制到", tint: .green, systemImage: "plus.square.on.square", shortcutId: nil, style: style, build: { self.buildFavoritesMenu(mode: .copy, selected: selected, style: style) }))
            },
            MenuFeatureCatalog.createSymlink: {
                guard hasExplicitSelection else { return }
                menu.addItem(self.makeItem(titleKey: "创建符号链接", tint: .green, systemImage: "link.badge.plus", action: #selector(self.createSymlink(_:)), shortcutId: nil, style: style))
            },
            MenuFeatureCatalog.compress: {
                guard hasExplicitSelection else { return }
                menu.addItem(self.makeItem(titleKey: "压缩为 ZIP", tint: .brown, systemImage: "doc.zipper", action: #selector(self.archiveOperation(_:)), shortcutId: "shortcut.compress", tag: 0, style: style))
            },
            MenuFeatureCatalog.decompress: {
                guard hasSelection, selected.contains(where: { ArchiveKind.isArchive(fileName: $0.lastPathComponent) }) else { return }
                menu.addItem(self.makeItem(titleKey: "解压到当前目录", tint: .brown, systemImage: "shippingbox.and.arrow.backward", action: #selector(self.archiveOperation(_:)), shortcutId: "shortcut.decompress", tag: 2, style: style))
            },
            MenuFeatureCatalog.toggleHidden: {
                // 无状态固定文案：CGEvent 切换是 fire-and-forget（无回执），跨进程读
                // com.apple.finder 偏好又命中 cfprefsd 客户端缓存，**不存在可靠的状态通道** ——
                // 「显示/隐藏」状态文案曾两轮实测反转（并留下过 settings.plist 里的死值
                // showHiddenFiles，该键已彻底删除）。固定文案永不撒谎，代价是不显示当前状态。
                // 因此主 App 启动时也不需要把任何状态锚定到 Finder 真实状态（见 FinderRightApp）。
                menu.addItem(self.makeItem(
                    titleKey: "切换隐藏文件",
                    tint: .pink,
                    systemImage: "eye",
                    action: #selector(self.toggleHiddenFiles(_:)),
                    shortcutId: "shortcut.toggleHidden",
                    style: style
                ))
            },
        ]

        for feature in MenuFeatureCatalog.ordered(by: SharedConfig.shared.menuOrder) where featureOn(feature.id) {
            builders[feature.id]?()
        }

        // 「取消剪切」平时紧跟「剪切」，但它不能跟着「剪切」开关一起消失：
        // 用户可能先剪切了一批文件，再到设置里关掉「剪切」，此时队列仍在，
        // 没有入口就只能靠「粘贴」或重启 App 才能清掉。开关关掉时补在「粘贴」后面。
        if hasCut, !featureOn(MenuFeatureCatalog.cut) {
            let item = cancelCutItem()
            let pasteIndex = menu.items.firstIndex { $0.action == #selector(self.pasteFiles(_:)) }
            if let pasteIndex {
                menu.insertItem(item, at: pasteIndex + 1)
            } else {
                menu.addItem(item)
            }
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

    private static let englishBundle: Bundle? = {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    /// 本地化菜单标题（按 SharedConfig.appLanguage 选择资源或系统本地化）
    func L(_ title: String) -> String {
        switch SharedConfig.shared.appLanguage {
        case "en":
            return Self.englishBundle?.localizedString(forKey: title, value: nil, table: nil) ?? title
        case "zh-Hans":
            return title
        default:
            return NSLocalizedString(title, comment: "menu item")
        }
    }

    /// 根据配置的图标风格（单色线条 / 彩色线条 / 彩色方块 / 无图标）设置菜单项的标题与图标
    private func configureMenuItem(
        _ item: NSMenuItem,
        titleKey: String,
        tint: MenuTint,
        systemImage: String?,
        style: MenuIconStyle
    ) {
        item.title = L(titleKey)
        guard let systemImage else {
            item.image = nil
            return
        }
        switch style {
        case .modern:
            item.image = Self.getSymbolImage(named: systemImage)
        case .tinted, .tile:
            item.image = MenuIconRenderer.image(symbol: systemImage, tint: tint, style: style)
        case .none:
            item.image = nil
        }
    }

    /// 构建通用菜单项（支持快捷键、tag 与图标风格自适应）
    func makeItem(
        titleKey: String,
        tint: MenuTint,
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
        configureMenuItem(i, titleKey: titleKey, tint: tint, systemImage: systemImage, style: style)
        return i
    }

    private func makeSubmenuItem(
        titleKey: String,
        tint: MenuTint,
        systemImage: String?,
        shortcutId: String? = nil,
        style: MenuIconStyle,
        build: () -> NSMenu
    ) -> NSMenuItem {
        let i = makeItem(titleKey: titleKey, tint: tint, systemImage: systemImage, shortcutId: shortcutId, style: style)
        i.setSubmenuOrSingleAction(build())
        return i
    }

    private func buildNewFileMenu(style: MenuIconStyle) -> NSMenu {
        let m = NSMenu(title: L("新建文件"))
        let customTemplates = SharedConfig.shared.customFileTemplates
        let order = SharedConfig.shared.newFileOrder
        let hidden = SharedConfig.shared.hiddenNewFileTemplates
        let allTemplates = NewFileTemplateCatalog.resolvedTemplates(order: order, customTemplates: customTemplates)
        let activeTemplates = allTemplates.filter { !hidden.contains($0.id) }
        self.activeNewFileTemplates = activeTemplates

        for (index, item) in activeTemplates.enumerated() {
            let title = item.isCustom ? (item.name.isEmpty ? ".\(item.fileExtension)" : "\(item.name) (.\(item.fileExtension))") : item.name
            let menuItem = makeItem(titleKey: title, tint: item.tint, systemImage: item.systemImage, action: #selector(newFile(_:)), tag: index, style: style)
            m.addItem(menuItem)
        }

        return m
    }

    /// 「打开终端」子菜单项对应的终端 id，按 tag 索引
    var terminalMenuIds: [String] = []

}
