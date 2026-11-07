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

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
            Divider()
            footerBar
        }
        .frame(minWidth: 480, minHeight: 340)
        .background(FRTheme.window)
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 26))
                    .foregroundColor(FRTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(model.targetURL?.lastPathComponent ?? NSLocalizedString("磁盘占用", comment: ""))
                            .font(.system(size: 15, weight: .bold))
                            .lineLimit(1)
                        if model.copiedFeedback {
                            Text(NSLocalizedString("已复制路径", comment: ""))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(FRTheme.okText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(FRTheme.okBackground)
                                .cornerRadius(4)
                        }
                    }

                    HStack(spacing: 4) {
                        Text(model.targetURL?.path ?? "")
                            .font(.system(size: 11))
                            .foregroundColor(FRTheme.mute)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Button(action: { model.copyPath() }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(FRTheme.mute)
                        }
                        .buttonStyle(.plain)
                        .help(NSLocalizedString("复制完整路径", comment: ""))
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
                            .font(.system(size: 10))
                            .foregroundColor(FRTheme.mute)
                        Spacer()
                    }
                    if let ratio = model.volumeUsageRatio {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.primary.opacity(0.08))
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
        .padding(14)
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FRTheme.mute)
                Spacer()
                Text(NSLocalizedString("占比", comment: ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FRTheme.mute)
                    .frame(width: 100, alignment: .trailing)
                Text(NSLocalizedString("大小", comment: ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(FRTheme.mute)
                    .frame(width: 75, alignment: .trailing)
                Text("") // 占位给操作按钮
                    .frame(width: 24)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.02))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        DiskUsageRow(item: item)
                        Divider().padding(.leading, 38)
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
                .font(.system(size: 11))
                .foregroundColor(FRTheme.mute)
            }
            Spacer()
            Button(NSLocalizedString("关闭", comment: "")) {
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.frSecondary)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - 子项行

private struct DiskUsageRow: View {
    let item: DiskUsageItem
    @FRState private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isDirectory ? "folder.fill" : fileSymbol(for: item.name))
                .font(.system(size: 14))
                .foregroundColor(item.isDirectory ? Color.accentColor : FRTheme.mute)
                .frame(width: 18)

            Text(item.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            // 进度占比条与百分比
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.primary.opacity(0.06))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(FRTheme.accent)
                            .frame(width: max(1, geo.size.width * CGFloat(item.percentage)))
                    }
                }
                .frame(width: 60, height: 6)

                Text(String(format: "%.1f%%", item.percentage * 100))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(FRTheme.mute)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(width: 115, alignment: .trailing)

            Text(item.formattedSize)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(FRTheme.text)
                .frame(width: 75, alignment: .trailing)

            Button(action: { revealInFinder(path: item.path) }) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11))
                    .foregroundColor(isHovered ? FRTheme.accent : FRTheme.mute.opacity(0.6))
            }
            .buttonStyle(.plain)
            .frame(width: 24)
            .help(NSLocalizedString("在访达中定位", comment: ""))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isHovered ? FRTheme.hover : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
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

    private let windowType = "diskUsage"
    private static let defaultSize = CGSize(width: 560, height: 420)
    private static let minimumSize = CGSize(width: 480, height: 340)

    func show(at url: URL) {
        if window == nil {
            let model = DiskUsageModel()
            let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let contentRect = NSRect(origin: .zero, size: Self.defaultSize)
            let window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
            window.title = NSLocalizedString("磁盘空间占用", comment: "")
            window.minSize = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: Self.minimumSize), styleMask: styleMask).size
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: DiskUsageView(model: model))
            window.setFrameAutosaveName("DiskUsageWindow")
            if !window.setFrameUsingName("DiskUsageWindow") {
                window.center()
            }
            self.model = model
            self.window = window
        }

        model?.open(at: url)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}
