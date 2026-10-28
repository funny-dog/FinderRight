import SwiftUI
import FinderRightKit

@main
struct FinderRightApp: App {
    // 用 AppDelegate 管理原生状态栏菜单 + URL scheme + activation policy
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        NSLog("[FinderRightApp] init() called, starting IPC watcher")
        IPCWatcher.shared.start()
        NSLog("[FinderRightApp] IPC watcher ready")
    }

    var body: some Scene {
        // 设置窗口改由 AppDelegate 唯一管理（菜单栏与 ⌘, 唤起相同实例），
        // 此处 Settings 留空以避免产生双设置窗口实例与状态分叉；
        // ⌘, 菜单项替换为 AppDelegate.openSettings()，否则 SwiftUI 默认项会打开空白窗口。
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(NSLocalizedString("设置...", comment: "menu")) {
                    appDelegate.openSettings()
                }
                // replacing: .appSettings 会连同系统自带「设置…」的 ⌘, 一起移除，
                // 这里必须显式补回，否则应用菜单里设置项没有快捷键
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    /// 设置页「重新查看引导」发出，由 AppDelegate 打开引导窗口
    static let openOnboarding = Notification.Name("FinderRight.openOnboarding")
}
