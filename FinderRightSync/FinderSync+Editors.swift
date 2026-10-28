import Cocoa
import FinderSync
import FinderRightKit

extension FinderSync {

    // MARK: - 编辑器探测与图标缓存（零等待内存快照 + 后台静默刷新）
    //
    // 线程模型：快照整体由 editorCacheLock 保护（持锁时间仅为字典读写，纳秒级），
    // 耗时的 LaunchServices 查询与 icns 读取一律在 cacheQueue 串行队列的锁外完成，
    // 主线程 menu(for:) 只取快照，绝不被后台刷新阻塞。
    private struct EditorCacheSnapshot {
        /// 经过文档编辑能力校验的应用快照
        var editors: [KnownEditor] = []
        /// 上次检测覆盖到的手动添加项；设置里新增的项不在其中时需要补检
        var checkedCustomIds: Set<String> = []
        var icons: [String: NSImage] = [:]
        var lastCheckTime: TimeInterval = 0
        /// 区分「还没检测过」与「检测结果为空」——否则一台没装任何编辑器的机器
        /// 会让每次右键都走同步 LaunchServices 探测
        var hasChecked = false
    }

    private static let editorCacheLock = NSLock()
    private static var editorCache = EditorCacheSnapshot()
    /// 仅允许在 cacheQueue 串行队列上访问
    private static var isRefreshingEditors = false
    /// 最近一次构建的「打开编辑器」子菜单中各项的 bundle id，菜单项 tag 即其下标（受 editorCacheLock 保护）
    private static var editorMenuIds: [String] = []

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

            let config = SharedConfig.shared
            let custom = config.customEditors
            let existingIcons = editorSnapshot().icons
            let fresh = EditorCatalog.installed(custom: custom, preferred: config.preferredEditor)
            var freshIcons: [String: NSImage] = [:]

            for editor in fresh {
                let id = editor.id
                if let existing = existingIcons[id] {
                    freshIcons[id] = existing
                } else if let appURL = EditorDiscovery.preferredIconSourceURL(bundleIdentifier: id) {
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    freshIcons[id] = icon
                }
            }

            editorCacheLock.lock()
            editorCache.editors = fresh
            editorCache.checkedCustomIds = Set(custom.map(\.id))
            editorCache.icons = freshIcons
            editorCache.lastCheckTime = ProcessInfo.processInfo.systemUptime
            editorCache.hasChecked = true
            editorCacheLock.unlock()
        }
    }

    /// 右键子菜单要展示的编辑器：主线程只读内存快照，0ms 立即返回。
    /// 超过 5 分钟未检查、或设置里新增了手动项时派发后台异步刷新，主线程绝不等待。
    /// 调用前 menu(for:) 已 reload 过 SharedConfig，手动添加项与隐藏项是最新的。
    func installedEditors() -> [KnownEditor] {
        let config = SharedConfig.shared
        let custom = config.customEditors
        let hidden = config.hiddenEditors
        var snap = Self.editorSnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        if !snap.hasChecked {
            // 预热未完成时只校验默认项和手动项，不在右键线程枚举应用。
            let ids = Set(custom.map(\.id)).union([EditorCatalog.defaultEditorBundleIdentifier()] + [config.preferredEditor].compactMap { $0 })
            let fallback = ids.sorted().compactMap { EditorCatalog.editor(bundleIdentifier: $0) }
            Self.editorCacheLock.lock()
            if !Self.editorCache.hasChecked {
                Self.editorCache.editors = fallback
                Self.editorCache.checkedCustomIds = Set(custom.map(\.id))
                Self.editorCache.lastCheckTime = now
                Self.editorCache.hasChecked = true
            }
            snap = Self.editorCache
            Self.editorCacheLock.unlock()
            Self.refreshInstalledEditorsAsync()
        } else {
            // 手动项也先校验能力；旧配置中混入的普通应用不能绕过筛选。
            let unchecked = Set(custom.map(\.id)).subtracting(snap.checkedCustomIds)
            let existing = Set(snap.editors.map(\.id))
            snap.editors += unchecked.subtracting(existing).sorted().compactMap { EditorCatalog.editor(bundleIdentifier: $0) }
            if !unchecked.isEmpty || now - snap.lastCheckTime > 300.0 {
                Self.refreshInstalledEditorsAsync()
            }
        }
        return EditorCatalog.menuEditors(available: snap.editors, hidden: hidden, order: config.editorOrder)
    }

    func cacheEditorMenuIds(_ editors: [KnownEditor]) {
        Self.editorCacheLock.lock()
        Self.editorMenuIds = editors.map(\.id)
        Self.editorCacheLock.unlock()
    }

    func editorMenuIcon(for id: String) -> NSImage? {
        Self.editorSnapshot().icons[id]
    }

    @objc func openEditorWith(_ sender: NSMenuItem) {
        let idx = sender.tag
        Self.editorCacheLock.lock()
        let menuIds = Self.editorMenuIds
        Self.editorCacheLock.unlock()
        guard idx >= 0, idx < menuIds.count else {
            logToFile("openEditorWith: bad tag \(idx)"); return
        }
        let bundleId = menuIds[idx]
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
}
