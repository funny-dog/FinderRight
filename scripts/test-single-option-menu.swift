import AppKit

private final class MenuTarget: NSObject {
    var receivedTag: Int?

    @objc func execute(_ sender: NSMenuItem) {
        receivedTag = sender.tag
    }
}

@main
struct SingleOptionMenuChecks {
    static func main() {
        let target = MenuTarget()
        let parent = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "n")
        parent.keyEquivalentModifierMask = [.command, .shift]
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        parent.image = icon
        let menu = NSMenu()
        let option = NSMenuItem(title: "Markdown", action: #selector(MenuTarget.execute(_:)), keyEquivalent: "")
        option.target = target
        option.tag = 7
        menu.addItem(option)
        parent.setSubmenuOrSingleAction(menu)
        precondition(parent.submenu == nil && parent.action == option.action && parent.target === target)
        precondition(parent.title == "新建文件" && parent.image === icon && parent.keyEquivalent == "n")
        precondition(parent.keyEquivalentModifierMask == [.command, .shift])
        target.perform(parent.action!, with: parent)
        precondition(target.receivedTag == 7, "直接执行必须保留模板或应用索引")
        print("✓ 单项直接执行并保留动作、索引、标题、图标和快捷键")

        let disabled = NSMenuItem(title: "禁用入口", action: nil, keyEquivalent: "")
        option.isEnabled = false
        disabled.setSubmenuOrSingleAction(menu)
        precondition(!disabled.isEnabled && disabled.submenu == nil)
        print("✓ 单项禁用状态保留")

        let multiple = NSMenuItem(title: "打开编辑器", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem(title: "另一个选项", action: #selector(MenuTarget.execute(_:)), keyEquivalent: ""))
        multiple.setSubmenuOrSingleAction(menu)
        precondition(multiple.submenu === menu)
        print("✓ 多项保留二级菜单")

        let empty = NSMenuItem(title: "新建文件", action: nil, keyEquivalent: "")
        empty.setSubmenuOrSingleAction(NSMenu())
        precondition(!empty.isEnabled && empty.submenu == nil)
        print("✓ 无选项时禁用入口")

        let nested = NSMenuItem(title: "嵌套菜单", action: nil, keyEquivalent: "")
        let branch = NSMenuItem(title: "下一层", action: nil, keyEquivalent: "")
        branch.submenu = NSMenu()
        let nestedMenu = NSMenu()
        nestedMenu.addItem(branch)
        nested.setSubmenuOrSingleAction(nestedMenu)
        precondition(nested.submenu === nestedMenu)
        print("✓ 嵌套菜单不会被误当作执行动作")
    }
}
