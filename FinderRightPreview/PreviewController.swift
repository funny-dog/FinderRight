import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import FinderRightKit

final class PreviewController: NSViewController, QLPreviewingController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let queue = DispatchQueue(label: "com.finderright.preview.read", qos: .userInitiated)
    private var roots: [PreviewNode] = []
    private var folderURL: URL?
    private var generation = UUID()
    private var truncated = false
    private var sourceName = ""
    private var pendingFolders = 0

    private let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: PreviewController.self), comment: "")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 500))
        container.autoresizingMask = [.width, .height]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        // 滚动条保留独立空间，避免覆盖最后一行内容。
        scroll.scrollerStyle = .legacy
        scroll.borderType = .noBorder
        outline.dataSource = self
        outline.delegate = self
        outline.rowHeight = 26
        outline.usesAlternatingRowBackgroundColors = true
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizingMask = [.width]
        outline.allowsMultipleSelection = false
        outline.setAccessibilityLabel(text("Folder and ZIP contents"))
        for (id, title, width) in [("name", "Name", 340.0), ("date", "Modified", 160.0),
                                    ("size", "Size", 90.0), ("kind", "Kind", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = text(title)
            column.width = width
            column.minWidth = id == "name" ? 160 : 65
            column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
            outline.addTableColumn(column)
        }
        outline.outlineTableColumn = outline.tableColumns.first
        outline.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        scroll.documentView = outline

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 1
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setAccessibilityLabel(text("Preview status"))
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        let footer = NSStackView(views: [progress, status])
        footer.spacing = 8
        footer.alignment = .centerY
        for item in [scroll, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(item)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            footer.heightAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
        view = container
        preferredContentSize = container.frame.size
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        outline.sizeLastColumnToFit()
        if let scroll = outline.enclosingScrollView {
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        _ = view
        let current = UUID()
        generation = current
        roots = []
        folderURL = nil
        truncated = false
        pendingFolders = 0
        sourceName = url.lastPathComponent
        outline.reloadData()
        status.stringValue = text("Loading…")
        progress.startAnimation(nil)
        queue.async { [weak self] in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let result = Result { () -> (PreviewListing, Bool) in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                guard values.isSymbolicLink != true, values.isPackage != true else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                let directory = values.isDirectory == true
                return (try directory ? PreviewContents.folder(url) : PreviewContents.zip(url), directory)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == current else {
                    handler(CocoaError(.userCancelled))
                    return
                }
                self.progress.stopAnimation(nil)
                do {
                    let (listing, directory) = try result.get()
                    self.folderURL = directory ? url : nil
                    self.roots = try directory
                        ? listing.entries.map { PreviewNode(path: $0.path, entry: $0) }
                        : PreviewNode.archiveTree(listing.entries)
                    self.truncated = listing.truncated
                    self.sort(self.roots)
                    self.roots = self.sorted(self.roots)
                    self.outline.reloadData()
                    self.updateStatus()
                } catch {
                    self.show(error)
                }
                // 错误也在预览中显示，避免系统退回只显示一个文件图标。
                handler(nil)
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        generation = UUID()
    }

    private func updateStatus() {
        if pendingFolders > 0 {
            status.stringValue = text("Loading…")
            return
        }
        let summary = roots.isEmpty ? text("Empty") : String(format: text("%ld top-level items"), roots.count)
        status.stringValue = sourceName + " · " + summary + (truncated ? " · " + text("Item limit reached; showing partial contents") : "")
        status.toolTip = status.stringValue
    }

    private func show(_ error: Error) {
        let reason = (error as? PreviewError).map { text($0.rawValue) } ?? error.localizedDescription
        status.stringValue = text("Unable to read contents") + ": " + reason
        status.toolTip = status.stringValue
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? PreviewNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? PreviewNode)?.children ?? roots)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? PreviewNode else { return false }
        return node.isDirectory && (!node.loaded || !node.children.isEmpty)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? PreviewNode, !node.loaded, let folderURL else { return true }
        guard !node.loading else { return false }
        node.loading = true
        pendingFolders += 1
        progress.startAnimation(nil)
        status.stringValue = text("Loading…") + " " + node.name
        let current = generation
        let url = folderURL.appendingPathComponent(node.path, isDirectory: true)
        queue.async { [weak self] in
            let access = folderURL.startAccessingSecurityScopedResource()
            defer { if access { folderURL.stopAccessingSecurityScopedResource() } }
            let result = Result { try PreviewContents.folder(url) }
            DispatchQueue.main.async {
                guard let self, self.generation == current else { return }
                node.loading = false
                self.pendingFolders -= 1
                if self.pendingFolders == 0 { self.progress.stopAnimation(nil) }
                do {
                    let listing = try result.get()
                    node.children = self.sorted(listing.entries.map {
                        PreviewNode(path: node.path + "/" + $0.path, entry: $0)
                    })
                    node.loaded = true
                    self.truncated = self.truncated || listing.truncated
                    self.outline.reloadItem(node, reloadChildren: true)
                    self.outline.expandItem(node)
                    self.updateStatus()
                } catch {
                    self.show(error)
                }
            }
        }
        return false
    }

    private func sorted(_ nodes: [PreviewNode]) -> [PreviewNode] {
        let descriptor = outline.sortDescriptors.first
        return nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let order: ComparisonResult
            switch descriptor?.key {
            case "size":
                order = NSNumber(value: a.entry?.size ?? -1).compare(NSNumber(value: b.entry?.size ?? -1))
            case "date":
                order = (a.entry?.modificationDate ?? .distantPast).compare(b.entry?.modificationDate ?? .distantPast)
            case "kind":
                order = kind(a).localizedStandardCompare(kind(b))
            default:
                order = a.name.localizedStandardCompare(b.name)
            }
            let resolved = order == .orderedSame ? a.name.localizedStandardCompare(b.name) : order
            return descriptor?.ascending == false ? resolved == .orderedDescending : resolved == .orderedAscending
        }
    }

    private func sort(_ nodes: [PreviewNode]) {
        for node in nodes {
            node.children = sorted(node.children)
            sort(node.children)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        roots = sorted(roots)
        sort(roots)
        outline.reloadData()
    }

    private func kind(_ node: PreviewNode) -> String {
        if node.entry?.isSymbolicLink == true { return text("Symbolic link") }
        if node.isDirectory { return text("Folder") }
        return UTType(filenameExtension: (node.name as NSString).pathExtension)?.localizedDescription ?? text("File")
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? PreviewNode, let id = tableColumn?.identifier else { return nil }
        let cell = (outline.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        switch id.rawValue {
        case "date": cell.textField?.stringValue = node.entry?.modificationDate.map(dates.string) ?? "—"
        case "size": cell.textField?.stringValue = node.entry?.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        case "kind": cell.textField?.stringValue = kind(node)
        default:
            cell.textField?.stringValue = node.name
            let type = node.isDirectory ? UTType.folder : UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .item
            cell.imageView?.image = NSWorkspace.shared.icon(for: type)
            cell.imageView?.setAccessibilityElement(false)
        }
        cell.toolTip = node.path
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        var leading = cell.leadingAnchor
        var inset: CGFloat = 4
        if id.rawValue == "name" {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            cell.imageView = icon
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16)
            ])
            leading = icon.trailingAnchor
            inset = 6
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leading, constant: inset),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
