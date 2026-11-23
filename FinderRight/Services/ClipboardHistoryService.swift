import AppKit
import Combine
import FinderRightKit

/// 轻量剪贴板历史服务：默认开启，在本机保留最近 N 条文本、图片或文件引用（关闭或清空时删除磁盘数据）。
final class ClipboardHistoryService: ObservableObject {
    static let shared = ClipboardHistoryService()

    private static let pollInterval: TimeInterval = 0.5

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var isEnabled: Bool
    @Published private(set) var limit: Int
    @Published private(set) var recordSensitive: Bool
    @Published private(set) var isPinned: Bool
    @Published private(set) var showDetails: Bool

    private let config: SharedConfig
    private let persistence: ClipboardHistoryPersistence
    private let ioQueue = DispatchQueue(label: "com.finderright.app.clipboardHistory.io", qos: .utility)
    private var store: ClipboardHistoryStore
    private var timer: Timer?
    private var mouseMonitor: Any?
    private var sensitiveMenuBarTracker = ClipboardHistoryStore.SensitiveMenuBarTracker()
    private var lastChangeCount: Int
    private let tempDragDirectory: URL

    init(config: SharedConfig = .shared,
         persistence: ClipboardHistoryPersistence = ClipboardHistoryPersistence()) {
        self.config = config
        self.persistence = persistence
        let savedLimit = config.clipboardHistoryLimit
        let enabled = config.clipboardEnabled
        self.isEnabled = enabled
        self.limit = savedLimit
        self.recordSensitive = config.clipboardRecordSensitive
        self.isPinned = config.clipboardWindowPinned
        self.showDetails = config.clipboardShowDetails
        if enabled {
            let restored = persistence.load(limit: savedLimit)
            self.store = ClipboardHistoryStore(limit: savedLimit, items: restored)
            self.items = self.store.items
        } else {
            self.store = ClipboardHistoryStore(limit: savedLimit)
            self.items = []
            ioQueue.async {
                persistence.clear()
            }
        }
        self.lastChangeCount = NSPasteboard.general.changeCount
        self.tempDragDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderRightClipboard-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    deinit {
        timer?.invalidate()
        removeMouseMonitor()
        cleanupAllTemporaryFiles()
    }

    func start() {
        refreshConfig()
    }

    func setEnabled(_ enabled: Bool) {
        config.clipboardEnabled = enabled
        refreshConfig()
        GlobalClipboardShortcut.shared.refresh()
    }

    func setLimit(_ newLimit: Int) {
        config.clipboardHistoryLimit = newLimit
        refreshConfig()
    }

    func setRecordSensitive(_ enabled: Bool) {
        config.clipboardRecordSensitive = enabled
        refreshConfig()
    }

    func setPinned(_ pinned: Bool) {
        config.clipboardWindowPinned = pinned
        isPinned = config.clipboardWindowPinned
    }

    func setShowDetails(_ show: Bool) {
        config.clipboardShowDetails = show
        showDetails = config.clipboardShowDetails
    }

    func refreshConfig() {
        config.reload()
        let enabled = config.clipboardEnabled
        let configuredLimit = config.clipboardHistoryLimit
        let allowSensitive = config.clipboardRecordSensitive
        let pinned = config.clipboardWindowPinned
        let details = config.clipboardShowDetails

        isEnabled = enabled
        limit = configuredLimit
        recordSensitive = allowSensitive
        isPinned = pinned
        showDetails = details

        if enabled {
            let previousItems = store.items
            store.setLimit(configuredLimit)
            items = store.items
            if store.items != previousItems {
                persistSnapshot()
            }
            startPollingIfNeeded()
        } else {
            stopPolling()
            clear()
            ClipboardHistoryController.shared.close()
        }
    }

    func clear() {
        store.clear()
        items = []
        cleanupAllTemporaryFiles()
        let persistence = self.persistence
        ioQueue.async {
            persistence.clear()
        }
    }

    /// 退出前停止轮询并等待在途写盘完成，保留持久化历史并清理拖拽临时文件。
    func prepareForTermination() {
        stopPolling()
        ioQueue.sync {}
        cleanupAllTemporaryFiles()
    }

    /// 将条目写回系统剪贴板并置顶，返回是否写入成功
    @discardableResult
    func copyItem(_ item: ClipboardItem,
                  pasteboard: NSPasteboard = .general,
                  showToast: Bool = true) -> Bool {
        pasteboard.clearContents()

        let wrote: Bool
        switch item.kind {
        case .text(let text):
            wrote = pasteboard.setString(text, forType: .string)
        case .image(let data, _, _):
            wrote = pasteboard.setData(data, forType: .png)
        case .files(let urls):
            wrote = pasteboard.writeObjects(urls.map { $0 as NSURL })
        }

        if pasteboard === NSPasteboard.general {
            lastChangeCount = pasteboard.changeCount
        }
        guard wrote else {
            if showToast {
                ClipboardToast.showCopied(message: NSLocalizedString("无法写入剪贴板", comment: "notification"), isWarning: true)
            }
            return false
        }

        store.record(item.kind, id: item.id)
        items = store.items
        persistSnapshot()
        if showToast {
            ClipboardToast.showCopied()
        }
        return true
    }

    func filterDroppedFileURLs(_ urls: [URL]) -> [URL] {
        ClipboardHistoryStore.normalizedFileURLs(urls, excludingDirectory: tempDragDirectory)
    }

    /// 接收外部拖入的本地文件：同步写入系统剪贴板、记入历史顶部并持久化。
    @discardableResult
    func recordDroppedFiles(_ urls: [URL],
                            pasteboard: NSPasteboard = .general,
                            showToast: Bool = true) -> Bool {
        guard isEnabled else { return false }
        let filtered = filterDroppedFileURLs(urls)
        guard !filtered.isEmpty else { return false }
        return copyItem(ClipboardItem(kind: .files(filtered)), pasteboard: pasteboard, showToast: showToast)
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        ClipboardFileContent.fileURLs(from: pasteboard)
    }

    /// 为图片条目生成临时 PNG 文件 URL，便于拖入 Finder 或其他接收文件的应用
    func temporaryDragFileURL(for item: ClipboardItem) -> URL? {
        guard case .image(let data, _, _) = item.kind else { return nil }
        let fileURL = temporaryFileURL(forItemId: item.id)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        do {
            try PrivateStorage.ensurePrivateDirectory(tempDragDirectory)
            try data.write(to: fileURL, options: .atomic)
            PrivateStorage.restrictFile(fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    // MARK: - 剪贴板轮询

    private func startPollingIfNeeded() {
        updateMouseMonitor()
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let pollTimer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
        RunLoop.main.add(pollTimer, forMode: .common)
        timer = pollTimer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        removeMouseMonitor()
        sensitiveMenuBarTracker.clear()
    }

    private func updateMouseMonitor() {
        guard isEnabled && !recordSensitive else {
            removeMouseMonitor()
            sensitiveMenuBarTracker.clear()
            return
        }
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.handleGlobalMouseDown()
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    private func handleGlobalMouseDown() {
        guard isEnabled && !recordSensitive else { return }
        let popovers = visibleSensitiveMenuBarPopovers()
        guard !popovers.isEmpty else {
            sensitiveMenuBarTracker.clear()
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let clickPoint = ClipboardHistoryStore.quartzPoint(
            fromCocoaPoint: NSEvent.mouseLocation,
            primaryScreenHeight: primaryHeight
        )
        if popovers.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(clickPoint) }) {
            sensitiveMenuBarTracker.arm(changeCount: NSPasteboard.general.changeCount)
        } else {
            sensitiveMenuBarTracker.clear()
        }
    }

    private func visibleSensitiveMenuBarPopovers() -> [CGRect] {
        var pidBundleMap: [pid_t: String] = [:]
        for bundleId in ClipboardHistoryStore.sensitiveMenuBarBundleIdentifiers {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
                pidBundleMap[app.processIdentifier] = bundleId
            }
        }
        guard !pidBundleMap.isEmpty else { return [] }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var rects: [CGRect] = []
        for entry in windowList {
            guard let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let bundleId = pidBundleMap[pid_t(pidNumber.intValue)],
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if ClipboardHistoryStore.isSensitiveMenuBarPopover(
                ownerBundleIdentifier: bundleId,
                bounds: bounds,
                layer: layer
            ) {
                rects.append(bounds)
            }
        }
        return rects
    }

    private func focusedApplicationBundleIdentifier() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let focusedApp,
              CFGetTypeID(focusedApp) == AXUIElementGetTypeID() else {
            return nil
        }
        var pid: pid_t = 0
        let axElement = unsafeBitCast(focusedApp, to: AXUIElement.self)
        guard AXUIElementGetPid(axElement, &pid) == .success, pid != 0 else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private func pollPasteboard() {
        guard isEnabled else { return }
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount

        let popoverVisible = !recordSensitive && !visibleSensitiveMenuBarPopovers().isEmpty
        if popoverVisible && currentCount == lastChangeCount {
            sensitiveMenuBarTracker.arm(changeCount: currentCount)
        }

        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if !recordSensitive {
            let consumedGrace = sensitiveMenuBarTracker.consumeIfActive(newChangeCount: currentCount)
            if popoverVisible || consumedGrace {
                return
            }
        }

        guard let kind = readPasteboardKind(from: pasteboard) else { return }
        let previousImageIds = Set(store.items.compactMap { item -> UUID? in
            if case .image = item.kind { return item.id }
            return nil
        })

        store.record(kind)
        items = store.items
        persistSnapshot()

        let currentIds = Set(store.items.map(\.id))
        for droppedId in previousImageIds.subtracting(currentIds) {
            try? FileManager.default.removeItem(at: temporaryFileURL(forItemId: droppedId))
        }
    }

    private func persistSnapshot() {
        let snapshot = store.items
        let persistence = self.persistence
        ioQueue.async {
            persistence.save(snapshot)
        }
    }

    private func readPasteboardKind(from pasteboard: NSPasteboard) -> ClipboardItem.Kind? {
        if !recordSensitive {
            var typeIdentifiers = (pasteboard.types ?? []).map(\.rawValue)
            if let itemTypes = pasteboard.pasteboardItems?.flatMap({ $0.types.map(\.rawValue) }) {
                typeIdentifiers.append(contentsOf: itemTypes)
            }
            let sourceBundleIds = [
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                focusedApplicationBundleIdentifier(),
            ].compactMap { $0 }
            if ClipboardHistoryStore.shouldIgnorePasteboard(
                typeIdentifiers: typeIdentifiers,
                sourceBundleIdentifiers: sourceBundleIds,
                allowSensitive: false
            ) {
                return nil
            }
        }

        let urls = Self.fileURLs(from: pasteboard)
        if !urls.isEmpty {
            return .files(urls)
        }

        if let pngData = pasteboard.data(forType: .png),
           pngData.count <= ClipboardHistoryPersistence.maxImageBytes,
           let (width, height) = ClipboardFileContent.validatedImageDimensions(from: pngData) {
            return .image(pngData, pixelWidth: width, pixelHeight: height)
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let (pngData, width, height) = ClipboardFileContent.normalizedPNG(from: tiffData),
           pngData.count <= ClipboardHistoryPersistence.maxImageBytes {
            return .image(pngData, pixelWidth: width, pixelHeight: height)
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty,
           text.utf8.count <= ClipboardHistoryPersistence.maxTextUTF8Bytes {
            return .text(text)
        }

        return nil
    }

    private func temporaryFileURL(forItemId id: UUID) -> URL {
        tempDragDirectory.appendingPathComponent("Clipboard-\(id.uuidString.prefix(8)).png")
    }

    private func cleanupAllTemporaryFiles() {
        try? FileManager.default.removeItem(at: tempDragDirectory)
    }
}
