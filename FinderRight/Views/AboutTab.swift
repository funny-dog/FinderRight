import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 关于 Tab

struct AboutTab: View {
    private let appVersion = UpdateChecker.shared.currentAppVersion

    @FRState private var updateStatus: UpdateCheckStatus = UpdateChecker.shared.currentStatus
    @FRState private var showingFeedback = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // 应用图标：直接取 App 自身图标，与程序坞 / 访达中显示的保持一致（图标自带边距与投影）
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 112, height: 112)

            Text(verbatim: "FinderRight")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(FRTheme.text)
                .padding(.top, 14)

            Text("版本 \(appVersion)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(FRTheme.mute)
                .padding(.top, 4)

            updateArea
                .padding(.top, 14)

            // 描述
            Text("增强 macOS Finder 右键菜单的轻量工具。")
                .multilineTextAlignment(.center)
                .foregroundColor(FRTheme.mute)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .padding(.horizontal, 40)
                .padding(.top, 22)

            // GitHub 链接与 Star 入口：从 Release 直接下载 dmg 的用户通常不会回到仓库页，这里给一个入口
            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/funny-dog/FinderRight")!)
                } label: {
                    Label("GitHub 仓库", systemImage: "link")
                }
                .buttonStyle(.frSecondary)

                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/funny-dog/FinderRight")!)
                } label: {
                    Label("觉得好用？去 GitHub 点个 Star", systemImage: "star")
                }
                .buttonStyle(.frPrimary)
                .help("打开仓库主页，登录 GitHub 后手动点击右上角 Star")
            }
            .padding(.top, 24)

            // 反馈入口：弹窗里选问题反馈或功能建议，提交时才跳转 GitHub；复制诊断信息也在弹窗里
            Button {
                showingFeedback = true
            } label: {
                Label("反馈与建议", systemImage: "exclamationmark.bubble")
            }
            .buttonStyle(.frSecondary)
            .help("反馈问题或提出功能建议")
            .padding(.top, 12)

            Spacer(minLength: 0)

            // 版权信息
            Text(verbatim: "Copyright © 2026 FinderRight · MIT License")
                .font(.system(size: 11.5))
                .foregroundColor(FRTheme.mute)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            performCheck(force: false)
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheet(isPresented: $showingFeedback)
        }
        // 菜单栏「检查更新…」发起的检查与下载也同步到这里
        .onReceive(NotificationCenter.default.publisher(for: UpdateChecker.statusDidChangeNotification)) { _ in
            updateStatus = UpdateChecker.shared.currentStatus
        }
    }

    /// 版本状态与更新操作：有新版本、下载中、安装中、最新、失败，各有各的呈现
    @ViewBuilder
    private var updateArea: some View {
        VStack(spacing: 8) {
            switch updateStatus {
            case .updateAvailable(let newVersion, let releaseURL, let downloadURL, let checksum):
                HStack(spacing: 8) {
                    if let downloadURL = downloadURL {
                        Button {
                            UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum) { newStatus in
                                self.updateStatus = newStatus
                            }
                        } label: {
                            Label("立即更新到 \(newVersion)", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.frPrimary)
                        .help("自动下载并安装新版本")
                    }

                    Button {
                        NSWorkspace.shared.open(releaseURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.frSecondary)
                    .help("在浏览器中查看更新说明")
                }

            case .downloading(let progress):
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(FRTheme.accent)
                        .frame(width: 120)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(FRTheme.mute)
                }

            case .installing:
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text("正在安装并重启...")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                }

            case .checking:
                ProgressView()
                    .scaleEffect(0.55)
                    .frame(width: 14, height: 14)

            case .upToDate:
                HStack(spacing: 10) {
                    FRChip(text: Text("已是最新版本"), kind: .ok)
                    checkButton
                }

            case .failed(let msg):
                HStack(spacing: 10) {
                    Label {
                        Text(verbatim: msg)
                    } icon: {
                        Image(systemName: "exclamationmark.circle")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
                    checkButton
                }

            default:
                checkButton
            }
        }
        .frame(minHeight: 28)
    }

    private var checkButton: some View {
        Button {
            performCheck(force: true)
        } label: {
            Label("检查更新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.frLink)
    }

    private func performCheck(force: Bool) {
        UpdateChecker.shared.check(force: force) { newStatus in
            self.updateStatus = newStatus
        }
    }
}
