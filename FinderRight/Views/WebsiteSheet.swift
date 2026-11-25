import SwiftUI
import AppKit
import FinderRightKit

/// 「关于」页的「官方网站」：整卡点击在浏览器中打开，也可单独复制网址。
struct WebsiteSheet: View {
    @Binding var isPresented: Bool

    private struct Site: Identifiable {
        let id: String
        let symbol: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
        let url: URL
    }

    private let sites: [Site] = [
        Site(id: "global", symbol: "globe", title: "全球站",
             detail: "主站 · 产品介绍与安装包下载",
             url: URL(string: UpdatePolicy.websiteOrigin)!),
        Site(id: "china", symbol: "network", title: "国内站",
             detail: "国内访问更快 · 浏览产品介绍",
             url: URL(string: "https://finderright-bhnr38evqjb.qoder.zone")!),
    ]

    @FRState private var copiedSite: String?
    @FRState private var hoveredSite: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                FRIconChip(systemName: "safari", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("官方网站")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(FRTheme.text)
                    Text("点击卡片在浏览器中打开，或复制网址")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                }
                Spacer(minLength: 0)
            }

            VStack(spacing: 10) {
                ForEach(sites) { site in
                    siteRow(site)
                }
            }

            HStack {
                Spacer()
                Button("完成") {
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.frSecondary)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(FRTheme.window)
    }

    private func siteRow(_ site: Site) -> some View {
        let hovered = hoveredSite == site.id
        return HStack(alignment: .center, spacing: 12) {
            Button {
                NSWorkspace.shared.open(site.url)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    FRIconChip(
                        systemName: site.symbol,
                        size: 32,
                        style: site.id == "global" ? .accent : .subtle
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(site.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(FRTheme.text)
                        Text(site.detail)
                            .font(.system(size: 12))
                            .foregroundColor(FRTheme.mute)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: site.url.absoluteString)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(FRTheme.accentText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredSite = site.id } else if hoveredSite == site.id { hoveredSite = nil }
            }
            .help("在浏览器中打开")

            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.open(site.url)
                } label: {
                    HStack(spacing: 4) {
                        Text("打开")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.frSecondary)
                .controlSize(.small)
                .help("在浏览器中打开")

                FRIconButton(
                    systemName: copiedSite == site.id ? "checkmark" : "doc.on.doc",
                    help: copiedSite == site.id ? "已复制" : "复制网址"
                ) {
                    copy(site)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovered ? FRTheme.hover : FRTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hovered ? FRTheme.text.opacity(0.22) : FRTheme.border, lineWidth: 1)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
    }

    private func copy(_ site: Site) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(site.url.absoluteString, forType: .string)
        copiedSite = site.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if copiedSite == site.id {
                copiedSite = nil
            }
        }
    }
}