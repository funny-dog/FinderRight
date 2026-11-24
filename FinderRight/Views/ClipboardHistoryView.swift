import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import FinderRightKit

// MARK: - 缩略图与详情图像加载器

struct ClipboardImageDetail {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
}

enum ClipboardPreviewLoader {
    private static let thumbCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 40
        return cache
    }()

    private static let detailCache: NSCache<NSUUID, ClipboardImageDetailBox> = {
        let cache = NSCache<NSUUID, ClipboardImageDetailBox>()
        cache.countLimit = 20
        return cache
    }()

    private final class ClipboardImageDetailBox {
        let detail: ClipboardImageDetail
        init(_ detail: ClipboardImageDetail) {
            self.detail = detail
        }
    }

    private static let maxThumbPixels = 88
    private static let maxDetailPixels = 1440
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp", "ico"
    ]

    static func thumbnail(for item: ClipboardItem) -> NSImage? {
        let key = item.id as NSUUID
        if let cached = thumbCache.object(forKey: key) {
            return cached
        }
        guard let image = buildImage(for: item, maxPixels: maxThumbPixels) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    static func imageDetail(for item: ClipboardItem) -> ClipboardImageDetail? {
        let key = item.id as NSUUID
        if let cached = detailCache.object(forKey: key) {
            return cached.detail
        }
        guard let detail = buildImageDetail(for: item) else { return nil }
        detailCache.setObject(ClipboardImageDetailBox(detail), forKey: key)
        return detail
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = IPCBridge.realUserHomeDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func buildImage(for item: ClipboardItem, maxPixels: Int) -> NSImage? {
        switch item.kind {
        case .text:
            return nil
        case .image(let data, _, _):
            if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let thumb = makeCGThumbnail(from: source, maxPixels: maxPixels) {
                return thumb
            }
            return NSImage(data: data)
        case .files(let urls):
            guard let url = urls.first, isImageFile(url) else { return nil }
            if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let thumb = makeCGThumbnail(from: source, maxPixels: maxPixels) {
                return thumb
            }
            return NSImage(contentsOf: url)
        }
    }

    private static func buildImageDetail(for item: ClipboardItem) -> ClipboardImageDetail? {
        switch item.kind {
        case .text:
            return nil

        case .image(let data, let width, let height):
            guard let image = buildImage(for: item, maxPixels: maxDetailPixels) else { return nil }
            return ClipboardImageDetail(
                image: image,
                pixelWidth: width,
                pixelHeight: height,
                byteCount: Int64(data.count)
            )

        case .files(let urls):
            guard let url = urls.first, isImageFile(url),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) >= 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  let image = makeCGThumbnail(from: source, maxPixels: maxDetailPixels) ?? NSImage(contentsOf: url) else {
                return nil
            }
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            let byteCount = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return ClipboardImageDetail(
                image: image,
                pixelWidth: width,
                pixelHeight: height,
                byteCount: byteCount
            )
        }
    }

    private static func makeCGThumbnail(from source: CGImageSource, maxPixels: Int) -> NSImage? {
        guard CGImageSourceGetCount(source) >= 1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]) {
            if values.isDirectory == true { return false }
            if let type = values.contentType, type.conforms(to: .image) {
                return true
            }
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            return true
        }
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - 主视图

final class ClipboardDropState: ObservableObject {
    @Published var isTargeted = false
}

struct ClipboardHistoryView: View {
    @ObservedObject private var service = ClipboardHistoryService.shared
    @ObservedObject var dropState: ClipboardDropState
    @FRState private var selectedId: UUID? = nil

    private var activeItem: ClipboardItem? {
        if let selectedId, let matched = service.items.first(where: { $0.id == selectedId }) {
            return matched
        }
        return service.items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            FRDivider()
            contentArea
        }
        .frame(minWidth: service.showDetails ? 560 : 240, minHeight: service.showDetails ? 340 : 240)
        .background(FRTheme.window)
        .overlay {
            if dropState.isTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(FRTheme.selection.opacity(0.85))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(FRTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(FRTheme.accentText)
                        Text("松开以加入剪贴板")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(FRTheme.text)
                    }
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if selectedId == nil {
                selectedId = service.items.first?.id
            }
        }
        .onChange(of: service.items.map(\.id)) { ids in
            if let first = ids.first, selectedId == nil || !ids.contains(selectedId!) {
                selectedId = first
            } else if let first = ids.first, selectedId != first {
                // 新复制的记录出现在顶部时同步更新详情预览
                selectedId = first
            }
            if ids.isEmpty {
                selectedId = nil
            }
        }
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("剪贴板")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FRTheme.text)
                .lineLimit(1)

            Spacer(minLength: 6)

            let limitPreset = ClipboardHistoryLimitPreset(rawValue: service.limit) ?? .five
            FRPicker(label: "记录条数", titleKey: limitPreset.titleKey, selection: Binding(
                get: { ClipboardHistoryLimitPreset(rawValue: service.limit) ?? .five },
                set: { service.setLimit($0.rawValue) }
            )) {
                ForEach(ClipboardHistoryLimitPreset.allCases) { preset in
                    Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                }
            }
            .controlSize(.small)
            .help("记录条数")

            headerIconButton(
                systemName: "sidebar.right",
                isOn: service.showDetails,
                helpKey: service.showDetails ? "隐藏详情" : "显示详情",
                accessibilityLabelKey: "详情"
            ) {
                let next = !service.showDetails
                service.setShowDetails(next)
                ClipboardHistoryController.shared.updateLayout(showDetails: next, animated: true)
            }

            headerIconButton(
                systemName: service.isPinned ? "pin.fill" : "pin",
                isOn: service.isPinned,
                helpKey: service.isPinned ? "已固定：复制或拖动后保持打开" : "未固定：复制或拖动后自动关闭",
                accessibilityLabelKey: "固定剪贴板窗口"
            ) {
                let next = !service.isPinned
                service.setPinned(next)
                ClipboardHistoryController.shared.updateWindowLevel(pinned: next)
            }
        }
        .padding(.leading, 38)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(height: 40)
    }

    private func headerIconButton(
        systemName: String,
        isOn: Bool,
        helpKey: String,
        accessibilityLabelKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isOn ? FRTheme.accentText : FRTheme.text)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? FRTheme.selection : FRTheme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isOn ? FRTheme.accentText.opacity(0.5) : FRTheme.fieldBorder, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(helpKey)))
        .accessibilityLabel(Text(accessibilityLabelKey))
        .accessibilityValue(Text(LocalizedStringKey(isOn ? "已开启" : "已关闭")))
    }

    // MARK: - 主体区域

    private var contentArea: some View {
        Group {
            if service.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 26))
                        .foregroundColor(FRTheme.mute.opacity(0.8))
                    Text("剪贴板记录为空")
                        .font(.system(size: 12.5))
                        .foregroundColor(FRTheme.mute)
                    Text("也可将文件拖入此处")
                        .font(.system(size: 11.5))
                        .foregroundColor(FRTheme.mute.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.showDetails {
                HStack(spacing: 0) {
                    listColumn
                        .frame(width: 240)
                        .frame(maxHeight: .infinity)

                    Rectangle()
                        .fill(FRTheme.border)
                        .frame(width: 1)

                    ClipboardDetailPane(item: activeItem)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                listColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var listColumn: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(service.items) { item in
                    ClipboardHistoryRow(
                        item: item,
                        isSelected: service.showDetails && activeItem?.id == item.id,
                        onHoverSelect: {
                            if service.showDetails {
                                selectedId = item.id
                            }
                        },
                        onCopy: {
                            if service.copyItem(item), !service.isPinned {
                                ClipboardHistoryController.shared.close()
                            }
                        },
                        onDragEnded: {
                            if !service.isPinned {
                                ClipboardHistoryController.shared.close()
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - 左侧单行条目

private struct ClipboardHistoryRow: View {
    let item: ClipboardItem
    let isSelected: Bool
    let onHoverSelect: () -> Void
    let onCopy: () -> Void
    let onDragEnded: () -> Void
    @FRState private var isHovered = false

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
        .animation(.easeOut(duration: 0.12), value: isHovered)
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

private struct ClipboardDetailPane: View {
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
                                    .font(.system(size: 11))
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

enum ClipboardHistoryHelpers {
    static func fileIcon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .item)
    }
}

// MARK: - 控制器

final class ClipboardHistoryController: NSObject, NSWindowDelegate {
    static let shared = ClipboardHistoryController()
    private var window: NSWindow?
    private var sizeBeforeExpand: NSSize?

    private static let compactSize = CGSize(width: 300, height: 360)
    private static let expandedSize = CGSize(width: 740, height: 480)
    private static let compactMinSize = CGSize(width: 240, height: 240)
    private static let expandedMinSize = CGSize(width: 560, height: 380)

    func show() {
        guard ClipboardHistoryService.shared.isEnabled else { return }
        let showDetails = ClipboardHistoryService.shared.showDetails
        if window == nil {
            let initialSize = showDetails ? Self.expandedSize : Self.compactSize
            let minSize = showDetails ? Self.expandedMinSize : Self.compactMinSize
            let panel = ClipboardPanel(
                contentRect: NSRect(origin: .zero, size: initialSize),
                minSize: minSize,
                autosaveKey: "clipboardHistoryCompact")
            panel.styleMask.insert(.fullSizeContentView)
            panel.title = NSLocalizedString("剪贴板", comment: "")
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.delegate = self

            let dropState = ClipboardDropState()
            let container = ClipboardDropContainerView(dropState: dropState)
            container.onDropFiles = { urls in
                ClipboardHistoryService.shared.recordDroppedFiles(urls)
            }
            let hostingView = NSHostingView(rootView: ClipboardHistoryView(dropState: dropState))
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: container.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            panel.contentView = container
            installHeaderDragBar(in: panel)
            self.window = panel
        }
        if let panel = window {
            let needsLayoutSync = showDetails
                ? (panel.frame.width < Self.expandedMinSize.width || panel.frame.height < Self.expandedMinSize.height)
                : panel.frame.width > Self.compactSize.width + 60
            if needsLayoutSync {
                updateLayout(showDetails: showDetails, animated: false)
            }
        }
        updateWindowLevel(pinned: ClipboardHistoryService.shared.isPinned)
        if let window {
            TransientWindowManager.shared.present(window)
        }
    }

    func toggleFromShortcut() {
        guard ClipboardHistoryService.shared.isEnabled else { return }
        if let window, window.isVisible {
            close()
        } else {
            show()
        }
    }

    func updateWindowLevel(pinned: Bool) {
        window?.level = pinned ? .floating : .normal
    }

    func updateLayout(showDetails: Bool, animated: Bool) {
        guard let panel = window else { return }
        let targetMinContent = showDetails ? Self.expandedMinSize : Self.compactMinSize
        let minFrameSize = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetMinContent),
            styleMask: panel.styleMask).size
        panel.minSize = minFrameSize

        let targetContent = showDetails ? Self.expandedSize : Self.compactSize
        let targetFrameSize = NSWindow.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContent),
            styleMask: panel.styleMask).size
        var frame = panel.frame
        let topY = frame.maxY
        if showDetails {
            if sizeBeforeExpand == nil, frame.width < Self.expandedMinSize.width { sizeBeforeExpand = frame.size }
            frame.size.width = max(minFrameSize.width, targetFrameSize.width)
            frame.size.height = max(minFrameSize.height, max(frame.height, targetFrameSize.height))
        } else if let saved = sizeBeforeExpand {
            sizeBeforeExpand = nil
            frame.size.width = max(minFrameSize.width, saved.width)
            frame.size.height = max(minFrameSize.height, saved.height)
        } else {
            frame.size.width = max(minFrameSize.width, targetFrameSize.width)
            frame.size.height = max(minFrameSize.height, min(frame.height, targetFrameSize.height))
        }
        frame.origin.y = topY - frame.size.height
        if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX {
                frame.origin.x = max(visible.minX, visible.maxX - frame.width)
            }
            if frame.minX < visible.minX {
                frame.origin.x = visible.minX
            }
            if frame.minY < visible.minY {
                frame.origin.y = visible.minY
            }
            if frame.maxY > visible.maxY {
                frame.origin.y = max(visible.minY, visible.maxY - frame.height)
            }
        }
        panel.setFrame(frame, display: true, animate: animated)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func installHeaderDragBar(in window: NSWindow) {
        guard let content = window.contentView else { return }
        let bar = ClipboardWindowDragBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 38),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -164),
            bar.heightAnchor.constraint(equalToConstant: 40),
        ])
    }
}
