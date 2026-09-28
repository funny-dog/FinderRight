import SwiftUI
import ApplicationServices  // for AXIsProcessTrusted...

/// 辅助功能权限状态检测与引导
///
/// 用于：让"切换隐藏文件"通过 Cmd+Shift+. 快捷键实现，避免 killall Finder 带来的窗口闪烁。
struct AccessibilityView: View {

    @FRState private var hasAccess: Bool = AccessibilityChecker.check()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: hasAccess ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundColor(hasAccess ? .green : .orange)
                    .font(.title)
                VStack(alignment: .leading) {
                    Text("辅助功能")
                        .font(.headline)
                    Text(LocalizedStringKey(hasAccess ? "已授权" : "未授权 — 「切换隐藏文件」会让 Finder 窗口短暂闪烁"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if !hasAccess {
                Text("FinderRight 用「辅助功能」权限模拟 Cmd+Shift+. 快捷键，实现 Finder 隐藏文件即时切换（无需重启 Finder）。授权后 Finder 窗口不再闪烁。")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("打开辅助功能设置…") {
                        openAccessibilitySettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("重新检测") {
                        hasAccess = AccessibilityChecker.check()
                    }
                }

                DisclosureGroup("授权步骤说明") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 点击上方按钮，会跳转到「辅助功能」列表")
                        Text("2. 找到 FinderRight 并打开开关；如果列表里没有，点 + 添加 FinderRight.app")
                        Text("3. 回到此处点击「重新检测」")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: 480, alignment: .leading)
        .onAppear {
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

// #Preview {
//     AccessibilityView()
// }
