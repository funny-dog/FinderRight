import AppKit
import ApplicationServices
import FinderRightKit

/// 读访达「编辑 → 撤销」项的当前样子（标题 + 是否可用），供撤销记录比对 ⌘Z 归谁。
///
/// 访达不在前台也能读菜单栏；未授权辅助功能、访达未运行或读不到时返回 nil，
/// 此时 ⌘Z 一律交还访达（见 UndoCenter.shortcutDecision）。
enum FinderUndoMenu {

    private static let finderBundleId = "com.apple.finder"

    static func snapshot() -> FinderUndoSnapshot? {
        guard AXIsProcessTrusted(),
              let pid = NSRunningApplication.runningApplications(withBundleIdentifier: finderBundleId).first?.processIdentifier
        else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // 访达无响应时不能拖住文件操作的收尾
        AXUIElementSetMessagingTimeout(app, 0.2)
        return snapshot(app: app)
    }

    static func snapshot(app: AXUIElement) -> FinderUndoSnapshot? {
        guard let bar = copyAttribute(app, kAXMenuBarAttribute) else { return nil }
        // 菜单栏顺序固定：苹果、访达、文件、编辑。标题本地化，按快捷键找撤销项（⌘Z，修饰键 0 = 仅 ⌘）
        let tops = children(bar as! AXUIElement)
        guard tops.count > 3, let menu = children(tops[3]).first else { return nil }
        let item = children(menu).first {
            copyAttribute($0, kAXMenuItemCmdCharAttribute) as? String == "Z"
                && (copyAttribute($0, kAXMenuItemCmdModifiersAttribute) as? Int) == 0
        }
        guard let item, let title = copyAttribute(item, kAXTitleAttribute) as? String else { return nil }
        let enabled = copyAttribute(item, kAXEnabledAttribute) as? Bool ?? false
        return FinderUndoSnapshot(title: title, enabled: enabled)
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
