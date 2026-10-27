import Cocoa
import FinderSync
import FinderRightKit

extension FinderSync {

    // MARK: - Actions

    @objc func newFile(_ sender: NSMenuItem) {
        guard let dir = currentContext().directory else {
            logToFile("newFile: no directory"); return
        }
        let index = sender.tag
        guard activeNewFileTemplates.indices.contains(index) else {
            logToFile("newFile: template index out of bounds (\(index))"); return
        }
        let item = activeNewFileTemplates[index]
        if item.isOffice {
            logToFile("newFile ipc (async) → dir=\(dir.lastPathComponent) template=\(item.fileExtension)")
            IPCClient.shared.callAsync(action: "createFile", payload: [
                "directory": .string(dir.path),
                "baseName": .string("untitled"),
                "template": .string(item.fileExtension)
            ]) { r in
                logToFile("newFile ipc result: success=\(r.success) msg=\(r.message ?? "")")
            }
            return
        }

        logToFile("newFile ipc (async) → dir=\(dir.lastPathComponent) tag=\(sender.tag) ext=\(item.fileExtension)")
        IPCClient.shared.callAsync(action: "createFile", payload: [
            "directory": .string(dir.path),
            "baseName": .string("untitled"),
            "ext": .string(item.fileExtension),
            "content": .string(item.content)
        ]) { r in
            logToFile("newFile ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("copyPath: no items"); return }
        // 主目录必须用真实路径：沙箱扩展里 NSHomeDirectory() 指向自己的容器目录
        let format = SharedConfig.shared.copyPathFormat
        let path = PathFormatter.string(for: urls, format: format, home: IPCBridge.realUserHomeDirectory.path)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(path, forType: .string) else {
            logToFile("copyPath: pasteboard write failed"); return
        }
        ClipboardToast.showCopied()
        logToFile("copyPath ok: count=\(urls.count) format=\(format.rawValue)")
    }

    @objc func copyFileName(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("copyFileName: no items"); return }
        let format = SharedConfig.shared.copyFileNameFormat
        let names = PathFormatter.fileNames(for: urls, format: format)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(names, forType: .string) else {
            logToFile("copyFileName: pasteboard write failed"); return
        }
        ClipboardToast.showCopied()
        logToFile("copyFileName ok: count=\(urls.count) format=\(format.rawValue)")
    }

    @objc func copyFileContent(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard urls.count == 1, let url = urls.first else {
            logToFile("copyFileContent: not single item")
            return
        }
        logToFile("copyFileContent: sending ipc for \(url.path)")
        IPCClient.shared.callAsync(action: "copyFileContent", payload: ["path": .string(url.path)]) { r in
            logToFile("copyFileContent ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    /// 「复制哈希」子菜单：每种算法一项，tag 为其在 FileHasher.Algorithm.allCases 中的下标
    func buildHashMenu() -> NSMenu {
        let m = NSMenu(title: L("复制哈希"))
        for (index, algorithm) in FileHasher.Algorithm.allCases.enumerated() {
            m.addItem(makeItem(titleKey: algorithm.title, tint: .teal, systemImage: nil, action: #selector(copyFileHash(_:)), tag: index, style: .none))
        }
        return m
    }

    @objc func copyFileHash(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        let algorithms = FileHasher.Algorithm.allCases
        guard !urls.isEmpty, algorithms.indices.contains(sender.tag) else {
            logToFile("copyFileHash: no items or algorithm index out of range (\(sender.tag))"); return
        }
        let algorithm = algorithms[sender.tag]
        logToFile("copyFileHash ipc (async) → \(algorithm.rawValue) count=\(urls.count)")
        IPCClient.shared.callAsync(action: "copyFileHash", payload: [
            "items": .stringArray(urls.map(\.path)),
            "algorithm": .string(algorithm.rawValue)
        ]) { r in
            logToFile("copyFileHash ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func createSymlink(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("createSymlink: no items"); return }
        logToFile("createSymlink ipc (async) → count=\(urls.count)")
        IPCClient.shared.callAsync(action: "createSymlink", payload: ["items": .stringArray(urls.map(\.path))]) { r in
            logToFile("createSymlink ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }


    func buildTerminalMenu(_ terminals: [KnownTerminal], style: MenuIconStyle) -> NSMenu {
        let menu = NSMenu(title: L("打开终端"))
        terminalMenuIds = terminals.map(\.bundleIdentifier)
        for (index, terminal) in terminals.enumerated() {
            menu.addItem(makeItem(titleKey: terminal.name, tint: .graphite, systemImage: terminal.icon,
                                  action: #selector(openTerminal(_:)), tag: index, style: style))
        }
        return menu
    }

    @objc func openTerminal(_ sender: NSMenuItem) {
        guard let dir = resolveWorkingDirectory() else {
            logToFile("openTerminal: no dir"); return
        }
        guard terminalMenuIds.indices.contains(sender.tag) else {
            logToFile("openTerminal: bad tag \(sender.tag)"); return
        }
        let bundleId = terminalMenuIds[sender.tag]
        logToFile("openTerminal ipc (async) → dir=\(dir.lastPathComponent) bundle=\(bundleId)")
        IPCClient.shared.callAsync(action: "openTerminal", payload: [
            "directory": .string(dir.path),
            "bundleId": .string(bundleId)
        ]) { r in
            logToFile("openTerminal ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func cutFiles(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("cutFiles: no items"); return }
        let paths = urls.map { $0.path }
        logToFile("cutFiles ipc (async) → count=\(paths.count)")

        // 1. 同步更新扩展内部内存集合，彻底消除异步 IPC 写磁盘与 Finder 刷新回调的时序竞争
        cutBadgeLock.lock()
        for p in paths {
            inMemoryCutPaths.insert(normalizePath(p))
        }
        cutBadgeLock.unlock()

        // 2. 立即给选中的文件打上剪切角标，提供即时视觉反馈
        for url in urls {
            logToFile("cutFiles setBadgeIdentifier for: \(url.path)")
            setCutBadge(for: url)
            setCutBadge(for: url.standardizedFileURL)
        }

        // 3. 剪切时兜底：所在目录尚未确认角标归属（探测没结论或主 App 当时未运行）时立即申请抢回。
        //    抢回成功后 Finder 会重新请求可见项角标，requestBadgeIdentifier 据内存队列给出剪切角标。
        if let parent = urls.first?.deletingLastPathComponent().path {
            requestBadgeReclaimIfNeeded(directory: parent, reason: "cut")
        }

        IPCClient.shared.callAsync(action: "cutFiles", payload: [
            "paths": .stringArray(paths)
        ]) { r in
            logToFile("cutFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
            guard r.success else {
                let persisted = persistedCutQueuePaths()
                let staleURLs = urls.filter { !persisted.contains(normalizePath($0.path)) }
                cutBadgeLock.lock()
                for url in staleURLs { inMemoryCutPaths.remove(normalizePath(url.path)) }
                cutBadgeLock.unlock()
                DispatchQueue.main.async {
                    for url in staleURLs {
                        FIFinderSyncController.default().setBadgeIdentifier("", for: url)
                        FIFinderSyncController.default().setBadgeIdentifier("", for: url.standardizedFileURL)
                    }
                }
                return
            }

            // 主 App 已落盘：延迟再推一次角标，覆盖「菜单刚关闭、Finder 还没重绘」的时序。
            // 同样只在持有角标归属时有效（见 requestBadgeIdentifier 处的说明）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let stillCut = currentCutQueuePaths()
                var pushed = 0
                for url in urls where stillCut.contains(normalizePath(url.path)) {
                    setCutBadge(for: url)
                    pushed += 1
                }
                logToFile("cutFiles badge re-push: \(pushed)/\(urls.count) item(s) still cut")
            }
        }
    }

    @objc func cancelCut(_ sender: NSMenuItem) {
        let cutPaths = currentCutQueuePaths()
        logToFile("cancelCut ipc (async) → clearing \(cutPaths.count) badges")

        // 立即清除内存队列中的待剪切路径
        cutBadgeLock.lock()
        inMemoryCutPaths.removeAll()
        cutBadgeLock.unlock()

        for path in cutPaths {
            let u = URL(fileURLWithPath: path)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u.standardizedFileURL)
        }
        IPCClient.shared.callAsync(action: "cancelCut", payload: [:]) { r in
            logToFile("cancelCut ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    /// 撤销 FinderRight 的上一次操作。结果提示由主 App 弹出，扩展只记日志
    @objc func undoLast(_ sender: NSMenuItem) {
        IPCClient.shared.callAsync(action: "undoLast", payload: [:]) { r in
            logToFile("undoLast ipc result: success=\(r.success) msg=\(r.message ?? "")")
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

        // 立即清除待粘贴源文件的剪切角标并清空内存队列
        cutBadgeLock.lock()
        inMemoryCutPaths.removeAll()
        cutBadgeLock.unlock()

        for path in cutPaths {
            let u = URL(fileURLWithPath: path)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u.standardizedFileURL)
        }

        IPCClient.shared.callAsync(action: "pasteFiles", payload: [
            "destination": .string(destDir.path)
        ]) { r in
            logToFile("pasteFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    // MARK: - 移动到 / 复制到常用目录

    /// 「移动到 / 复制到」子菜单：每个常用目录一项，末尾是「管理常用目录…」。
    /// tag 为其在 orderedFavoriteDirectories 中的下标：访达转发菜单只保留 tag 与标题，带不了路径
    func buildFavoritesMenu(mode: FileTransferCheck.Mode, selected: [URL], style: MenuIconStyle) -> NSMenu {
        let m = NSMenu(title: L(mode == .move ? "移动到" : "复制到"))
        m.autoenablesItems = false
        let favorites = SharedConfig.shared.orderedFavoriteDirectories
        let unavailable = Self.favoriteAvailability.unavailablePaths(in: favorites)
        let names = FavoriteDirectories.displayNames(for: favorites, home: IPCBridge.realUserHomeDirectory.path)
        let action = mode == .move ? #selector(moveToFavorite(_:)) : #selector(copyToFavorite(_:))

        if favorites.isEmpty {
            let empty = makeItem(titleKey: "尚未添加常用目录", tint: .gray, systemImage: nil, style: .none)
            empty.isEnabled = false
            m.addItem(empty)
        }
        for (index, (path, name)) in zip(favorites, names).enumerated() {
            let item = makeItem(titleKey: name, tint: .cyan, systemImage: "folder", action: action, tag: index, style: style)
            item.toolTip = path
            if unavailable.contains(path) { item.title += " — " + L("目录不可用") }
            // 没有任何一项能放过去时置灰：移动时全部已在该目录，或目标位于选中的文件夹内部
            item.isEnabled = !unavailable.contains(path) && selected.contains {
                FileTransferCheck.check(source: normalizePath($0.path), destinationDirectory: path, mode: mode) == .ok
            }
            m.addItem(item)
        }

        m.addItem(.separator())
        m.addItem(makeItem(titleKey: "管理常用目录…", tint: .gray, systemImage: "gearshape", action: #selector(manageFavorites(_:)), style: style))
        return m
    }

    @objc func moveToFavorite(_ sender: NSMenuItem) {
        transferToFavorite(sender, mode: .move)
    }

    @objc func copyToFavorite(_ sender: NSMenuItem) {
        transferToFavorite(sender, mode: .copy)
    }

    private func transferToFavorite(_ sender: NSMenuItem, mode: FileTransferCheck.Mode) {
        let urls = currentContext().selectedItems
        // 与构建菜单时同一顺序；菜单展开到点击之间不会有新的使用记录，顺序不变
        let favorites = SharedConfig.shared.orderedFavoriteDirectories
        guard !urls.isEmpty, favorites.indices.contains(sender.tag) else {
            logToFile("transferItems: no items or favorite index out of range (\(sender.tag))"); return
        }
        let destination = favorites[sender.tag]
        logToFile("transferItems ipc (async) → mode=\(mode.rawValue) count=\(urls.count) dest=\((destination as NSString).lastPathComponent)")
        IPCClient.shared.callAsync(action: "transferItems", payload: [
            "items": .stringArray(urls.map(\.path)),
            "destination": .string(destination),
            "mode": .string(mode.rawValue)
        ]) { r in
            logToFile("transferItems ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func goToDirectory(_ sender: NSMenuItem) {
        guard let url = URL(string: "\(IPCBridge.urlScheme)://go-to-directory") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let appURL = IPCBridge.containingAppURL(forExtensionAt: Bundle.main.bundleURL) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, error in
                if let error { logToFile("goToDirectory: \(error.localizedDescription)") }
            }
        } else if !NSWorkspace.shared.open(url) {
            logToFile("goToDirectory: failed to open main app")
        }
    }

    /// 打开主 App 设置的「常用目录」页。与 IPC 唤醒一样定向投递给内嵌本扩展的主 App
    @objc func manageFavorites(_ sender: NSMenuItem) {
        guard let url = URL(string: "\(IPCBridge.urlScheme)://settings/favorites") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let appURL = IPCBridge.containingAppURL(forExtensionAt: Bundle.main.bundleURL) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg, completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
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
        let templates = BuiltInFileTemplates.text
        let template = templates.indices.contains(tag) ? templates[tag] : templates[0]
        return (template.fileExtension, template.content)
    }
}
