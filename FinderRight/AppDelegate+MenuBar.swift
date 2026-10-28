import SwiftUI
import FinderRightKit

extension AppDelegate {
    // MARK: - 原生状态栏菜单

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(named: "MenuBarIcon")
            image?.isTemplate = true   // 模板图随明暗菜单栏自动反色
            button.image = image
            button.image?.size = NSSize(width: 18, height: 18)
            button.toolTip = "FinderRight"
        }
        item.menu = buildMenu()
        item.isVisible = showMenuBarIcon
        statusItem = item
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        // 每次打开前重建，更新扩展状态与下载进度。
        menu.delegate = self
        populate(menu)
        return menu
    }

    func populate(_ menu: NSMenu) {
        let status = NSMenuItem(title: L("FinderRight 运行中"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        // 引导不再常驻菜单：只有扩展未启用（右键菜单完全不出现）时才给出修复入口。
        // 完全磁盘访问、辅助功能是可选授权，用户可能有意跳过，不在这里常驻提醒
        if !FinderExtensionChecker.check() {
            let setup = NSMenuItem(title: L("启用 Finder 扩展…"), action: #selector(openExtensionSetup), keyEquivalent: "")
            setup.target = self
            setup.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.systemOrange]))
            setup.toolTip = L("扩展未启用时，访达右键菜单中不会出现 FinderRight")
            menu.addItem(setup)
        }
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("设置..."), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let update = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        update.target = self
        configureUpdateItem(update)
        menu.addItem(update)
        updateMenuItem = update

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("退出 FinderRight"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func L(_ key: String) -> String { NSLocalizedString(key, comment: "menu") }

    // MARK: - 检查更新

    /// 进行中时显示进度并禁用（action 置空后 NSMenu 自动置灰），空闲时可点
    func configureUpdateItem(_ item: NSMenuItem) {
        let status = UpdateChecker.shared.currentStatus
        switch status {
        case .checking:
            item.title = L("正在检查更新…")
        case .downloading(let progress):
            item.title = String(format: L("正在下载更新… %d%%"), Int(progress * 100))
        case .installing:
            item.title = L("正在安装更新…")
        default:
            item.title = L("检查更新…")
        }
        item.action = status.isInProgress ? nil : #selector(checkForUpdates)
    }

    @objc func updateStatusDidChange() {
        if let item = updateMenuItem { configureUpdateItem(item) }
    }

    /// 后台检查，结果用弹窗告知：已是最新直接提示，有新版本可一键下载安装并重启
    @objc func checkForUpdates() {
        UpdateChecker.shared.check(force: true) { [weak self] status in
            guard let self else { return }
            switch status {
            case .upToDate:
                self.showUpToDateAlert()
            case .updateAvailable(let version, let releaseURL, let downloadURL, let checksum):
                self.promptUpdate(version: version, releaseURL: releaseURL, downloadURL: downloadURL, checksum: checksum)
            case .failed(let message):
                self.showUpdateFailure(title: self.L("无法检查更新"), message: message)
            default:
                break   // 检查中等中间状态由菜单项标题体现
            }
        }
    }

    func showUpToDateAlert() {
        FRDialog(title: L("已是最新版本"),
                 message: String(format: L("FinderRight %@ 是目前的最新版本。"), UpdateChecker.shared.currentAppVersion),
                 symbol: "checkmark.seal", buttons: [L("好")]).runModal()
    }

    func promptUpdate(version: String, releaseURL: URL, downloadURL: URL?, checksum: UpdateChecksum?) {
        let title = String(format: L("发现新版本 %@"), version)
        let current = UpdateChecker.shared.currentAppVersion

        // 发布缺少校验和时 downloadURL 为空，不能自动安装，只能去发布页手动下载
        guard let downloadURL else {
            let dialog = FRDialog(title: title,
                                  message: String(format: L("当前版本 %@。此版本不支持自动安装，请前往发布页下载。"), current),
                                  symbol: "arrow.down.circle", buttons: [L("前往下载"), L("稍后")])
            if dialog.runModal() == 0 {
                NSWorkspace.shared.open(releaseURL)
            }
            return
        }

        let dialog = FRDialog(title: title,
                              message: String(format: L("当前版本 %@。更新将在后台下载并安装，完成后 FinderRight 会自动重启。"), current),
                              symbol: "arrow.down.circle", buttons: [L("立即更新"), L("稍后"), L("查看更新说明")])
        dialog.cancelIndex = 1
        switch dialog.runModal() {
        case 0:
            // 成功时安装脚本会退出并重新拉起新版，这里只需处理失败；进度显示在菜单项标题上
            UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum) { [weak self] status in
                guard let self, case .failed(let message) = status else { return }
                self.showUpdateFailure(title: self.L("自动更新失败"), message: message)
            }
        case 2:
            NSWorkspace.shared.open(releaseURL)
        default:
            break
        }
    }

    func showUpdateFailure(title: String, message: String) {
        FRDialog(title: title, message: message, symbol: "exclamationmark.triangle", tone: .warning,
                 buttons: [L("好")]).runModal()
    }

    @objc func operationDidFinish(_ notification: Notification) {
        guard let record = notification.object as? OperationRecord else { return }
        if let message = OperationHistoryPresentation.transferSuccessMessage(record) {
            ClipboardToast.show(message: message, style: .success)
            return
        }
        guard !record.succeeded, !record.cancelled,
              ![OperationRecord.Kind.undo, .createFile, .cut].contains(record.kind) else { return }
        // 撤销与同步的新建、剪切已有结果反馈，避免重复。
        let message = String(format: L("%@未完成：%@。%@"),
                             OperationHistoryPresentation.actionTitle(record.kind),
                             OperationRecord.truncatedSubject(record.subject),
                             OperationHistoryPresentation.failureSummary(record))
        ClipboardToast.show(message: message, style: record.results.isEmpty ? .failure : .partial)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 偏好变化

    /// 防止 defaultsChanged 重入：
    /// 设置 NSStatusItem.isVisible 时，AppKit 会把可见性自动保存写回 UserDefaults，
    /// 并同步再次发出 didChangeNotification。若无保护，defaultsChanged → setVisible
    /// → 通知 → defaultsChanged 无限递归，最终栈溢出崩溃（EXC_BAD_ACCESS）。
    /// 重入瞬间 isVisible 读到的仍是旧值，靠 "值是否相等" 判断挡不住，必须用标志位。
    @objc func defaultsChanged() {
        UpdateChecker.shared.configureAutomaticUpdates()

        let historyLimit = UserDefaults.standard.object(forKey: RecentOperations.capacityKey) as? Int ?? 100
        if RecentOperations.shared.capacity != historyLimit {
            RecentOperations.shared.setCapacity(historyLimit)
        }

        // 实时同步菜单栏图标显隐（设置里 showMenuBarIcon 改变时）
        guard !isUpdatingStatusItemVisibility else { return }
        let want = showMenuBarIcon
        guard statusItem?.isVisible != want else { return }
        isUpdatingStatusItemVisibility = true
        defer { isUpdatingStatusItemVisibility = false }
        statusItem?.isVisible = want
    }

}

// MARK: - 状态栏菜单刷新

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populate(menu)
    }

}

