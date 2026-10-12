import SwiftUI
import AppKit
import FinderSync

/// 访达扩展启用状态检测与引导
///
/// 右键菜单全部由 FinderRightSync 扩展提供：扩展未启用时，FinderRight 在访达里完全不可见。
struct FinderExtensionView: View {

    @FRState private var enabled: Bool = FinderExtensionChecker.check()

    var body: some View {
        PermissionBlock(
            title: "访达扩展",
            granted: enabled,
            grantedDetail: "已启用",
            deniedDetail: "未启用 — 访达右键菜单中不会出现 FinderRight",
            explanation: "FinderRight 的右键菜单由访达扩展提供，需要在系统设置中启用后才会出现。",
            openTitle: "打开扩展设置…",
            tip: "提示：启用后若右键仍没有菜单，可在「设置 → 通用」中点「重启访达」。",
            steps: [
                "1. 点击上方按钮，会跳转到系统设置的扩展管理",
                "2. 在列表中找到 FinderRight",
                "3. 打开 FinderRight 的访达扩展开关",
                "4. 回到此处，状态会自动刷新",
            ],
            onOpen: FinderExtensionChecker.openSettings,
            onRecheck: { enabled = FinderExtensionChecker.check() }
        )
        .onAppear {
            enabled = FinderExtensionChecker.check()
        }
        // 从系统设置启用后切回本 App 时自动刷新
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            enabled = FinderExtensionChecker.check()
        }
    }
}

/// 查询 / 管理本 App 内嵌的访达扩展。系统专为宿主 App 提供了这两个接口，
/// 比解析 `pluginkit -m` 输出更轻，可以在每次打开菜单栏菜单时同步调用。
enum FinderExtensionChecker {
    static func check() -> Bool {
        FIFinderSyncController.isExtensionEnabled
    }

    /// 打开系统设置中管理访达扩展的位置（各系统版本入口不同，由系统负责定位）
    static func openSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }
}
