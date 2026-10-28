import SwiftUI
import FinderRightKit

extension AppDelegate {
    // MARK: - finderright:// 入口

    /// 在 willFinishLaunching 注册：冷启动时拉起 App 的那条 URL 事件紧随其后派发，晚了会错过。
    /// 注册后 AppKit 不再调用 application(_:open:)，所有 finderright:// URL 都经由 handleGetURLEvent。
    /// 直接处理 Apple Event 是为了拿到发送方的 audit token —— application(_:open:) 拿不到。
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
    }

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == IPCBridge.urlScheme else { return }
        receivedLaunchURL = true

        // 打开设置窗口无副作用，任何来源都可以。
        if url.host == "settings" || url.host == "preferences" {
            // 可带页名直达某一页，如 finderright://settings/favorites；未知页名忽略，停留在当前页
            let page = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if let tab = SettingsView.SettingsTab.allCases.first(where: { $0.urlName == page }) {
                SettingsNavigation.shared.selectedTab = tab
            }
            // 冷启动时先完成激活策略初始化，再切为 regular 显示窗口。
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
            return
        }

        // URL 只打开输入框，路径必须由用户输入，不从外部请求接收。
        if url.host == "go-to-directory" {
            DispatchQueue.main.async { [weak self] in self?.openGoToDirectory() }
            return
        }

        // 执行类请求会以「完全磁盘访问」身份读写文件：只受理本 App 内嵌的 FinderSync 扩展发来的。
        // 比对的是磁盘上内嵌扩展自己的签名规则，ad-hoc 与证书签名都适用（见 CodeSignatureCheck）
        guard let token = event.attributeDescriptor(forKeyword: keySenderAuditTokenAttr)?.data,
              let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FinderRightSync.appex"),
              CodeSignatureCheck.process(auditToken: token, satisfiesDesignatedRequirementOf: appex) else {
            NSLog("[AppDelegate] 拒绝来源未通过校验的请求: \(url.absoluteString)")
            return
        }
        IPCWatcher.shared.handle(url: url)
    }
}

