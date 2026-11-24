import SwiftUI
import AppKit
import FinderRightKit
import UniformTypeIdentifiers

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
