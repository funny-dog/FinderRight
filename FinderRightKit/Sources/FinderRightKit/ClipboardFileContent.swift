import AppKit
import ImageIO
import UniformTypeIdentifiers

/// 读取文字、内嵌图片或经调用方授权的单张图片文件。
public struct ClipboardFileContent {
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

    public static func read(from pasteboard: NSPasteboard, allowFile: (URL) -> Bool = { _ in false }) throws -> ClipboardFileContent {
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if (pasteboard.types ?? []).contains(.fileURL) || (pasteboard.types ?? []).contains(filenamesType) {
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
                ?? (pasteboard.propertyList(forType: filenamesType) as? [String])?.map { URL(fileURLWithPath: $0) }
                ?? []
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
        guard CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw ReadError.invalidImage }
        try ImageTransformer.validateConversionSize(width: width, height: height)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: max(width, height)]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ReadError.invalidImage }
        return ClipboardFileContent(data: try encode(image, as: .png), fileExtension: "png")
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
