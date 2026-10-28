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

        let style = SharedConfig.shared.menuIconStyle

        // 剪切队列状态：剪切 / 粘贴 / 取消剪切的显示与文案都依赖它
        let cutPaths = currentCutQueuePaths()
        let hasCut = !cutPaths.isEmpty

        // 兜底刷新角标：对仍处于剪切队列的选中项再推一次角标标识，覆盖重绘时序问题
        if hasSelection, hasCut {
            var pushed = 0
            for url in selected.prefix(50) where cutPaths.contains(normalizePath(url.path)) {
                setCutBadge(for: url)
                pushed += 1
            }
            if pushed > 0 { logToFile("menu(for:) badge refresh: \(pushed) cut item(s)") }
        }

        // 解析位置
        let location: MenuTargetLocation
        switch menuKind {
        case .contextualMenuForContainer:
            location = .container
        case .contextualMenuForSidebar:
            location = .sidebar
        case .contextualMenuForItems:
            location = .items
        case .toolbarItemMenu:
            location = .items
        @unknown default:
            location = .items
        }

        // 解析选中项类型
        let selectionKind: SelectionKind
        if selected.isEmpty {
            selectionKind = .empty
        } else if selected.count == 1, let first = selected.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                selectionKind = .singleFolder
            } else {
                let isText = FileContentReader.isEligible(url: first, maxBytes: SharedConfig.shared.copyFileContentMaxBytes)
                let isArchive = ArchiveKind.isArchive(fileName: first.lastPathComponent)
                selectionKind = .singleFile(isTextEligible: isText, isArchive: isArchive, isRegularFile: FileHasher.isRegularFile(first))
            }
        } else {
            let hasRegular = selected.prefix(50).contains(where: FileHasher.isRegularFile)
            let hasArchives = selected.contains(where: { ArchiveKind.isArchive(fileName: $0.lastPathComponent) })
            selectionKind = .multiple(count: selected.count, hasRegularFiles: hasRegular, hasArchives: hasArchives)
        }

        // 剪切队列状态判断
        let selectedPaths = Set(selected.map(\.path))
        let isSubset = !selectedPaths.isEmpty && selectedPaths.isSubset(of: cutPaths)
        let cutState = CutState(count: cutPaths.count, isSelectionSubsetOfCut: isSubset)

        // 新建文件模板缓存与纯数据
        let customTemplates = SharedConfig.shared.customFileTemplates
        let order = SharedConfig.shared.newFileOrder
        let hidden = SharedConfig.shared.hiddenNewFileTemplates
        let allTemplates = NewFileTemplateCatalog.resolvedTemplates(order: order, customTemplates: customTemplates)
        let activeTemplates = allTemplates.filter { !hidden.contains($0.id) }
        self.activeNewFileTemplates = activeTemplates
        let templateData = activeTemplates.enumerated().map { index, item in
            let name = item.isCustom ? (item.name.isEmpty ? ".\(item.fileExtension)" : "\(item.name) (.\(item.fileExtension))") : item.name
            return MenuTemplateData(id: item.id, displayName: name, systemImage: item.systemImage, tint: item.tint, tag: index, isCustom: item.isCustom)
        }

        // 终端配置与纯数据
        let terminals = TerminalCatalog.menuTerminals(
            selected: SharedConfig.shared.selectedTerminals,
            preferred: SharedConfig.shared.preferredTerminal,
            order: SharedConfig.shared.terminalOrder)
        self.terminalMenuIds = terminals.map(\.bundleIdentifier)
        let terminalData = terminals.enumerated().map { index, t in
            MenuTerminalData(bundleIdentifier: t.bundleIdentifier, name: t.name, icon: t.icon, tag: index)
        }

        // 编辑器配置与纯数据
        let editors = self.installedEditors()
        cacheEditorMenuIds(editors)
        let editorData = editors.enumerated().map { index, e in
            MenuEditorData(bundleIdentifier: e.id, name: e.name, icon: nil, tag: index)
        }

        // 常用目录配置与纯数据
        let favorites = SharedConfig.shared.orderedFavoriteDirectories
        let unavailable = Self.favoriteAvailability.unavailablePaths(in: favorites)
        let names = FavoriteDirectories.displayNames(for: favorites, home: IPCBridge.realUserHomeDirectory.path)
        let favoriteData = zip(favorites, names).enumerated().map { index, pair in
            let (path, name) = pair
            let isUnav = unavailable.contains(path)
            let canTransfer = !isUnav && selected.contains {
                FileTransferCheck.check(source: normalizePath($0.path), destinationDirectory: path, mode: .move) == .ok
            }
            let canCopy = !isUnav && selected.contains {
                FileTransferCheck.check(source: normalizePath($0.path), destinationDirectory: path, mode: .copy) == .ok
            }
            return MenuFavoriteData(path: path, displayName: name, isUnavailable: isUnav, canTransfer: canTransfer, tag: index, canCopy: canCopy)
        }

        let undoTitle: String? = UndoMenuState.read().map { UndoText.menuTitle(for: $0, localize: self.L) }
        let imageState: ImageMenuState? = location != .container
            && SharedConfig.shared.isActionEnabled(MenuFeatureCatalog.imageTools)
            ? ImageMenuState.evaluate(selection: selected) : nil

        let input = MenuBuildInput(
            location: location,
            selection: selectionKind,
            enabledFeatureIds: Set(MenuFeatureCatalog.all.map(\.id).filter { SharedConfig.shared.isActionEnabled($0) }),
            menuOrder: SharedConfig.shared.menuOrder,
            cutState: cutState,
            undoTitle: undoTitle,
            newFileTemplates: templateData,
            terminals: terminalData,
            editors: editorData,
            favoriteDirectories: favoriteData,
            imageMenuState: imageState
        )

        let nodes = MenuTreeBuilder.buildMenuTree(input: input)
        let menu = renderMenu(nodes: nodes, editors: editors, style: style)

        // 冷启动打点：仅首次菜单记录 init→首菜单间隔与菜单构建耗时，之后执行延后初始化
        if !didDeferredSetup {
            let sinceInitMs = (menuStart - Self.initStartUptime) * 1000
            let buildMs = (ProcessInfo.processInfo.systemUptime - menuStart) * 1000
            logToFile("coldStart: initToFirstMenu=\(String(format: "%.1f", sinceInitMs))ms firstMenuBuild=\(String(format: "%.1f", buildMs))ms")
        }
        deferredSetupIfNeeded()
        return menu
    }

    // MARK: - 菜单构建与渲染

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

    func selector(for actionId: String) -> Selector? {
        switch actionId {
        case "newFile": return #selector(self.newFile(_:))
        case "copyPath": return #selector(self.copyPath(_:))
        case "copyFileName": return #selector(self.copyFileName(_:))
        case "copyFileContent": return #selector(self.copyFileContent(_:))
        case "copyFileHash": return #selector(self.copyFileHash(_:))
        case "goToDirectory": return #selector(self.goToDirectory(_:))
        case "openTerminal": return #selector(self.openTerminal(_:))
        case "openEditor": return #selector(self.openEditorWith(_:))
        case "cutFiles": return #selector(self.cutFiles(_:))
        case "cancelCut": return #selector(self.cancelCut(_:))
        case "pasteFiles": return #selector(self.pasteFiles(_:))
        case "moveToFavorite": return #selector(self.moveToFavorite(_:))
        case "copyToFavorite": return #selector(self.copyToFavorite(_:))
        case "manageFavorites": return #selector(self.manageFavorites(_:))
        case "createSymlink": return #selector(self.createSymlink(_:))
        case "archiveOperation": return #selector(self.archiveOperation(_:))
        case "convertImage": return #selector(self.convertImage(_:))
        case "scaleImage": return #selector(self.scaleImage(_:))
        case "toggleHiddenFiles": return #selector(self.toggleHiddenFiles(_:))
        case "undoLast": return #selector(self.undoLast(_:))
        default: return nil
        }
    }

    /// 将 Kit 纯数据树渲染为 NSMenu
    func renderMenu(title: String = "FinderRight", nodes: [MenuDataNode], editors: [KnownEditor] = [], style: MenuIconStyle) -> NSMenu {
        let menu = NSMenu(title: L(title))
        menu.autoenablesItems = false
        for node in nodes {
            switch node.kind {
            case .separator:
                menu.addItem(.separator())
            case .action(let actionId, let tag):
                let item = makeItem(from: node, action: selector(for: actionId), tag: tag, style: style)
                if case .action(let actionId, let index) = node.kind,
                   actionId == "openEditor", editors.indices.contains(index), style != .none {
                    item.image = editorMenuIcon(for: editors[index].id)
                }
                menu.addItem(item)
            case .submenu(let children):
                let item = makeItem(from: node, action: nil, tag: 0, style: style)
                let subMenu = renderMenu(title: node.titleKey, nodes: children, editors: editors, style: style)
                item.setSubmenuOrSingleAction(subMenu)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// 根据纯数据节点生成 NSMenuItem
    private func makeItem(
        from node: MenuDataNode,
        action: Selector?,
        tag: Int,
        style: MenuIconStyle
    ) -> NSMenuItem {
        let title: String
        switch node.title {
        case .key(let k):
            title = L(k)
        case .dynamic(let d):
            title = d
        case .unavailableDirectory(let name):
            title = name + " — " + L("目录不可用")
        case .formatted(let key, let count):
            title = String(format: L(key), count)
        }

        let sc = node.shortcutId.flatMap { SharedConfig.shared.shortcut(forActionId: $0) }
        let key = sc?.key ?? ""
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.tag = tag
        if let sc, !key.isEmpty {
            item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(sc.modifiers))
        }

        item.isEnabled = node.isEnabled
        item.toolTip = node.toolTip

        if let systemImage = node.systemImage {
            switch style {
            case .modern:
                item.image = Self.getSymbolImage(named: systemImage)
            case .tinted, .tile:
                item.image = MenuIconRenderer.image(symbol: systemImage, tint: node.tint, style: style)
            case .none:
                item.image = nil
            }
        }

        return item
    }

    /// 「打开终端」子菜单项对应的终端 id，按 tag 索引
    var terminalMenuIds: [String] = []

}
