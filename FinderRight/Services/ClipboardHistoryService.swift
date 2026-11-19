import AppKit
import Combine
import FinderRightKit
import ImageIO

/// 内存剪贴板历史服务：默认关闭，开启后仅在内存中保留最近 N 条文本、图片或文件引用。
final class ClipboardHistoryService: ObservableObject {
    static let shared = ClipboardHistoryService()

    private static let pollInterval: TimeInterval = 0.5
    private static let maxTextUTF8Bytes = 1_048_576 // 1 MiB
    private static let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var isEnabled: Bool
    @Published private(set) var limit: Int
    @Published private(set) var isPinned: Bool
    @Published private(set) var showDetails: Bool

    private let config: SharedConfig
    private var store: ClipboardHistoryStore
    private var timer: Timer?
    private var lastChangeCount: Int
    private let tempDragDirectory: URL

    init(config: SharedConfig = .shared) {
        self.config = config
        let savedLimit = config.clipboardHistoryLimit
        self.isEnabled = config.clipboardEnabled
        self.limit = savedLimit
        self.isPinned = config.clipboardWindowPinned
        self.showDetails = config.clipboardShowDetails
        self.store = ClipboardHistoryStore(limit: savedLimit)
        self.lastChangeCount = NSPasteboard.general.changeCount
        self.tempDragDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderRightClipboard-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }

    deinit {
        timer?.invalidate()
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
        let pinned = config.clipboardWindowPinned
        let details = config.clipboardShowDetails

        isEnabled = enabled
        limit = configuredLimit
        isPinned = pinned
        showDetails = details
        store.setLimit(configuredLimit)
        items = store.items

        if enabled {
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
    }

    /// 将条目写回系统剪贴板并置顶，返回是否写入成功
    @discardableResult
    func copyItem(_ item: ClipboardItem) -> Bool {
        let pasteboard = NSPasteboard.general
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

        lastChangeCount = pasteboard.changeCount
        guard wrote else {
            ClipboardToast.showCopied(message: NSLocalizedString("无法写入剪贴板", comment: "notification"), isWarning: true)
            return false
        }

        store.record(item.kind)
        items = store.items
        ClipboardToast.showCopied()
        return true
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
    }

    private func pollPasteboard() {
        guard isEnabled else { return }
        let pasteboard = NSPasteboard.general
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let kind = readPasteboardKind(from: pasteboard) else { return }
        let previousImageIds = Set(store.items.compactMap { item -> UUID? in
            if case .image = item.kind { return item.id }
            return nil
        })

        store.record(kind)
        items = store.items

        let currentIds = Set(store.items.map(\.id))
        for droppedId in previousImageIds.subtracting(currentIds) {
            try? FileManager.default.removeItem(at: temporaryFileURL(forItemId: droppedId))
        }
    }

    private func readPasteboardKind(from pasteboard: NSPasteboard) -> ClipboardItem.Kind? {
        let types = pasteboard.types ?? []
        if types.contains(.fileURL) || types.contains(Self.filenamesPasteboardType) {
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                ?? (pasteboard.propertyList(forType: Self.filenamesPasteboardType) as? [String])?.map { URL(fileURLWithPath: $0) }
                ?? [])
                .filter(\.isFileURL)
            if !urls.isEmpty {
                return .files(urls)
            }
        }

        if let pngData = pasteboard.data(forType: .png),
           let (width, height) = imageDimensions(from: pngData) {
            return .image(pngData, pixelWidth: width, pixelHeight: height)
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let (pngData, width, height) = encodePNG(from: tiffData) {
            return .image(pngData, pixelWidth: width, pixelHeight: height)
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty,
           text.utf8.count <= Self.maxTextUTF8Bytes {
            return .text(text)
        }

        return nil
    }

    private func imageDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (try? ImageTransformer.validateConversionSize(width: width, height: height)) != nil else {
            return nil
        }
        return (width, height)
    }

    private func encodePNG(from data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (try? ImageTransformer.validateConversionSize(width: width, height: height)) != nil else {
            return nil
        }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, ImageTargetFormat.png.utType, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, cgImage.width, cgImage.height)
    }

    private func temporaryFileURL(forItemId id: UUID) -> URL {
        tempDragDirectory.appendingPathComponent("Clipboard-\(id.uuidString.prefix(8)).png")
    }

    private func cleanupAllTemporaryFiles() {
        try? FileManager.default.removeItem(at: tempDragDirectory)
    }
}
