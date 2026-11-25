import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 左侧单行条目

struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let onHoverSelect: () -> Void
    let onCopy: () -> Void
    let onDragEnded: () -> Void
    @FRState private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var imageThumbnail: NSImage? {
        ClipboardPreviewLoader.thumbnail(for: item)
    }

    private var rowTitle: String {
        switch item.kind {
        case .text:
            return item.previewText
        case .image(_, let width, let height):
            return String(format: NSLocalizedString("图片 (%d×%d)", comment: ""), width, height)
        case .files(let urls):
            if urls.count == 1 {
                return urls[0].lastPathComponent
            }
            return String(format: NSLocalizedString("%@ 等 %d 个项目", comment: ""), urls[0].lastPathComponent, urls.count)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            rowIcon
            Text(verbatim: rowTitle)
                .font(.system(size: 13))
                .foregroundColor(FRTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? FRTheme.selection : (isHovered ? FRTheme.hover : Color.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            ClipboardItemDragView(
                item: item,
                onCopy: onCopy,
                onDragEnded: onDragEnded
            )
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                onHoverSelect()
            }
        }
    }

    @ViewBuilder
    private var rowIcon: some View {
        if let thumb = imageThumbnail {
            Image(nsImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else {
            switch item.kind {
            case .text:
                Image(systemName: "doc")
                    .font(.system(size: 14))
                    .foregroundColor(FRTheme.mute)
                    .frame(width: 22, height: 22)
            case .image:
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundColor(FRTheme.mute)
                    .frame(width: 22, height: 22)
            case .files(let urls):
                Image(nsImage: ClipboardHistoryHelpers.fileIcon(for: urls[0]))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
            }
        }
    }
}

// MARK: - 右侧详情面板

struct ClipboardDetailPane: View {
    let item: ClipboardItem?

    private struct MetadataRow {
        let labelKey: String
        let value: String
        var monospaced: Bool = false
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                previewArea(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                informationSection(for: item)
            }
        } else {
            Text("未选择条目")
                .font(.system(size: 12))
                .foregroundColor(FRTheme.mute)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func previewArea(for item: ClipboardItem) -> some View {
        if let detail = ClipboardPreviewLoader.imageDetail(for: item) {
            ZStack {
                Image(nsImage: detail.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: Color.black.opacity(0.14), radius: 5, y: 2)
            }
            .padding(10)
        } else {
            switch item.kind {
            case .text(let text):
                ScrollView {
                    Text(verbatim: text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundColor(FRTheme.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }

            case .image(_, let width, let height):
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundColor(FRTheme.mute)
                    Text(String(format: NSLocalizedString("图片 (%d×%d)", comment: ""), width, height))
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                }
                .padding(14)

            case .files(let urls):
                VStack(spacing: 10) {
                    Image(nsImage: ClipboardHistoryHelpers.fileIcon(for: urls[0]))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)

                    if urls.count == 1 {
                        Text(verbatim: urls[0].lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(FRTheme.text)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        VStack(spacing: 3) {
                            ForEach(Array(urls.prefix(4).enumerated()), id: \.offset) { _, url in
                                Text(verbatim: url.lastPathComponent)
                                    .font(.system(size: 12))
                                    .foregroundColor(FRTheme.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if urls.count > 4 {
                                Text(String(format: NSLocalizedString("另有 %d 项…", comment: ""), urls.count - 4))
                                    .font(.system(size: 11.5))
                                    .foregroundColor(FRTheme.mute)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func informationSection(for item: ClipboardItem) -> some View {
        let allRows = metadataRows(for: item)
        let pathRow = allRows.first { $0.labelKey == "路径" }
        let compactRows = allRows.filter { $0.labelKey != "路径" }
        let pairedRows = stride(from: 0, to: compactRows.count, by: 2).map { index in
            Array(compactRows[index..<min(index + 2, compactRows.count)])
        }

        return VStack(alignment: .leading, spacing: 5) {
            Text("信息")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(FRTheme.mute)
                .padding(.horizontal, 2)

            VStack(spacing: 4) {
                ForEach(Array(pairedRows.enumerated()), id: \.offset) { _, pair in
                    HStack(spacing: 4) {
                        ForEach(Array(pair.enumerated()), id: \.offset) { _, row in
                            metadataRowView(row)
                        }
                    }
                }
                if let pathRow {
                    metadataRowView(pathRow)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    private func metadataRowView(_ row: MetadataRow) -> some View {
        HStack(spacing: 8) {
            Text(LocalizedStringKey(row.labelKey))
                .font(.system(size: 11.5))
                .foregroundColor(FRTheme.mute)
            Spacer(minLength: 6)
            Text(verbatim: row.value)
                .font(.system(size: 11.5, design: row.monospaced ? .monospaced : .default))
                .foregroundColor(FRTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FRTheme.card)
        )
    }

    private func metadataRows(for item: ClipboardItem) -> [MetadataRow] {
        var rows: [MetadataRow] = []

        if let detail = ClipboardPreviewLoader.imageDetail(for: item) {
            rows.append(MetadataRow(labelKey: "类型", value: NSLocalizedString("图片", comment: "")))
            rows.append(MetadataRow(labelKey: "尺寸", value: "\(detail.pixelWidth) × \(detail.pixelHeight)", monospaced: true))
            if detail.byteCount > 0 {
                let size = ByteCountFormatter.string(fromByteCount: detail.byteCount, countStyle: .file)
                rows.append(MetadataRow(labelKey: "大小", value: size, monospaced: true))
            }
            if case .files(let urls) = item.kind, let first = urls.first {
                rows.append(MetadataRow(
                    labelKey: "路径",
                    value: ClipboardPreviewLoader.abbreviateHome(first.deletingLastPathComponent().path)
                ))
            }
        } else {
            switch item.kind {
            case .text(let text):
                rows.append(MetadataRow(labelKey: "类型", value: NSLocalizedString("文本", comment: "")))
                rows.append(MetadataRow(labelKey: "字符数", value: "\(text.count)", monospaced: true))

            case .image(_, let width, let height):
                rows.append(MetadataRow(labelKey: "类型", value: NSLocalizedString("图片", comment: "")))
                rows.append(MetadataRow(labelKey: "尺寸", value: "\(width) × \(height)", monospaced: true))

            case .files(let urls):
                let first = urls[0]
                let typeName = ClipboardPreviewLoader.isDirectory(first)
                    ? NSLocalizedString("文件夹", comment: "")
                    : NSLocalizedString("文件", comment: "")
                rows.append(MetadataRow(labelKey: "类型", value: typeName))
                if urls.count > 1 {
                    rows.append(MetadataRow(labelKey: "项目数", value: "\(urls.count)", monospaced: true))
                }
                rows.append(MetadataRow(
                    labelKey: "路径",
                    value: ClipboardPreviewLoader.abbreviateHome(first.deletingLastPathComponent().path)
                ))
            }
        }

        rows.append(MetadataRow(
            labelKey: "复制时间",
            value: Self.timeFormatter.string(from: item.copiedAt),
            monospaced: true
        ))
        return rows
    }
}
