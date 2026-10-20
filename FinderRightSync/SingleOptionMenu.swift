import AppKit

extension NSMenuItem {
    /// 保留入口的标题、图标和快捷键，单个选项只接管执行动作。
    func setSubmenuOrSingleAction(_ menu: NSMenu) {
        if menu.items.count == 1, let option = menu.items.first,
           option.action != nil, option.submenu == nil {
            action = option.action
            target = option.target
            tag = option.tag
            isEnabled = option.isEnabled
        } else if menu.items.isEmpty {
            isEnabled = false
        } else {
            submenu = menu
        }
    }
}
