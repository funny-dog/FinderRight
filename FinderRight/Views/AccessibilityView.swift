import SwiftUI
import ApplicationServices  // for AXIsProcessTrusted...

/// 辅助功能权限状态检测与引导
///
/// 用于：让"切换隐藏文件"通过 Cmd+Shift+. 快捷键实现，避免 killall Finder 关闭所有访达窗口、中断正在进行的拷贝或移动。
struct AccessibilityView: View {

    @FRState private var hasAccess: Bool = AccessibilityChecker.check()

    var body: some View {
        PermissionBlock(
            title: "辅助功能",
            granted: hasAccess,
            deniedDetail: "未授权 — 「切换隐藏文件」需重启访达，会关闭所有访达窗口",
            explanation: "FinderRight 用「辅助功能」权限模拟 Cmd+Shift+. 快捷键，无需重启访达即可切换隐藏文件；剪切、粘贴快捷键也需要它。未授权时只能重启访达，会关闭所有访达窗口，并可能中断正在进行的拷贝或移动。",
            openTitle: "打开辅助功能设置…",
            tip: "提示：版本更新后若授权失效，请在系统设置中点「-」删除旧项，再点「+」重新添加。",
            steps: [
                "1. 点击上方按钮，会跳转到「辅助功能」列表",
                "2. 找到 FinderRight 并打开开关；如果列表里没有，点 + 添加 FinderRight.app",
                "3. 版本更新后若未生效：先选中 FinderRight 点「-」删除旧项，再点「+」重新添加",
                "4. 回到此处点击「重新检测」",
            ],
            onOpen: openAccessibilitySettings,
            onRecheck: { hasAccess = AccessibilityChecker.check() }
        )
        .onAppear {
            hasAccess = AccessibilityChecker.check()
        }
        // 从系统设置授权后切回本 App 时自动刷新，不必再手动点「重新检测」
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasAccess = AccessibilityChecker.check()
        }
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// 静默检测主 App 是否拥有辅助功能权限
enum AccessibilityChecker {
    static func check() -> Bool {
        // prompt=false：只查询，绝不弹对话框
        let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
