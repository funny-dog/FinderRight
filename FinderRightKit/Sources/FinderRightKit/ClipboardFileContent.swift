import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 读取文字、内嵌图片或经调用方授权的单张图片文件。
public struct ClipboardFileContent {
    public static let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    public let data: Data
    public let fileExtension: String

    public func encodedData(for ext: String) throws -> Data {
        guard fileExtension == "png" else { return data }
        guard let format = ImageTargetFormat.allCases.first(where: { $0.fileExtension == ext }) else {
            throw ReadError.unsupported
        }
        if format == .png { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ReadError.invalidImage }
        return try Self.encode(image, as: format)
    }

    public enum ReadError: LocalizedError, Equatable {
        case unsupported
        case invalidImage

        public var errorDescription: String? {
            switch self {
            case .unsupported: return NSLocalizedString("剪贴板中没有可保存的文字或图片", comment: "clipboard file")
            case .invalidImage: return NSLocalizedString("无法读取剪贴板图片", comment: "clipboard file")
            }
        }
    }

    /// 剪贴板是否声明了本地文件引用类型（`.fileURL` 或 `NSFilenamesPboardType`）
    public static func containsFileReferenceTypes(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(.fileURL) || types.contains(filenamesPasteboardType)
    }

    /// 从剪贴板读取本地文件 URL 列表（兼容 `.fileURL` 与 `NSFilenamesPboardType`）
    public static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard containsFileReferenceTypes(pasteboard) else { return [] }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.filter(\.isFileURL)
        }
        if let paths = pasteboard.propertyList(forType: filenamesPasteboardType) as? [String],
           !paths.isEmpty {
            return paths.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0) }
        }
        return []
    }

    /// 读取并校验单帧图片的像素尺寸（须在 `ImageTransformer.maxConversionPixels` 上限内）
    public static func validatedImageDimensions(from source: CGImageSource) throws -> (width: Int, height: Int) {
        guard CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ReadError.invalidImage
        }
        try ImageTransformer.validateConversionSize(width: width, height: height)
        return (width, height)
    }

    public static func validatedImageDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return try? validatedImageDimensions(from: source)
    }

    /// 将图片源按 EXIF 方向归一化并编码为 PNG 数据及最终像素宽高
    public static func normalizedPNG(from source: CGImageSource) throws -> (data: Data, width: Int, height: Int) {
        let (width, height) = try validatedImageDimensions(from: source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ReadError.invalidImage
        }
        return (try encode(image, as: .png), image.width, image.height)
    }

    public static func normalizedPNG(from data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return try? normalizedPNG(from: source)
    }

    public static func read(from pasteboard: NSPasteboard, allowFile: (URL) -> Bool = { _ in false }) throws -> ClipboardFileContent {
        if containsFileReferenceTypes(pasteboard) {
            let urls = fileURLs(from: pasteboard)
            guard urls.count == 1, let url = urls.first, url.isFileURL, allowFile(url),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey]),
                  values.isRegularFile == true, values.contentType?.conforms(to: .image) == true else {
                throw ReadError.unsupported
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ReadError.invalidImage
            }
            return try png(from: source)
        }
        if let type = pasteboard.availableType(from: [.png, .tiff]) {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ReadError.invalidImage
            }
            return try png(from: source)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { throw ReadError.unsupported }
        return ClipboardFileContent(data: Data(text.utf8), fileExtension: "txt")
    }

    private static func png(from source: CGImageSource) throws -> ClipboardFileContent {
        let normalized = try normalizedPNG(from: source)
        return ClipboardFileContent(data: normalized.data, fileExtension: "png")
    }

    private static func encode(_ image: CGImage, as format: ImageTargetFormat) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.utType, 1, nil) else {
            throw ImageTransformError.cannotCreateDestination
        }
        let image = format == .jpeg ? try ImageTransformer.flattenOnWhiteBackground(image) : image
        let properties: [CFString: Any] = format == .png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageTransformError.cannotCreateDestination }
        return output as Data
    }
}
