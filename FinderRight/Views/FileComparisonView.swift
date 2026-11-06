import SwiftUI
import AppKit
import FinderRightKit

final class FileComparisonModel: ObservableObject {
    @Published private(set) var leftURL: URL?
    @Published private(set) var rightURL: URL?
    @Published private(set) var left: ComparisonDocument?
    @Published private(set) var right: ComparisonDocument?
    @Published private(set) var leftError: String?
    @Published private(set) var rightError: String?
    @Published private(set) var comparisonError: String?
    @Published private(set) var result: FileComparisonResult?
    @Published private(set) var isLoading = false
    var hasPair: Bool { leftURL != nil && rightURL != nil }
    private var revision = 0
    private let queue = DispatchQueue(label: "com.finderright.app.comparison", qos: .userInitiated)
    private var operation: BlockOperation?

    func setFile(_ url: URL, onLeft: Bool) {
        if onLeft { leftURL = url } else { rightURL = url }
        reload()
    }

    func setFiles(_ urls: [URL]) {
        leftURL = urls.first
        rightURL = urls.count > 1 ? urls[1] : nil
        reload()
    }

    func removeFile(onLeft: Bool) {
        cancel()
        if onLeft { leftURL = nil; left = nil; leftError = nil }
        else { rightURL = nil; right = nil; rightError = nil }
        result = nil
        comparisonError = nil
        isLoading = false
    }

    func cancel() {
        revision += 1
        operation?.cancel()
        operation = nil
    }

    private func reload() {
        revision += 1
        let revision = revision
        operation?.cancel()
        left = nil
        right = nil
        result = nil
        leftError = nil
        rightError = nil
        comparisonError = nil
        isLoading = true
        let leftURL = leftURL, rightURL = rightURL
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let l = leftURL.map { url in Result { try ComparisonDocument.read(url) } }
            guard !operation.isCancelled else { return }
            let r = rightURL.map { url in Result { try ComparisonDocument.read(url) } }
            guard !operation.isCancelled else { return }
            var comparison: Result<FileComparisonResult, Error>?
            if case .success(let left)? = l, case .success(let right)? = r {
                comparison = Result { try FileComparisonResult.compare(left, right) }
            }
            DispatchQueue.main.async { [weak self] in
                // 已完成的操作仍可能有主队列回调，代次避免它覆盖新的选择。
                guard let self, self.revision == revision, !operation.isCancelled else { return }
                if case .success(let value)? = l { self.left = value }
                if case .failure(let error)? = l { self.leftError = error.localizedDescription }
                if case .success(let value)? = r { self.right = value }
                if case .failure(let error)? = r { self.rightError = error.localizedDescription }
                if case .success(let value)? = comparison { self.result = value }
                if case .failure(let error)? = comparison { self.comparisonError = error.localizedDescription }
                self.isLoading = false
            }
        }
        self.operation = operation
        // 纳入退出等待，确保 diff 的临时文本副本清理完再退出应用。
        if !FinderRightService.runGuarded(on: queue, work: { operation.start() }) {
            isLoading = false
            comparisonError = NSLocalizedString("FinderRight 正在退出，请稍后重试", comment: "")
        }
    }
}

enum FileComparisonLayout {
    static let contentSize = NSSize(width: 560, height: 400)
    static let minimumContentSize = NSSize(width: 480, height: 320)
}

struct FileComparisonView: View {
    @ObservedObject var model: FileComparisonModel
    @FRState private var leftTargeted = false
    @FRState private var rightTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: model.hasPair ? 10 : 16) {
                fileSlot(onLeft: true)
                fileSlot(onLeft: false)
            }
            .padding(model.hasPair ? 12 : 18)

            if model.hasPair {
                FRDivider()
                comparisonStatus
                FRDivider()
                Group {
                    if let result = model.result {
                        FileComparisonDiffView(left: model.left, right: model.right, result: result)
                    } else if let error = errorMessage {
                        Text(verbatim: error)
                            .font(.system(size: 12)).foregroundColor(FRTheme.danger)
                            .multilineTextAlignment(.center)
                            .padding(20)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: FileComparisonLayout.minimumContentSize.width,
               minHeight: FileComparisonLayout.minimumContentSize.height)
        .foregroundColor(FRTheme.text)
        .background(FRTheme.window)
    }

    private var errorMessage: String? {
        model.comparisonError ?? model.leftError ?? model.rightError
    }

    private var comparisonStatus: some View {
        HStack(spacing: 10) {
            if model.isLoading {
                ProgressView().controlSize(.small)
                Text("正在比较…")
            } else if let result = model.result {
                if result.additions == 0 && result.deletions == 0 {
                    Text(result.differentLineEndings ? "文本相同，换行格式不同" : "文件内容相同")
                        .foregroundColor(FRTheme.okText)
                } else {
                    Text(verbatim: "+\(result.additions)").foregroundColor(FRTheme.okText)
                        .accessibilityLabel(Text(String(format: NSLocalizedString("新增 %d 行", comment: ""), result.additions)))
                    Text(verbatim: "−\(result.deletions)").foregroundColor(FRTheme.danger)
                        .accessibilityLabel(Text(String(format: NSLocalizedString("删除 %d 行", comment: ""), result.deletions)))
                }
            } else if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundColor(FRTheme.danger).lineLimit(1)
            }
            Spacer()
            Button("重新比较") { model.setFiles([model.leftURL, model.rightURL].compactMap { $0 }) }
                .buttonStyle(.frLink)
                .disabled(model.isLoading)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func fileSlot(onLeft: Bool) -> some View {
        let url = onLeft ? model.leftURL : model.rightURL
        let error = onLeft ? model.leftError : model.rightError
        let targeted = onLeft ? leftTargeted : rightTargeted
        let compact = model.hasPair
        return Button { chooseFile(onLeft: onLeft) } label: {
            Group {
                if compact {
                    HStack(spacing: 8) {
                        Image(systemName: error == nil ? "doc.text" : "exclamationmark.circle")
                            .foregroundColor(error == nil ? FRTheme.accentText : FRTheme.danger)
                        Text(verbatim: url?.lastPathComponent ?? "")
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .padding(.trailing, 24)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                } else {
                    VStack(spacing: 12) {
                        Text(onLeft ? "左侧文件" : "右侧文件")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(FRTheme.mute)
                        Image(systemName: url == nil ? "doc.badge.plus" : "doc.text")
                            .font(.system(size: 32, weight: .light)).foregroundColor(FRTheme.accentText)
                        Text(verbatim: url?.lastPathComponent ?? NSLocalizedString("拖入文件或点击选择", comment: ""))
                            .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        if let error {
                            Text(verbatim: error).font(.system(size: 11)).foregroundColor(FRTheme.danger)
                                .lineLimit(3)
                        } else if let url {
                            Text(verbatim: url.deletingLastPathComponent().path)
                                .font(.system(size: 11)).foregroundColor(FRTheme.mute)
                                .lineLimit(2).truncationMode(.middle)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(targeted ? FRTheme.selection : FRTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                targeted ? FRTheme.accent : FRTheme.fieldBorder, style: StrokeStyle(lineWidth: 1, dash: url == nil ? [5, 4] : [])))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: error ?? url?.path ?? NSLocalizedString("拖入文件或点击选择", comment: "")))
        .accessibilityLabel(onLeft ? "选择左侧文件" : "选择右侧文件")
        .overlay(alignment: .topTrailing) {
            if url != nil {
                Button { model.removeFile(onLeft: onLeft) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(FRTheme.mute)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(onLeft ? "移除左侧文件" : "移除右侧文件")
                .accessibilityLabel(onLeft ? "移除左侧文件" : "移除右侧文件")
                .padding(compact ? 4 : 8)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            model.setFile(url, onLeft: onLeft)
            return true
        } isTargeted: { targeted in
            if onLeft { leftTargeted = targeted } else { rightTargeted = targeted }
        }
    }

    private func chooseFile(onLeft: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("选择", comment: "")
        if panel.runModal() == .OK, let url = panel.url { model.setFile(url, onLeft: onLeft) }
    }

}

struct FileComparisonDiffView: View {
    let left: ComparisonDocument?
    let right: ComparisonDocument?
    let result: FileComparisonResult

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(result.rows) { row in
                        diffRow(row, columnWidth: (geometry.size.width - 1) / 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .center) {
                Rectangle().fill(FRTheme.border).frame(width: 1).allowsHitTesting(false)
            }
        }
    }

    private func diffRow(_ row: FileDiffRow, columnWidth: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 1) {
            diffCell(row.left, number: row.leftNumber, marker: row.kind == .changed ? "−" : " ",
                     noNewline: row.leftNumber == left?.lines.count && left?.hasFinalNewline == false)
                .frame(width: columnWidth, alignment: .leading)
            diffCell(row.right, number: row.rightNumber, marker: row.kind == .changed ? "+" : " ",
                     noNewline: row.rightNumber == right?.lines.count && right?.hasFinalNewline == false)
                .frame(width: columnWidth, alignment: .leading)
        }
        .background {
            HStack(spacing: 1) {
                row.kind == .changed && row.left != nil ? FRTheme.danger.opacity(0.10) : Color.clear
                row.kind == .changed && row.right != nil ? FRTheme.okText.opacity(0.10) : Color.clear
            }
        }
        .overlay(alignment: .center) { Rectangle().fill(FRTheme.border).frame(width: 1) }
    }

    private func diffCell(_ text: String?, number: Int?, marker: String, noNewline: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: number.map(String.init) ?? "")
                .foregroundColor(FRTheme.mute).frame(width: 38, alignment: .trailing)
                .accessibilityHidden(true)
            Text(verbatim: text == nil ? " " : marker)
                .foregroundColor(marker == "+" ? FRTheme.okText : FRTheme.danger).frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: text?.replacingOccurrences(of: "\t", with: "    ") ?? " ")
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if noNewline && text != nil {
                    Text("无末尾换行").font(.system(size: 10)).foregroundColor(FRTheme.mute)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 3)
        .padding(.trailing, 10)
    }
}

final class FileComparisonController: NSObject, NSWindowDelegate {
    static let shared = FileComparisonController()
    private var window: NSWindow?
    private var model: FileComparisonModel?
    
    private let windowType = "fileComparison"

    func show(files: [URL] = []) {
        if window == nil {
            let model = FileComparisonModel()
            
            // 尝试恢复上次的位置（如果存在）
            var contentRect = NSRect(origin: .zero, size: FileComparisonLayout.contentSize)
            if let saved = SharedConfig.shared.restoreWindowPosition(for: windowType) {
                contentRect = saved
            }
            
            let window = NSWindow(contentRect: contentRect,
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = NSLocalizedString("文件比较", comment: "")
            window.minSize = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: FileComparisonLayout.minimumContentSize),
                                                styleMask: window.styleMask).size
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: FileComparisonView(model: model))
            window.center()
            self.model = model
            self.window = window
        }
        if !files.isEmpty { model?.setFiles(Array(files.prefix(2))) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidEndMoving(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        SharedConfig.shared.saveWindowPosition(for: windowType, frame: window.frame)
    }
    
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        SharedConfig.shared.saveWindowPosition(for: windowType, frame: window.frame)
    }
    
    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}
