import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 权限与扩展 Tab

struct PermissionsTab: View {
    var body: some View {
        FRPage(title: "权限与扩展", subtitle: "管理访达扩展与系统授权") {
            // 从下载目录直接打开时先提醒：这种运行方式会让扩展状态与唤醒行为都不正常
            if AppRuntime.isTranslocated {
                translocationNotice
            }

            FRSection("扩展") {
                FRCard {
                    FinderExtensionView()
                }
            }

            FRSection("系统权限") {
                FRCard {
                    FullDiskAccessView()
                    FRDivider()
                    AccessibilityView()
                }

                FRFootnote(Text("「完全磁盘访问」用于受保护目录；「辅助功能」用于免重启切换隐藏文件及快捷键。"))
            }

            FRSection {
                HStack {
                    FRCaption("排查与引导")
                    Spacer()
                    Button("重新查看引导") {
                        NotificationCenter.default.post(name: .openOnboarding, object: nil)
                    }
                    .buttonStyle(.frLink)
                    .padding(.trailing, 4)
                }
            } content: {
                FRCard {
                    FRRow(title: Text("右键菜单排查"), subtitle: Text("右键无菜单时，可重启访达或检查扩展")) {
                        HStack(spacing: 8) {
                            Button("重启访达") { FinderRelauncher.relaunch() }
                                .buttonStyle(.frSecondary)

                            Button("扩展设置...") {
                                FinderExtensionChecker.openSettings()
                            }
                            .buttonStyle(.frSecondary)
                        }
                    }
                }
            }
        }
    }

    /// 运行在 App Translocation 临时副本时的提示（见 AppRuntime.isTranslocated）
    private var translocationNotice: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(FRTheme.warnText)

            VStack(alignment: .leading, spacing: 2) {
                Text("FinderRight 正在以临时副本运行")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                Text("从下载目录直接打开会导致扩展异常，请拖入「应用程序」文件夹后重开。")
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("打开应用程序文件夹") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
            }
            .buttonStyle(.frSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(FRTheme.warnBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(FRTheme.warnText.opacity(0.25), lineWidth: 1)
        )
    }
}
