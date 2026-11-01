import AppKit
import QuickLookUI
import FinderRightKit

/// 独立的 Markdown 预览扩展：与文件预览扩展分开，用户可在设置里单独关闭，
/// 关闭后 .md 回到系统或其他应用的预览。渲染复用 DocumentPreviewView，不使用 WebKit。
final class MarkdownPreviewController: NSViewController, QLPreviewingController {
    private let documentView = DocumentPreviewView()
    private let status = NSTextField(wrappingLabelWithString: "")
    let queue = DispatchQueue(label: "com.finderright.markdown.read", qos: .userInitiated)
    private var request: PreviewRequest?
    private var sourceURL: URL?
    private var needsReload = false
    private var savedScroll: NSPoint?

    private func text(_ key: String) -> String { Self.text(key) }

    private static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: MarkdownPreviewController.self), comment: "")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        container.autoresizingMask = [.width, .height]
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setAccessibilityLabel(text("Preview status"))
        for item in [documentView, status] as [NSView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(item)
        }
        NSLayoutConstraint.activate([
            documentView.topAnchor.constraint(equalTo: container.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: documentView.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
        view = container
        preferredContentSize = container.frame.size
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        _ = view
        request?.cancel()
        if !needsReload || sourceURL != url { savedScroll = nil }
        sourceURL = url
        needsReload = false
        let current = PreviewRequest(completion: handler)
        request = current
        documentView.clear()
        status.stringValue = text("Loading…")
        let name = url.lastPathComponent
        queue.async { [weak self] in
            // Markdown 解析与富文本生成在后台完成，1 MiB 文档约 1 秒，不能卡住主线程。
            let result = Result { try autoreleasepool {
                try current.checkCancellation()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let document = try PreviewDocument.readMarkdown(url, request: current)
                try current.checkCancellation()
                let content = DocumentPreviewView.content(for: document, text: Self.text, isCancelled: { current.isCancelled })
                try current.checkCancellation()
                return content
            } }
            DispatchQueue.main.async {
                guard let self, self.request === current, !current.isCancelled else {
                    current.cancel()
                    return
                }
                switch result {
                case .success(let content):
                    self.documentView.show(content)
                    if let point = self.savedScroll {
                        self.documentView.contentView.scroll(to: point)
                        self.documentView.reflectScrolledClipView(self.documentView.contentView)
                        self.savedScroll = nil
                    }
                    self.status.stringValue = name + " · " + self.text("Read-only preview")
                case .failure(let error):
                    let reason = self.text((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    self.status.stringValue = self.text("Unable to read contents") + ": " + reason
                }
                self.status.toolTip = self.status.stringValue
                // 错误也在预览中显示，避免系统退回只显示一个文件图标。
                current.finish()
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        guard !needsReload else { return }
        request?.cancel()
        request = nil
        needsReload = sourceURL != nil
        savedScroll = documentView.contentView.bounds.origin
        documentView.clear()
        status.stringValue = ""
        status.toolTip = nil
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if needsReload, let sourceURL { preparePreviewOfFile(at: sourceURL) { _ in } }
    }

    deinit { request?.cancel() }
}
