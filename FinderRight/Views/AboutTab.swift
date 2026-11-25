import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 关于 Tab

struct AboutTab: View {
    private let appVersion = UpdateChecker.shared.currentAppVersion

    @FRState private var updateStatus: UpdateCheckStatus = UpdateChecker.shared.currentStatus
    @FRState private var showingFeedback = false
    @FRState private var showingChangelog = false
    @FRState private var showingWebsite = false

    private var hasUpdateAvailable: Bool {
        if case .updateAvailable = updateStatus { return true }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 14)

                    // 应用图标：直接取 App 自身图标，与程序坞 / 访达中显示的保持一致（图标自带边距与投影）
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 64, height: 64)

                    Text(verbatim: "FinderRight")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(FRTheme.text)
                        .padding(.top, 10)

                    Text("版本 \(appVersion)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(FRTheme.mute)
                        .padding(.top, 2)

                    Text("增强 macOS Finder 右键菜单的轻量工具。")
                        .multilineTextAlignment(.center)
                        .foregroundColor(FRTheme.mute)
                        .font(.system(size: 13))
                        .padding(.top, 4)

                    HStack(spacing: 10) {
                        updateArea
                        starButton
                    }
                    .padding(.top, 14)

                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            AboutGridCard(
                                icon: "link",
                                title: "GitHub 仓库",
                                subtitle: "源码与版本发布",
                                trailingSymbol: "arrow.up.right"
                            ) {
                                NSWorkspace.shared.open(URL(string: "https://github.com/funny-dog/FinderRight")!)
                            }
                            AboutGridCard(
                                icon: "safari",
                                title: "官方网站",
                                subtitle: "介绍与安装包",
                                trailingSymbol: "chevron.right"
                            ) {
                                showingWebsite = true
                            }
                        }
                        HStack(spacing: 10) {
                            AboutGridCard(
                                icon: "exclamationmark.bubble",
                                title: "反馈与建议",
                                subtitle: "问题与功能想法",
                                trailingSymbol: "chevron.right"
                            ) {
                                showingFeedback = true
                            }
                            AboutGridCard(
                                icon: "sparkles",
                                title: "更新日志",
                                subtitle: "各版本功能演进",
                                trailingSymbol: "chevron.right"
                            ) {
                                showingChangelog = true
                            }
                        }
                    }
                    .padding(.top, 20)

                    // 版权信息
                    Text(verbatim: "Copyright © 2026 FinderRight · MIT License")
                        .font(.system(size: 11.5))
                        .foregroundColor(FRTheme.mute)
                        .padding(.top, 20)

                    Spacer(minLength: 14)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            performCheck(force: false)
        }
        .sheet(isPresented: $showingFeedback) {
            FeedbackSheet(isPresented: $showingFeedback)
        }
        .sheet(isPresented: $showingChangelog) {
            ChangelogSheet(isPresented: $showingChangelog)
        }
        .sheet(isPresented: $showingWebsite) {
            WebsiteSheet(isPresented: $showingWebsite)
        }
        // 菜单栏「检查更新…」发起的检查与下载也同步到这里
        .onReceive(NotificationCenter.default.publisher(for: UpdateChecker.statusDidChangeNotification)) { _ in
            updateStatus = UpdateChecker.shared.currentStatus
        }
    }

    @ViewBuilder
    private var starButton: some View {
        let base = Button {
            NSWorkspace.shared.open(URL(string: "https://github.com/funny-dog/FinderRight")!)
        } label: {
            Label("GitHub Star", systemImage: "star.fill")
        }
        .help("打开仓库主页，登录 GitHub 后手动点击右上角 Star")

        if hasUpdateAvailable {
            base.buttonStyle(.frSecondary)
        } else {
            base.buttonStyle(.frPrimary)
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
                            UpdateChecker.shared.startDownloadAndInstall(downloadURL: downloadURL, checksum: checksum, version: newVersion) { newStatus in
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

private struct AboutGridCard: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let trailingSymbol: String
    let action: () -> Void

    @FRState private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                FRIconChip(systemName: icon, size: 28, style: .subtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FRTheme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(FRTheme.mute)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: trailingSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isHovering ? FRTheme.accentText : FRTheme.mute)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isHovering ? FRTheme.hover : FRTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isHovering ? FRTheme.text.opacity(0.20) : FRTheme.border, lineWidth: 1)
            )
            .shadow(color: FRTheme.cardShadow, radius: 3, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
    }
}
