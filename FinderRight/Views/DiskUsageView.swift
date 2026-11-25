import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 数据模型

final class DiskUsageModel: ObservableObject {
    @Published private(set) var targetURL: URL?
    @Published private(set) var breakdown: DiskUsageBreakdown?
    @Published private(set) var volumeInfo: String?
    @Published private(set) var volumeUsageRatio: Double?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?
    @Published var copiedFeedback: Bool = false

    private let queue = DispatchQueue(label: "com.finderright.app.disk-usage-scan", qos: .userInitiated)
    private var scanRevision = 0
    private var scanOperation: BlockOperation?

    func open(at url: URL) {
        targetURL = url
        breakdown = nil
        error = nil
        volumeInfo = nil
        volumeUsageRatio = nil
        refresh()
    }

    func refresh() {
        guard let url = targetURL else { return }
        scanRevision += 1
        let revision = scanRevision
        scanOperation?.cancel()
        isLoading = true
        error = nil

        updateVolumeInfo(for: url)

        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let breakdown = DiskUsage.inspectDirectChildren(at: url) {
                operation.isCancelled
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanRevision == revision, !operation.isCancelled else { return }
                self.isLoading = false
                if let breakdown {
                    self.breakdown = breakdown
                } else {
                    self.error = NSLocalizedString("无法统计该目录的磁盘占用，请检查读取权限", comment: "")
                }
            }
        }
        scanOperation = operation
        queue.async { operation.start() }
    }

    private func updateVolumeInfo(for url: URL) {
        if let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]) {
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
            let name = values.volumeLocalizedName ?? NSLocalizedString("磁盘", comment: "")
            let used = max(0, total - free)
            volumeUsageRatio = total > 0 ? Double(used) / Double(total) : 0
            volumeInfo = String(
                format: NSLocalizedString("%@ · 剩余 %@ / %@", comment: ""),
                name,
                DiskUsage.formatted(free),
                DiskUsage.formatted(total)
            )
        }
    }

    func copyPath() {
        guard let path = targetURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        withAnimation(.easeInOut(duration: 0.2)) {
            copiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            withAnimation(.easeInOut(duration: 0.2)) {
                self?.copiedFeedback = false
            }
        }
    }

    func cancel() {
        scanRevision += 1
        scanOperation?.cancel()
        scanOperation = nil
        isLoading = false
    }
}

// MARK: - 主视图

struct DiskUsageView: View {
    @ObservedObject var model: DiskUsageModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FRThemeID.storageKey) private var themeRaw = FRThemeID.midnight.rawValue

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            FRDivider()
            contentArea
            FRDivider()
            footerBar
        }
        .frame(minWidth: 480, minHeight: 340)
        .background(FRTheme.window)
        .id(themeRaw)
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                FRIconChip(systemName: "internaldrive.fill", size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.targetURL?.lastPathComponent ?? NSLocalizedString("磁盘占用", comment: ""))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(FRTheme.text)
                            .lineLimit(1)
                        if model.copiedFeedback {
                            FRChip(text: Text(NSLocalizedString("已复制路径", comment: "")), kind: .ok)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(model.targetURL?.path ?? "")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(FRTheme.mute)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        FRIconButton(systemName: "doc.on.doc", help: "复制完整路径") {
                            model.copyPath()
                        }
                    }
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 2) {
                    if let breakdown = model.breakdown {
                        Text(breakdown.formattedTotalSize)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(FRTheme.text)
                    } else if model.isLoading {
                        Text(NSLocalizedString("正在统计…", comment: ""))
                            .font(.system(size: 13))
                            .foregroundColor(FRTheme.mute)
                    }
                }

                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.frSecondary)
                .disabled(model.isLoading)
                .keyboardShortcut("r", modifiers: .command)
                .help(NSLocalizedString("重新统计 (⌘R)", comment: ""))
            }

            if let volumeInfo = model.volumeInfo {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(volumeInfo)
                            .font(.system(size: 11.5))
                            .foregroundColor(FRTheme.mute)
                        Spacer()
                    }
                    if let ratio = model.volumeUsageRatio {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(FRTheme.segmentedTrack)
                                    .frame(height: 4)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(FRTheme.accent)
                                    .frame(width: max(2, geo.size.width * CGFloat(ratio)), height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - 主体列表

    private var contentArea: some View {
        Group {
            if model.isLoading && model.breakdown == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(NSLocalizedString("正在统计直接子项占用…", comment: ""))
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundColor(FRTheme.danger)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                    Button(NSLocalizedString("重试", comment: "")) { model.refresh() }
                        .buttonStyle(.frSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let breakdown = model.breakdown {
                if breakdown.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 32))
                            .foregroundColor(FRTheme.mute)
                        Text(NSLocalizedString("此文件夹为空", comment: ""))
                            .font(.system(size: 12))
                            .foregroundColor(FRTheme.mute)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    itemList(breakdown.items)
                }
            }
        }
    }

    private func itemList(_ items: [DiskUsageItem]) -> some View {
        VStack(spacing: 0) {
            // 列标头
            HStack(spacing: 8) {
                Text(NSLocalizedString("名称", comment: ""))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(FRTheme.mute)
                Spacer()
                Text(NSLocalizedString("占比", comment: ""))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(FRTheme.mute)
                    .frame(width: 100, alignment: .trailing)
                Text(NSLocalizedString("大小", comment: ""))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(FRTheme.mute)
                    .frame(width: 75, alignment: .trailing)
                Text("") // 占位给操作按钮
                    .frame(width: 26)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(FRTheme.card)

            FRDivider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        DiskUsageRow(item: item)
                        FRDivider().padding(.leading, 40)
                    }
                }
            }
        }
    }

    // MARK: - 底栏

    private var footerBar: some View {
        HStack {
            if let breakdown = model.breakdown {
                Text(String(
                    format: NSLocalizedString("共 %d 个子项（%d 个文件夹，%d 个文件）", comment: ""),
                    breakdown.items.count,
                    breakdown.directDirectoryCount,
                    breakdown.directFileCount
                ))
                .font(.system(size: 12))
                .foregroundColor(FRTheme.mute)
            }
            Spacer()
            Button(NSLocalizedString("关闭", comment: "")) {
                DiskUsageController.shared.close()
            }
            .buttonStyle(.frSecondary)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 子项行

private struct DiskUsageRow: View {
    let item: DiskUsageItem
    @FRState private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDirectory ? "folder.fill" : fileSymbol(for: item.name))
                .font(.system(size: 14))
                .foregroundColor(item.isDirectory ? FRTheme.accentText : FRTheme.mute)
                .frame(width: 18)

            Text(item.name)
                .font(.system(size: 12.5))
                .foregroundColor(FRTheme.text)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // 进度占比条与百分比
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(FRTheme.segmentedTrack)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(FRTheme.accent)
                            .frame(width: max(1, geo.size.width * CGFloat(item.percentage)))
                    }
                }
                .frame(width: 60, height: 6)

                Text(String(format: "%.1f%%", item.percentage * 100))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(FRTheme.mute)
                    .frame(width: 46, alignment: .trailing)
            }
            .frame(width: 118, alignment: .trailing)

            Text(item.formattedSize)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(FRTheme.text)
                .frame(width: 75, alignment: .trailing)

            FRIconButton(systemName: "arrow.up.forward.app", help: "在访达中定位") {
                revealInFinder(path: item.path)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(isHovered ? FRTheme.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func fileSymbol(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            return "photo"
        case "mp4", "mov", "mkv", "avi":
            return "film"
        case "mp3", "wav", "m4a", "flac":
            return "music.note"
        case "zip", "tar", "gz", "7z", "rar", "bz2", "xz":
            return "archivebox"
        case "swift", "py", "js", "ts", "rs", "go", "c", "cpp", "h", "java", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc"
        }
    }
}

// MARK: - 控制器

final class DiskUsageController: NSObject, NSWindowDelegate {
    static let shared = DiskUsageController()
    private var window: NSWindow?
    private var model: DiskUsageModel?

    private static let defaultSize = CGSize(width: 560, height: 420)
    private static let minimumSize = CGSize(width: 480, height: 340)

    func show(at url: URL) {
        if window == nil {
            let model = DiskUsageModel()
            let window = FRTransientPanel(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                minSize: Self.minimumSize,
                autosaveKey: "diskUsage")
            window.title = NSLocalizedString("磁盘空间占用", comment: "")
            window.delegate = self
            window.contentView = NSHostingView(rootView: DiskUsageView(model: model))
            self.model = model
            self.window = window
        }

        model?.open(at: url)
        if let window { TransientWindowManager.shared.present(window) }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}
