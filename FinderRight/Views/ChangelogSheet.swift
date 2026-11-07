import SwiftUI
import AppKit
import FinderRightKit

/// 更新日志弹窗：展示各版本核心更新说明，支持离线秒开与 GitHub Releases 完整历史跳转。
struct ChangelogSheet: View {
    @Binding var isPresented: Bool

    private let currentVersion = UpdateChecker.shared.currentAppVersion

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 顶栏 Header
            HStack(spacing: 12) {
                FRIconChip(systemName: "sparkles", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("更新日志")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(FRTheme.text)
                    Text("FinderRight 的功能演进与最新改进")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                }
                Spacer(minLength: 0)
                Button("完成") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.frSecondary)
            }

            // 中间版本列表时间线
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ChangelogCatalog.entries, id: \.version) { release in
                        releaseCard(for: release)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 380)

            // 底栏 Footer
            HStack {
                Button {
                    NSWorkspace.shared.open(ChangelogCatalog.releasesURL)
                } label: {
                    Label("在 GitHub Releases 查看完整历史", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.frLink)

                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(22)
        .frame(width: 520)
        .background(FRTheme.window)
    }

    private func releaseCard(for release: ChangelogRelease) -> some View {
        let isCurrent = (release.version == currentVersion)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "v\(release.version)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundColor(FRTheme.text)

                if isCurrent {
                    Text("当前版本")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(FRTheme.accentText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(FRTheme.accent.opacity(0.15))
                        )
                }

                Spacer(minLength: 0)

                Text(verbatim: release.date)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(FRTheme.mute)
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(release.items.indices, id: \.self) { idx in
                    let item = release.items[idx]
                    HStack(alignment: .top, spacing: 8) {
                        typeTag(item.type)

                        Text(LocalizedStringKey(item.textKey))
                            .font(.system(size: 12.5))
                            .foregroundColor(FRTheme.text)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isCurrent ? FRTheme.selection.opacity(0.5) : FRTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isCurrent ? FRTheme.accent.opacity(0.5) : FRTheme.border, lineWidth: 1)
        )
    }

    private func typeTag(_ type: ChangelogType) -> some View {
        let color: Color
        switch type {
        case .feature:
            color = .green
        case .improvement:
            color = .blue
        case .fix:
            color = .orange
        }

        return Text(LocalizedStringKey(type.titleKey))
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }
}
