import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 数据模型

final class LineCountModel: ObservableObject {
    @Published private(set) var targetURL: URL?
    @Published private(set) var result: LineCountResult?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var errorMessage: String?
    @Published var copiedFeedback: Bool = false

    private let queue = DispatchQueue(label: "com.finderright.app.line-count-scan", qos: .userInitiated)
    private var scanRevision = 0
    private var scanOperation: BlockOperation?

    func open(at url: URL) {
        targetURL = url
        result = nil
        errorMessage = nil
        refresh()
    }

    func refresh() {
        guard let url = targetURL else { return }
        scanRevision += 1
        let revision = scanRevision
        scanOperation?.cancel()
        isLoading = true
        errorMessage = nil

        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let countResult = LineCounter.count(at: url) {
                operation.isCancelled
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanRevision == revision, !operation.isCancelled else { return }
                self.isLoading = false
                if let countResult {
                    self.result = countResult
                } else {
                    self.errorMessage = NSLocalizedString("无法统计该目录，请检查读取权限", comment: "")
                }
            }
        }
        scanOperation = operation
        queue.async { operation.start() }
    }

    func cancel() {
        scanOperation?.cancel()
        scanOperation = nil
        isLoading = false
    }

    func copyTable() {
        guard let result else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.formatTable(), forType: .string)
        copiedFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copiedFeedback = false
        }
    }
}

// MARK: - 视图界面

struct LineCountView: View {
    @ObservedObject var model: LineCountModel

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            FRDivider()
            contentArea
            if let result = model.result, !result.languages.isEmpty {
                FRDivider()
                footerSummary(result: result)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .background(FRTheme.window)
    }

    // MARK: - 顶部导航栏

    private var headerBar: some View {
        HStack(spacing: 10) {
            FRIconChip(systemName: "number.square")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.targetURL?.lastPathComponent ?? NSLocalizedString("代码行数统计", comment: ""))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FRTheme.text)
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    }
                }
                if let path = model.targetURL?.path {
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(FRTheme.mute)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            if let targetURL = model.targetURL {
                Button {
                    NSWorkspace.shared.selectFile(targetURL.path, inFileViewerRootedAtPath: "")
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.frSecondary)
                .help(NSLocalizedString("在访达中显示", comment: ""))
            }

            Button {
                model.copyTable()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.copiedFeedback ? "checkmark" : "doc.on.doc")
                    Text(model.copiedFeedback ? NSLocalizedString("已复制", comment: "") : NSLocalizedString("复制表格", comment: ""))
                }
            }
            .buttonStyle(.frSecondary)
            .disabled(model.result == nil || model.result?.languages.isEmpty == true)

            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.frSecondary)
            .disabled(model.isLoading || model.targetURL == nil)
            .help(NSLocalizedString("重新统计", comment: ""))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(FRTheme.card)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentArea: some View {
        if model.isLoading && model.result == nil {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Text(NSLocalizedString("正在扫描并统计代码行数…", comment: ""))
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(FRTheme.danger)
                Text(error)
                    .font(.system(size: 13))
                    .foregroundColor(FRTheme.text)
                Button(NSLocalizedString("重试", comment: "")) { model.refresh() }
                    .buttonStyle(.frSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = model.result {
            if result.languages.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundColor(FRTheme.mute)
                    Text(NSLocalizedString("未找到可识别的代码文件", comment: ""))
                        .font(.system(size: 13))
                        .foregroundColor(FRTheme.mute)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tableArea(result: result)
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "folder")
                    .font(.system(size: 32))
                    .foregroundColor(FRTheme.mute)
                Text(NSLocalizedString("请选择需要统计代码行数的目录", comment: ""))
                    .font(.system(size: 13))
                    .foregroundColor(FRTheme.mute)
                Button(NSLocalizedString("选择目录…", comment: "")) {
                    chooseDirectory()
                }
                .buttonStyle(.frPrimary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 数据表格

    private func tableArea(result: LineCountResult) -> some View {
        VStack(spacing: 0) {
            // 表头
            HStack(spacing: 8) {
                Text(NSLocalizedString("语言", comment: ""))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(NSLocalizedString("文件", comment: ""))
                    .frame(width: 55, alignment: .trailing)
                Text(NSLocalizedString("代码", comment: ""))
                    .frame(width: 70, alignment: .trailing)
                Text(NSLocalizedString("注释", comment: ""))
                    .frame(width: 60, alignment: .trailing)
                Text(NSLocalizedString("空白", comment: ""))
                    .frame(width: 55, alignment: .trailing)
                Text(NSLocalizedString("总计", comment: ""))
                    .frame(width: 75, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(FRTheme.mute)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(FRTheme.card)

            FRDivider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(result.languages) { stat in
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(languageColor(for: stat.language))
                                    .frame(width: 8, height: 8)
                                Text(stat.language)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundColor(FRTheme.text)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text("\(stat.files)")
                                .frame(width: 55, alignment: .trailing)
                            Text("\(stat.code)")
                                .frame(width: 70, alignment: .trailing)
                                .foregroundColor(FRTheme.text)
                                .fontWeight(.medium)
                            Text("\(stat.comment)")
                                .frame(width: 60, alignment: .trailing)
                                .foregroundColor(FRTheme.mute)
                            Text("\(stat.blank)")
                                .frame(width: 55, alignment: .trailing)
                                .foregroundColor(FRTheme.mute)
                            Text("\(stat.total)")
                                .frame(width: 75, alignment: .trailing)
                                .foregroundColor(FRTheme.text)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        FRDivider().opacity(0.5)
                    }
                }
            }
        }
    }

    // MARK: - 底部统计汇总

    private func footerSummary(result: LineCountResult) -> some View {
        HStack(spacing: 16) {
            Text(String(format: NSLocalizedString("语言：%d", comment: ""), result.languages.count))
            Text(String(format: NSLocalizedString("文件：%d", comment: ""), result.totalFiles))
            Text(String(format: NSLocalizedString("代码：%d 行", comment: ""), result.totalCode))
                .fontWeight(.semibold)
                .foregroundColor(FRTheme.text)
            Text(String(format: NSLocalizedString("总计：%d 行", comment: ""), result.totalLines))
            Spacer()
            Text(String(format: "%.0f ms", result.durationMs))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(FRTheme.mute)
        }
        .font(.system(size: 12))
        .foregroundColor(FRTheme.mute)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(FRTheme.card)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("选择", comment: "")
        if panel.runModal() == .OK, let url = panel.url {
            model.open(at: url)
        }
    }

    private func languageColor(for language: String) -> Color {
        switch language {
        case "Swift": return .orange
        case "TypeScript", "TypeScript (TSX)": return .blue
        case "JavaScript", "JavaScript (JSX)": return .yellow
        case "Python": return .green
        case "Go": return .cyan
        case "Rust": return Color(red: 0.8, green: 0.3, blue: 0.1)
        case "C", "C++", "C/C++ Header": return .purple
        case "Objective-C", "Objective-C++": return .indigo
        case "Java", "Kotlin": return Color(red: 0.9, green: 0.4, blue: 0.2)
        case "HTML", "Vue": return Color(red: 0.9, green: 0.3, blue: 0.2)
        case "CSS", "SCSS", "Sass", "Less": return .pink
        case "Shell": return .gray
        case "JSON", "YAML", "TOML", "XML": return Color(red: 0.4, green: 0.7, blue: 0.5)
        case "Markdown": return .teal
        default: return .secondary
        }
    }
}

// MARK: - 控制器

final class LineCountController: NSObject, NSWindowDelegate {
    static let shared = LineCountController()
    private var window: NSWindow?
    private var model: LineCountModel?

    private let windowType = "lineCount"
    private static let defaultSize = CGSize(width: 580, height: 440)
    private static let minimumSize = CGSize(width: 500, height: 360)

    func show(at url: URL? = nil, openedFromExternalApplication: Bool = true) {
        if window == nil {
            let model = LineCountModel()
            let window = FRTransientPanel(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                minSize: Self.minimumSize)
            window.title = NSLocalizedString("代码行数统计", comment: "")
            window.delegate = self
            window.contentView = NSHostingView(rootView: LineCountView(model: model))

            if let saved = SharedConfig.shared.restoreWindowPosition(for: windowType),
               let adjusted = Self.fittedFrame(saved, window: window) {
                window.setFrame(adjusted, display: false)
            } else {
                window.center()
            }

            self.model = model
            self.window = window
        }

        if let url {
            model?.open(at: url)
        }

        if let window {
            TransientWindowManager.shared.present(
                window, openedFromExternalApplication: openedFromExternalApplication)
        }
    }

    private static func fittedFrame(_ frame: NSRect, window: NSWindow) -> NSRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return nil }
        var result = frame
        result.size.width = max(window.minSize.width, min(result.width, screen.visibleFrame.width))
        result.size.height = max(window.minSize.height, min(result.height, screen.visibleFrame.height))
        result.origin.x = max(screen.visibleFrame.minX, min(result.minX, screen.visibleFrame.maxX - result.width))
        result.origin.y = max(screen.visibleFrame.minY, min(result.minY, screen.visibleFrame.maxY - result.height))
        return result
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveFrame(notification) }
    func windowDidEndMoving(_ notification: Notification) { saveFrame(notification) }

    private func saveFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        SharedConfig.shared.saveWindowPosition(for: windowType, frame: window.frame)
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}
