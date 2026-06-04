import Cocoa
import FinderSync
import FinderRightKit
import os.log

private let log = OSLog(subsystem: "com.finderright.app.sync", category: "FinderSync")

// MARK: - 剪切队列（文件 IPC，跨沙箱共享）

private var cutQueueFileURL: URL {
    IPCBridge.rootDirectory.appendingPathComponent("cut-queue.json")
}

/// 判断暂存区是否有待粘贴的文件，用于控制「粘贴」菜单项的启用状态
private func hasCutQueue() -> Bool {
    if let data = try? Data(contentsOf: cutQueueFileURL),
       let paths = try? JSONSerialization.jsonObject(with: data) as? [String] {
        return !paths.isEmpty
    }
    return false
}

// MARK: - 日志

private func logToFile(_ message: String) {
    let fm = FileManager.default
    guard let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let logFile = docDir.appendingPathComponent("debug.log")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(formatter.string(from: Date()))] \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if fm.fileExists(atPath: logFile.path) {
        if let h = try? FileHandle(forWritingTo: logFile) {
            h.seekToEndOfFile(); h.write(data); h.closeFile()
        }
    } else {
        try? data.write(to: logFile)
    }
}

// MARK: - FinderSync

class FinderSync: FIFinderSync {

    override init() {
        super.init()
        logToFile("FinderSync init started")

        let dirs = Self.buildMonitoredDirectories()
        FIFinderSyncController.default().directoryURLs = dirs
        logToFile("monitoredDirs: \(dirs.map(\.path).joined(separator: ", "))")

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumeDidMount(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumeDidUnmount(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc func volumeDidMount(_ n: Notification) { updateMonitoredDirectories() }
    @objc func volumeDidUnmount(_ n: Notification) { updateMonitoredDirectories() }

    private func updateMonitoredDirectories() {
        let dirs = Self.buildMonitoredDirectories()
        FIFinderSyncController.default().directoryURLs = dirs
        logToFile("updateMonitoredDirectories: \(dirs.map(\.path).joined(separator: ", "))")
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
        logToFile("beginObserving: \(url.absoluteString) | path=\(url.path)")
    }

    override func endObservingDirectory(at url: URL) {
        logToFile("endObserving: \(url.path)")
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
        // 读取主 App 设置界面最新写入的功能开关 / 终端 / 编辑器偏好
        SharedConfig.shared.reload()

        let (directory, selected) = currentContext()
        let hasSelection = !selected.isEmpty
        let exts = selected.map { $0.pathExtension.lowercased() }.joined(separator: ",")
        logToFile("menu(for:) kind=\(menuKind.rawValue) selected=\(selected.count) exts=[\(exts)] dir=\(directory?.path ?? "nil")")

        let menu = NSMenu(title: "FinderRight")

        // 功能开关：默认开启，用户在设置里关闭后对应菜单项隐藏
        func featureOn(_ id: String) -> Bool { SharedConfig.shared.isActionEnabled(id) }

        let isContainerLike = menuKind == .contextualMenuForContainer
            || menuKind == .contextualMenuForSidebar
            || !hasSelection

        // 新建文件 —— 容器/侧边栏/空选中时
        if featureOn(MenuFeatureCatalog.newFile), isContainerLike {
            menu.addItem(submenuItem("📄 新建文件", build: buildNewFileMenu))
        }

        if featureOn(MenuFeatureCatalog.copyPath), hasSelection {
            menu.addItem(shortcutItem("📋 复制路径", #selector(copyPath(_:)), id: "shortcut.copyPath"))
        }

        if featureOn(MenuFeatureCatalog.openTerminal) {
            menu.addItem(shortcutItem("💻 打开终端", #selector(openTerminal(_:)), id: "shortcut.openTerminal"))
        }

        if featureOn(MenuFeatureCatalog.openEditor), hasSelection {
            let editors = installedEditors()
            if !editors.isEmpty {
                menu.addItem(submenuItem("✏️ 打开编辑器", build: { self.buildEditorMenu(editors) }))
            }
        }

        // 剪切 / 粘贴
        if featureOn(MenuFeatureCatalog.cut), hasSelection {
            menu.addItem(shortcutItem("✂️ 剪切", #selector(cutFiles(_:)), id: "shortcut.cut"))
        }
        if featureOn(MenuFeatureCatalog.paste) {
            let hasCut = hasCutQueue()
            if hasCut || isContainerLike {
                let pasteItem = shortcutItem("📋 粘贴", #selector(pasteFiles(_:)), id: "shortcut.paste")
                pasteItem.isEnabled = hasCut
                menu.addItem(pasteItem)
            }
        }

        // 压缩解压
        if featureOn(MenuFeatureCatalog.compress), hasSelection {
            menu.addItem(shortcutItem("📦 压缩为 ZIP", #selector(archiveOperation(_:)), id: "shortcut.compress", tag: 0))
        }
        if featureOn(MenuFeatureCatalog.decompress), hasSelection, selected.contains(where: isArchive) {
            menu.addItem(shortcutItem("📂 解压到当前目录", #selector(archiveOperation(_:)), id: "shortcut.decompress", tag: 2))
        }

        if featureOn(MenuFeatureCatalog.toggleHidden) {
            menu.addItem(shortcutItem("👁 切换隐藏文件", #selector(toggleHiddenFiles(_:)), id: "shortcut.toggleHidden"))
        }
        return menu
    }

    // MARK: - 菜单构建辅助

    /// 本地化菜单标题（中文做 key，en.lproj 提供英文）
    private func L(_ title: String) -> String {
        NSLocalizedString(title, comment: "menu item")
    }

    /// 普通菜单项
    private func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: L(title), action: action, keyEquivalent: "")
        i.target = self
        i.tag = tag
        return i
    }

    /// 带快捷键查找的菜单项
    private func shortcutItem(_ title: String, _ action: Selector, id: String, tag: Int = 0) -> NSMenuItem {
        let sc = SharedConfig.shared.shortcut(forActionId: id)
        let key = sc?.key ?? ""
        let i = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
        i.target = self
        i.tag = tag
        if let sc = sc, !key.isEmpty {
            i.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(sc.modifiers))
        }
        return i
    }

    private func submenuItem(_ title: String, build: () -> NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
        i.submenu = build()
        return i
    }

    private func buildNewFileMenu() -> NSMenu {
        let m = NSMenu(title: "新建文件")
        let types: [(String, Int)] = [
            ("📝 文本文件 (.txt)", 0), ("📖 Markdown (.md)", 1), ("🌐 HTML (.html)", 2),
            ("🐍 Python (.py)", 3), ("🔧 Shell (.sh)", 4), ("📊 JSON (.json)", 5),
            ("📃 XML (.xml)", 6), ("📈 CSV (.csv)", 7), ("🍎 Swift (.swift)", 8),
            ("🟨 JavaScript (.js)", 9),
        ]
        for (t, tag) in types { m.addItem(item(t, #selector(newFile(_:)), tag: tag)) }
        return m
    }

    // MARK: - Actions

    @objc func newFile(_ sender: NSMenuItem) {
        guard let dir = currentContext().directory else {
            logToFile("newFile: no directory"); return
        }
        let (ext, content) = newFileTypeInfo(for: sender.tag)
        logToFile("newFile ipc → dir=\(dir.path) tag=\(sender.tag) ext=\(ext)")
        let r = IPCClient.shared.call(action: "createFile", payload: [
            "directory": .string(dir.path),
            "baseName": .string("untitled"),
            "ext": .string(ext),
            "content": .string(content)
        ])
        logToFile("newFile ipc result: success=\(r.success) msg=\(r.message ?? "")")
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("copyPath: no items"); return }
        let path = urls.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        logToFile("copyPath ok: \(path)")
    }

    @objc func openTerminal(_ sender: NSMenuItem) {
        guard let dir = resolveWorkingDirectory() else {
            logToFile("openTerminal: no dir"); return
        }
        // 使用 SharedConfig 中配置的终端
        let bundleId = SharedConfig.shared.preferredTerminal
        logToFile("openTerminal ipc → dir=\(dir.path) bundle=\(bundleId)")
        let r = IPCClient.shared.call(action: "openTerminal", payload: [
            "directory": .string(dir.path),
            "bundleId": .string(bundleId)
        ])
        logToFile("openTerminal ipc result: success=\(r.success) msg=\(r.message ?? "")")
    }

    /// 检测系统已安装的编辑器（按 EditorCatalog 顺序，Zed 置顶）。
    /// 返回项带 catalogIndex —— 即在 EditorCatalog.all 中的下标，用作菜单项 tag。
    private func installedEditors() -> [(name: String, catalogIndex: Int)] {
        EditorCatalog.all.enumerated().compactMap { idx, ed in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: ed.id) != nil
                ? (ed.name, idx) : nil
        }
    }

    /// 构建「打开编辑器」子菜单。
    ///
    /// 注意：FIFinderSync 的菜单会跨进程传给 Finder 渲染，NSMenuItem 的
    /// `representedObject`（Any）在跨进程序列化时会丢失，因此必须用 `tag`（Int）
    /// 携带数据 —— 这里 tag = 编辑器在 EditorCatalog.all 中的下标。
    private func buildEditorMenu(_ editors: [(name: String, catalogIndex: Int)]) -> NSMenu {
        let m = NSMenu(title: "打开编辑器")
        for ed in editors {
            let item = NSMenuItem(title: ed.name, action: #selector(openEditorWith(_:)), keyEquivalent: "")
            item.target = self
            item.tag = ed.catalogIndex
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
        logToFile("openEditorWith ipc → bundle=\(bundleId) paths=\(paths.joined(separator: ","))")
        let r = IPCClient.shared.call(action: "openWithApp", payload: [
            "paths": .stringArray(paths),
            "bundleId": .string(bundleId)
        ])
        logToFile("openEditorWith ipc result: success=\(r.success) msg=\(r.message ?? "")")
    }

    @objc func cutFiles(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("cutFiles: no items"); return }
        let paths = urls.map { $0.path }
        logToFile("cutFiles ipc → paths=\(paths.joined(separator: ","))")
        // 由主 App（非沙箱）执行：将文件立即移到暂存区，源文件消失，暂存路径写入 cut-queue.json
        let r = IPCClient.shared.call(action: "cutFiles", payload: [
            "paths": .stringArray(paths)
        ])
        logToFile("cutFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
    }

    @objc func pasteFiles(_ sender: NSMenuItem) {
        // 粘贴目标始终是 Finder 当前正在浏览的目录（targetedURL），
        // 而不是选中的项——否则当用户选中一个子文件夹时会错误地粘贴进去。
        guard let destDir = FIFinderSyncController.default().targetedURL() else {
            logToFile("pasteFiles: no destination directory"); return
        }
        logToFile("pasteFiles ipc → destDir=\(destDir.path)")
        let r = IPCClient.shared.call(action: "pasteFiles", payload: [
            "destination": .string(destDir.path)
        ])
        logToFile("pasteFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
    }

    @objc func archiveOperation(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("archiveOperation: no items"); return }
        let paths = urls.map(\.path)
        logToFile("archiveOperation ipc → tag=\(sender.tag) paths=\(paths.joined(separator: ","))")

        let r: (success: Bool, message: String?)
        switch sender.tag {
        case 0:
            r = IPCClient.shared.call(action: "compressZip", payload: ["items": .stringArray(paths)], timeout: 30)
        case 1:
            r = IPCClient.shared.call(action: "compressTarGz", payload: ["items": .stringArray(paths)], timeout: 30)
        case 2:
            var firstErr: String?
            for p in paths {
                let one = IPCClient.shared.call(action: "decompress",
                                                payload: ["archive": .string(p)],
                                                timeout: 30)
                if !one.success, firstErr == nil { firstErr = one.message }
            }
            r = (firstErr == nil, firstErr)
        default:
            return
        }
        logToFile("archiveOperation ipc result: success=\(r.success) msg=\(r.message ?? "")")
    }

    @objc func toggleHiddenFiles(_ sender: NSMenuItem) {
        logToFile("toggleHiddenFiles ipc →")
        let r = IPCClient.shared.call(action: "toggleHiddenFiles", payload: [:])
        logToFile("toggleHiddenFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
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
