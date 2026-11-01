import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 关于 Tab

struct AboutTab: View {
    private let appVersion = UpdateChecker.shared.currentAppVersion

    /// 只保存最终结果；检查进行中保留最近结论与检查时间，不把结果区切换成转圈
    @FRState private var updateStatus: UpdateCheckStatus = UpdateChecker.shared.currentStatus
    @FRState private var showingFeedback = false
    @FRState private var isChecking = false
    @FRState private var checkedAt: Date?

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
            checkedAt = UpdateChecker.shared.lastCheckedDate
            performCheck(force: false)
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheet(isPresented: $showingFeedback)
        }
        // 菜单栏「检查更新…」发起的检查与下载也同步到这里
        .onReceive(NotificationCenter.default.publisher(for: UpdateChecker.statusDidChangeNotification)) { _ in
            apply(UpdateChecker.shared.currentStatus)
        }
    }

    /// 版本状态与更新操作：有新版本、下载中、安装中、最新、失败，各有各的呈现；
    /// 检查期间在下方加小指示，结果与检查时间保持可见
    @ViewBuilder
    private var updateArea: some View {
        VStack(spacing: 8) {
            statusRow

            if isChecking {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                    Text("正在检查更新…")
                        .font(.system(size: 11.5))
                        .foregroundColor(FRTheme.mute)
                }
            }

            if let timeText = checkTimeText {
                Text(verbatim: timeText)
                    .font(.system(size: 11))
                    .foregroundColor(FRTheme.mute)
            }
        }
        .frame(minHeight: 28)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch updateStatus {
        case .updateAvailable(let newVersion, let releaseURL, let downloadURL, let checksum):
            HStack(spacing: 8) {
                if let downloadURL = downloadURL {
                    Button {
                        UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum, version: newVersion) { newStatus in
                            apply(newStatus)
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

        case .upToDate:
            HStack(spacing: 10) {
                // 只代表本次检查的结果：慢渠道可能还有更高版本，文案不能暗示两路都已确认
                FRChip(text: Text("未发现新版本"), kind: .ok)
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

    /// 最近一次成功检查的相对时间，帮助判断「未发现新版本」这类结论的新旧
    private var checkTimeText: String? {
        guard let checkedAt else { return nil }
        let minutes = Int(Date().timeIntervalSince(checkedAt) / 60)
        if minutes < 1 { return NSLocalizedString("刚刚检查", comment: "about check time") }
        if minutes < 60 { return String(format: NSLocalizedString("%d 分钟前检查", comment: "about check time"), minutes) }
        if minutes < 60 * 24 { return String(format: NSLocalizedString("%d 小时前检查", comment: "about check time"), minutes / 60) }
        return String(format: NSLocalizedString("%d 天前检查", comment: "about check time"), minutes / (60 * 24))
    }

    private var checkButton: some View {
        Button {
            performCheck(force: true)
        } label: {
            Label("检查更新", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.frLink)
    }

    /// 检查状态只驱动小指示；最终结果更新状态区并记录检查时间
    private func apply(_ status: UpdateCheckStatus) {
        if case .checking = status {
            isChecking = true
            return
        }
        updateStatus = status
        isChecking = false
        switch status {
        case .upToDate, .updateAvailable:
            checkedAt = UpdateChecker.shared.lastCheckedDate
        default:
            break
        }
    }

    private func performCheck(force: Bool) {
        UpdateChecker.shared.check(force: force) { newStatus in
            apply(newStatus)
        }
    }
}
