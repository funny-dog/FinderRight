import SwiftUI

/// 权限状态块：状态图标 + 标题 + 状态说明；未授权时展开说明、跳转按钮和授权步骤。
/// 完全磁盘访问与辅助功能共用，设置页与首次引导都放在卡片里使用。
struct PermissionBlock: View {
    let title: LocalizedStringKey
    let granted: Bool
    /// 未授权时在标题下方显示的后果说明
    let deniedDetail: LocalizedStringKey
    let explanation: LocalizedStringKey
    let openTitle: LocalizedStringKey
    var tip: LocalizedStringKey? = nil
    let steps: [LocalizedStringKey]
    let onOpen: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                statusIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FRTheme.text)
                    Text(granted ? LocalizedStringKey("已授权") : deniedDetail)
                        .font(.system(size: 12))
                        .foregroundColor(granted ? FRTheme.okText : FRTheme.warnText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !granted {
                Text(explanation)
                    .font(.system(size: 12.5))
                    .foregroundColor(FRTheme.mute)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(action: onOpen) { Text(openTitle) }
                        .buttonStyle(.frPrimary)
                    Button(action: onRecheck) { Text("重新检测") }
                        .buttonStyle(.frSecondary)
                }

                if let tip {
                    Text(tip)
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.warnText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Text(step)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
                    .padding(.top, 6)
                } label: {
                    Text("授权步骤说明")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(FRTheme.text)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusIcon: some View {
        Image(systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(granted ? FRTheme.okText : FRTheme.warnText)
            .frame(width: 30, height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(granted ? FRTheme.okBackground : FRTheme.warnBackground)
            )
    }
}
