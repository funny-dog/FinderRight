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
        guard let bar = AXUIElement.from(app.copyAttribute(kAXMenuBarAttribute)) else { return nil }
        // 菜单栏顺序固定：苹果、访达、文件、编辑。标题本地化，按快捷键找撤销项（⌘Z，修饰键 0 = 仅 ⌘）
        let tops = bar.children
        guard tops.count > 3, let menu = tops[3].children.first else { return nil }
        let item = menu.children.first {
            $0.copyAttribute(kAXMenuItemCmdCharAttribute) as? String == "Z"
                && ($0.copyAttribute(kAXMenuItemCmdModifiersAttribute) as? Int) == 0
        }
        guard let item, let title = item.copyAttribute(kAXTitleAttribute) as? String else { return nil }
        let enabled = item.copyAttribute(kAXEnabledAttribute) as? Bool ?? false
        return FinderUndoSnapshot(title: title, enabled: enabled)
    }
}

extension AXUIElement {
    func copyAttribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success ? value : nil
    }

    // CF 类型的 as? 不做运行时类型检查（编译器视为恒成功），必须按 TypeID 判定
    static func from(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    var children: [AXUIElement] {
        (copyAttribute(kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
