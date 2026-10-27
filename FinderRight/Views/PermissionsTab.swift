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

                FRFootnote(Text("「完全磁盘访问」让你能在 ~/Documents、~/Desktop、~/Pictures 等受保护目录使用所有功能。「辅助功能」让「切换隐藏文件」无需重启访达，不会关闭访达窗口或中断拷贝。"))
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
                    FRRow(title: Text("右键菜单排查"), subtitle: Text("若右键未显示菜单，可尝试重启访达或检查扩展开关")) {
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
        FRCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.warnText)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text("FinderRight 正在以临时副本运行")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FRTheme.text)
                    Text("当前是从下载目录直接打开的，macOS 会把它挂载到只读的临时路径下运行，扩展状态判断与「新建文件」等操作可能表现异常。把 FinderRight 拖到「应用程序」文件夹后再打开即可恢复正常。")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button("打开应用程序文件夹") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                }
                .buttonStyle(.frSecondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
        }
    }
}
