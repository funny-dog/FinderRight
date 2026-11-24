import AppKit
import FinderRightKit
import ImageIO
import UniformTypeIdentifiers


// MARK: - 缩略图与详情图像加载器

struct ClipboardImageDetail {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int64
}

enum ClipboardPreviewLoader {
    private static let thumbCache: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 40
        return cache
    }()

    private static let detailCache: NSCache<NSUUID, ClipboardImageDetailBox> = {
        let cache = NSCache<NSUUID, ClipboardImageDetailBox>()
        cache.countLimit = 20
        return cache
    }()

    private final class ClipboardImageDetailBox {
        let detail: ClipboardImageDetail
        init(_ detail: ClipboardImageDetail) {
            self.detail = detail
        }
    }

    private static let maxThumbPixels = 88
    private static let maxDetailPixels = 1440
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp", "ico"
    ]

    static func thumbnail(for item: ClipboardItem) -> NSImage? {
        let key = item.id as NSUUID
        if let cached = thumbCache.object(forKey: key) {
            return cached
        }
        guard let image = buildImage(for: item, maxPixels: maxThumbPixels) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    static func imageDetail(for item: ClipboardItem) -> ClipboardImageDetail? {
        let key = item.id as NSUUID
        if let cached = detailCache.object(forKey: key) {
            return cached.detail
        }
        guard let detail = buildImageDetail(for: item) else { return nil }
        detailCache.setObject(ClipboardImageDetailBox(detail), forKey: key)
        return detail
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = IPCBridge.realUserHomeDirectory.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func buildImage(for item: ClipboardItem, maxPixels: Int) -> NSImage? {
        switch item.kind {
        case .text:
            return nil
        case .image(let data, _, _):
            if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let thumb = makeCGThumbnail(from: source, maxPixels: maxPixels) {
                return thumb
            }
            return NSImage(data: data)
        case .files(let urls):
            guard let url = urls.first, isImageFile(url) else { return nil }
            if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let thumb = makeCGThumbnail(from: source, maxPixels: maxPixels) {
                return thumb
            }
            return NSImage(contentsOf: url)
        }
    }

    private static func buildImageDetail(for item: ClipboardItem) -> ClipboardImageDetail? {
        switch item.kind {
        case .text:
            return nil

        case .image(let data, let width, let height):
            guard let image = buildImage(for: item, maxPixels: maxDetailPixels) else { return nil }
            return ClipboardImageDetail(
                image: image,
                pixelWidth: width,
                pixelHeight: height,
                byteCount: Int64(data.count)
            )

        case .files(let urls):
            guard let url = urls.first, isImageFile(url),
                  let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) >= 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  let image = makeCGThumbnail(from: source, maxPixels: maxDetailPixels) ?? NSImage(contentsOf: url) else {
                return nil
            }
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            let byteCount = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            return ClipboardImageDetail(
                image: image,
                pixelWidth: width,
                pixelHeight: height,
                byteCount: byteCount
            )
        }
    }

    private static func makeCGThumbnail(from source: CGImageSource, maxPixels: Int) -> NSImage? {
        guard CGImageSourceGetCount(source) >= 1 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func isImageFile(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]) {
            if values.isDirectory == true { return false }
            if let type = values.contentType, type.conforms(to: .image) {
                return true
            }
        }
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
            return true
        }
        return imageExtensions.contains(url.pathExtension.lowercased())
    }
}
