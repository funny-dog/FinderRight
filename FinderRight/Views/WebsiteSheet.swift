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
             detail: "展示镜像 · 不含安装包，主站访问不畅时使用",
             url: URL(string: "https://finderright-bhnr38evqjb.qoder.zone")!),
    ]

    @FRState private var copiedSite: String?

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
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(site.url)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: site.symbol)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(FRTheme.accentText)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(site.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(FRTheme.text)
                        Text(site.detail)
                            .font(.system(size: 11.5))
                            .foregroundColor(FRTheme.mute)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: site.url.absoluteString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(FRTheme.accentText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 13))
                        .foregroundColor(FRTheme.mute)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在浏览器中打开")

            Button {
                copy(site)
            } label: {
                Label(copiedSite == site.id ? "已复制" : "复制",
                      systemImage: copiedSite == site.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.frLink)
            .help("复制网址")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(FRTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(FRTheme.border, lineWidth: 1)
        )
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