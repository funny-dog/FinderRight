import SwiftUI
import AppKit
import ServiceManagement
import FinderRightKit

/// 两种设置窗口共用的开机启动开关，保留授权提示与失败回滚。
struct LaunchAtLoginControl: View {
    var embedInCard: Bool = true
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @FRState private var launchAtLoginError: String?
    @FRState private var currentLoginStatus: SMAppService.Status = .notRegistered

    var body: some View {
        Group {
            if embedInCard {
                FRCard {
                    content
                }
            } else {
                content
            }
        }
        .onAppear {
            calibrateLaunchAtLoginStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            calibrateLaunchAtLoginStatus()
        }
    }

    @ViewBuilder
    private var content: some View {
        // 登录时自动运行 FinderRight
        FRRow(title: Text("开机自动启动")) {
            FRSwitch(label: "开机自动启动", isOn: Binding(
                get: { launchAtLogin },
                set: { updateLaunchAtLogin(to: $0) }
            ))
        }

        if let error = launchAtLoginError {
            FRDivider()
            Text(verbatim: error)
                .font(.system(size: 12))
                .foregroundColor(FRTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }

        if currentLoginStatus == .requiresApproval {
            FRDivider()
            HStack(spacing: 12) {
                Text("已注册，但需要在「系统设置」-「通用」-「登录项与扩展」（macOS 14 及更早为「登录项」）中允许启动")
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.warnText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("打开系统设置") {
                    LaunchAtLoginManager.openLoginItemsSettings()
                }
                .buttonStyle(.frSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func updateLaunchAtLogin(to newValue: Bool) {
        launchAtLoginError = nil
        do {
            try LaunchAtLoginManager.shared.setEnabled(newValue)
            launchAtLogin = newValue
            currentLoginStatus = LaunchAtLoginManager.shared.status
        } catch {
            NSLog("[SettingsView] 设置开机自动启动失败 (\(newValue ? "开启" : "关闭")): \(error)")
            // 回滚开关状态到系统实际状态
            launchAtLogin = LaunchAtLoginManager.shared.isEnabled
            currentLoginStatus = LaunchAtLoginManager.shared.status
            launchAtLoginError = "设置开机自动启动失败: \(error.localizedDescription)"
        }
    }

    private func calibrateLaunchAtLoginStatus() {
        let status = LaunchAtLoginManager.shared.status
        currentLoginStatus = status
        let isEnabled = LaunchAtLoginManager.shared.isEnabled
        if launchAtLogin != isEnabled {
            NSLog("[SettingsView] 校准开机自启状态: 本地=\(launchAtLogin) -> 系统=\(isEnabled) (系统状态: \(LaunchAtLoginManager.shared.statusDescription(status)))")
            launchAtLogin = isEnabled
        }
    }
}
