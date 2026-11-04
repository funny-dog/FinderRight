import SwiftUI
import AppKit
import FinderRightKit

/// 简洁窗口；较长的授权与错误提示可滚动查看。
struct CompactSettingsView: View {
    let onOpenPermissions: () -> Void

    @FRState private var isExtensionEnabled: Bool = FinderExtensionChecker.check()

    init(onOpenPermissions: @escaping () -> Void) {
        self.onOpenPermissions = onOpenPermissions
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                headerView
                if !isExtensionEnabled {
                    Button("权限与扩展", action: onOpenPermissions)
                        .buttonStyle(.frSecondary)
                }
                LaunchAtLoginControl()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 58)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FRTheme.window)
        .onAppear {
            isExtensionEnabled = FinderExtensionChecker.check()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isExtensionEnabled = FinderExtensionChecker.check()
        }
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            appIconView

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: "FinderRight")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(FRTheme.text)

                HStack(spacing: 6) {
                    Text("访达扩展")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                    FRChip(
                        text: Text(LocalizedStringKey(isExtensionEnabled ? "已启用" : "未启用")),
                        kind: isExtensionEnabled ? .ok : .warn
                    )
                }
            }

            Spacer(minLength: 8)

        }
    }

    private var appIconView: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)
    }
}
