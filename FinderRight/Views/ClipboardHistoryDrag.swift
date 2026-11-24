import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import FinderRightKit

// MARK: - 原生点击与拖出桥接

struct ClipboardItemDragView: NSViewRepresentable {
    let item: ClipboardItem
    let onCopy: () -> Void
    let onDragEnded: () -> Void

    func makeNSView(context: Context) -> ClipboardDragNSView {
        let view = ClipboardDragNSView()
        view.item = item
        view.onCopy = onCopy
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: ClipboardDragNSView, context: Context) {
        nsView.item = item
        nsView.onCopy = onCopy
        nsView.onDragEnded = onDragEnded
    }
}

final class ClipboardDragNSView: NSView, NSDraggingSource {
    var item: ClipboardItem?
    var onCopy: (() -> Void)?
    var onDragEnded: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var didStartDrag = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didStartDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let item, let downEvent = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - downEvent.locationInWindow.x
        let dy = event.locationInWindow.y - downEvent.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }

        let draggingItems = buildDraggingItems(for: item)
        guard !draggingItems.isEmpty else { return }
        didStartDrag = true
        beginDraggingSession(with: draggingItems, event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownEvent = nil
            didStartDrag = false
        }
        guard !didStartDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onCopy?()
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let droppedOutside = !(window?.frame.contains(screenPoint) ?? false)
        if operation != [] || droppedOutside {
            onDragEnded?()
        }
        mouseDownEvent = nil
        didStartDrag = false
    }

    private func buildDraggingItems(for item: ClipboardItem) -> [NSDraggingItem] {
        let localPoint = mouseDownEvent.map { convert($0.locationInWindow, from: nil) } ?? NSPoint(x: 20, y: 20)
        let previewFrame = NSRect(x: max(0, localPoint.x - 16), y: max(0, localPoint.y - 16), width: 32, height: 32)

        switch item.kind {
        case .text(let text):
            let pbItem = NSPasteboardItem()
            pbItem.setString(text, forType: .string)
            let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
            let icon = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 32, height: 32))
            dragItem.setDraggingFrame(previewFrame, contents: icon)
            return [dragItem]

        case .image(let data, _, _):
            let pbItem = NSPasteboardItem()
            pbItem.setData(data, forType: .png)
            if let fileURL = ClipboardHistoryService.shared.temporaryDragFileURL(for: item) {
                pbItem.setString(fileURL.absoluteString, forType: .fileURL)
            }
            let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
            let preview = ClipboardPreviewLoader.thumbnail(for: item)
                ?? NSImage(data: data)
                ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 32, height: 32))
            dragItem.setDraggingFrame(previewFrame, contents: preview)
            return [dragItem]

        case .files(let urls):
            let singleImagePreview = urls.count == 1 ? ClipboardPreviewLoader.thumbnail(for: item) : nil
            return urls.enumerated().map { index, url in
                let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = singleImagePreview ?? ClipboardHistoryHelpers.fileIcon(for: url)
                let offset = CGFloat(min(index, 4) * 3)
                let frame = previewFrame.offsetBy(dx: offset, dy: -offset)
                dragItem.setDraggingFrame(frame, contents: icon)
                return dragItem
            }
        }
    }
}

// MARK: - 一体化面板与拖动条

final class ClipboardPanel: FRTransientPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

final class ClipboardWindowDragBar: NSView {
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

final class ClipboardDropContainerView: NSView {
    private let dropState: ClipboardDropState
    var onDropFiles: (([URL]) -> Bool)?

    init(dropState: ClipboardDropState) {
        self.dropState = dropState
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, ClipboardFileContent.filenamesPasteboardType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func wantsPeriodicDraggingUpdates() -> Bool {
        false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTargetState(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateTargetState(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropState.isTargeted = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropState.isTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropState.isTargeted = false
        let urls = draggedFileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        return onDropFiles?(urls) ?? false
    }

    private func updateTargetState(for sender: NSDraggingInfo) -> NSDragOperation {
        let canAccept = !draggedFileURLs(from: sender).isEmpty
        dropState.isTargeted = canAccept
        return canAccept ? .copy : []
    }

    private func draggedFileURLs(from sender: NSDraggingInfo) -> [URL] {
        // 内部列表拖出时不接受回落到自身面板
        if sender.draggingSource is ClipboardDragNSView {
            return []
        }
        let raw = ClipboardHistoryService.fileURLs(from: sender.draggingPasteboard)
        return ClipboardHistoryService.shared.filterDroppedFileURLs(raw)
    }
}
