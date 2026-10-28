import Foundation
import CoreGraphics
import ImageIO

/// 图片处理目标格式
public enum ImageTargetFormat: String, CaseIterable, Equatable {
    case png
    case jpeg
    case heic

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        }
    }

    public var utType: CFString {
        switch self {
        case .png: return "public.png" as CFString
        case .jpeg: return "public.jpeg" as CFString
        case .heic: return "public.heic" as CFString
        }
    }
}

/// 图片操作类型
public enum ImageTransformOperation: Equatable {
    case convert(format: ImageTargetFormat)
    case scale(maxPixelSize: Int)
}

/// 图片处理错误
public enum ImageTransformError: LocalizedError, Equatable {
    case multiFrameNotSupported(frameCount: Int)
    case alreadySmallerThanTarget(longEdge: Int, target: Int)
    case cannotReadImageSource, cannotCreateThumbnail, cannotCreateDestination, cannotCreateContext
    case pixelCountExceedsLimit(pixels: Int, limit: Int)
    case unwritableSourceFormat(String)
    case invalidScaleSize

    public var errorDescription: String? {
        switch self {
        case .multiFrameNotSupported(let count):
            return String(format: NSLocalizedString("多帧图片暂不支持处理（共 %d 帧）", comment: "image error"), count)
        case .alreadySmallerThanTarget(let edge, let target):
            return String(format: NSLocalizedString("图片长边（%d 像素）未超过 %d 像素，已跳过", comment: "image error"), edge, target)
        case .cannotReadImageSource:
            return NSLocalizedString("无法读取图片或文件已损坏", comment: "image error")
        case .cannotCreateThumbnail:
            return NSLocalizedString("图像解码缩放失败", comment: "image error")
        case .cannotCreateDestination:
            return NSLocalizedString("无法创建输出图片", comment: "image error")
        case .pixelCountExceedsLimit(let pixels, let limit):
            return String(format: NSLocalizedString("图片像素（%@）超过格式转换上限（%@），请先使用缩放缩小尺寸后再转换", comment: "image error"), String(pixels), String(limit))
        case .unwritableSourceFormat(let ext):
            return String(format: NSLocalizedString("不支持写出 %@ 格式，无法直接缩放。请先转换为 PNG/JPEG/HEIC", comment: "image error"), ext)
        case .cannotCreateContext:
            return NSLocalizedString("创建图像绘制上下文失败", comment: "image error")
        case .invalidScaleSize:
            return NSLocalizedString("缩放长边必须在 1 至 2560 像素之间", comment: "image error")
        }
    }
}

/// ImageIO 图片快速转换与缩放核心
public enum ImageTransformer {

    /// 转换操作的像素内存上限（宽 x 高），超出则拦截并提示先缩放；缩放操作走流式缩略图下采样不受此限制
    public static let maxConversionPixels = 40_000_000

    /// 解码前检查转换尺寸，避免像素乘法溢出或分配过大的完整位图。
    public static func validateConversionSize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else { throw ImageTransformError.cannotReadImageSource }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maxConversionPixels else {
            throw ImageTransformError.pixelCountExceedsLimit(pixels: overflow ? Int.max : pixels, limit: maxConversionPixels)
        }
    }

    /// 读取图片头部元数据（格式及有效尺寸），不完整解码大图
    public static func inspectImageHeader(at url: URL) -> InspectedImageItem? {
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: kCFBooleanFalse as Any
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else {
            return nil
        }
        guard CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        guard let typeCF = CGImageSourceGetType(source) else {
            return nil
        }
        guard CGImageSourceGetStatus(source) == .statusComplete else { return nil }
        let format = ImageSourceFormat.from(uti: typeCF)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [CFString: Any] else {
            return nil
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else {
            return nil
        }
        return InspectedImageItem(format: format, width: w, height: h)
    }

    /// 铺白底，用于将透明通道图片转为无透明度的 JPEG（避免透明区域变黑）
    public static func flattenOnWhiteBackground(_ image: CGImage) throws -> CGImage {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw ImageTransformError.cannotCreateThumbnail
        }
        // 尽量沿用原图的 RGB 色彩空间，保留 ICC
        let colorSpace: CGColorSpace
        if let cs = image.colorSpace, cs.model == .rgb {
            colorSpace = cs
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ImageTransformError.cannotCreateContext
        }
        // 填充白色背景
        context.setFillColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 绘制原图
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let flattened = context.makeImage() else {
            throw ImageTransformError.cannotCreateContext
        }
        return flattened
    }

    /// 检查图片源属性（长宽、帧数等），若多帧或无法读取则抛错
    public static func inspectImageSource(
        _ source: CGImageSource
    ) throws -> (width: Int, height: Int, frameCount: Int, props: [CFString: Any]) {
        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            throw ImageTransformError.cannotReadImageSource
        }
        if count > 1 {
            throw ImageTransformError.multiFrameNotSupported(frameCount: count)
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ImageTransformError.cannotReadImageSource
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard w > 0, h > 0 else { throw ImageTransformError.cannotReadImageSource }
        return (w, h, count, props)
    }

    /// 执行转换或缩放，将新文件输出到目标目录
    @discardableResult
    public static func process(
        sourceURL: URL,
        operation: ImageTransformOperation,
        outputDirectory: URL? = nil,
        registry: ScratchDirectoryRegistry = ScratchDirectoryRegistry()
    ) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true, FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw ImageTransformError.cannotReadImageSource
        }
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: kCFBooleanFalse as Any
        ]
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions as CFDictionary) else {
            throw ImageTransformError.cannotReadImageSource
        }

        let (width, height, _, sourceProps) = try inspectImageSource(source)
        let longEdge = max(width, height)
        guard let sourceUTIType = CGImageSourceGetType(source) else {
            throw ImageTransformError.cannotReadImageSource
        }
        let sourceUTI = sourceUTIType as String

        let targetUTType: CFString
        let targetExt: String
        let thumbnailMaxPixelSize: Int
        let needsFlattenJPEG: Bool

        switch operation {
        case .convert(let fmt):
            // 转换模式：在解码前检查像素上限，超过则拦截提示先缩放
            try validateConversionSize(width: width, height: height)
            targetUTType = fmt.utType
            targetExt = fmt.fileExtension
            thumbnailMaxPixelSize = max(longEdge, 1)
            needsFlattenJPEG = (fmt == .jpeg)

        case .scale(let maxPixel):
            guard (1...2560).contains(maxPixel) else { throw ImageTransformError.invalidScaleSize }
            // 缩放模式：长边未超尺寸不放大
            guard longEdge > maxPixel else {
                throw ImageTransformError.alreadySmallerThanTarget(longEdge: longEdge, target: maxPixel)
            }
            // 检查当前系统对源图片格式的可写支持
            let writableTypes = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
            guard !sourceUTI.lowercased().contains("webp"), writableTypes.contains(sourceUTI) else {
                throw ImageTransformError.unwritableSourceFormat(sourceURL.pathExtension)
            }
            // 保持源格式与扩展名
            targetUTType = sourceUTIType
            targetExt = sourceURL.pathExtension
            thumbnailMaxPixelSize = maxPixel
            // 保持原格式缩放，无需铺白底
            needsFlattenJPEG = false
        }

        // 解码与缩放：大图通过缩略图接口流式下采样，避免内存暴涨
        // 配合 kCGImageSourceCreateThumbnailWithTransform 保证应用 EXIF 方向
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: kCFBooleanTrue as Any,
            kCGImageSourceCreateThumbnailWithTransform: kCFBooleanTrue as Any,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize as NSNumber,
            kCGImageSourceShouldCache: kCFBooleanFalse as Any
        ]

        guard var cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageTransformError.cannotCreateThumbnail
        }

        // 如果转为 JPEG，铺白底消除透明通道（避免透明黑底）
        if needsFlattenJPEG {
            cgImage = try flattenOnWhiteBackground(cgImage)
        }

        // 清洗元数据，设置有损质量 0.9（如果目标格式是 JPEG 或 HEIC）
        var destProps = sourceProps
        destProps[kCGImagePropertyOrientation] = 1
        destProps.removeValue(forKey: kCGImagePropertyPixelWidth)
        destProps.removeValue(forKey: kCGImagePropertyPixelHeight)
        if let tiff = destProps[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            var cleanTIFF = tiff
            cleanTIFF[kCGImagePropertyTIFFOrientation] = 1
            cleanTIFF.removeValue(forKey: "ImageWidth" as CFString)
            cleanTIFF.removeValue(forKey: "ImageLength" as CFString)
            destProps[kCGImagePropertyTIFFDictionary] = cleanTIFF
        }
        if let exif = destProps[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            var cleanExif = exif
            cleanExif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            cleanExif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            destProps[kCGImagePropertyExifDictionary] = cleanExif
        }
        let isLossy = (targetUTType == ("public.jpeg" as CFString) || targetUTType == ("public.heic" as CFString))
        if isLossy {
            destProps[kCGImageDestinationLossyCompressionQuality] = 0.9
        }

        let targetDir = outputDirectory ?? sourceURL.deletingLastPathComponent()

        // 通过 ScratchDirectoryRegistry 登记与创建同卷临时目录，防止崩溃或强退残留
        let scratchDir = try registry.makeScratchDirectory(in: targetDir)
        defer {
            registry.remove(scratchDir)
        }

        let tempFileURL = scratchDir.appendingPathComponent("output.\(targetExt)")
        guard let destination = CGImageDestinationCreateWithURL(tempFileURL as CFURL, targetUTType, 1, nil) else {
            throw ImageTransformError.cannotCreateDestination
        }

        CGImageDestinationAddImage(destination, cgImage, destProps as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageTransformError.cannotCreateDestination
        }

        // 基础名
        let baseName: String
        switch operation {
        case .convert:
            baseName = sourceURL.deletingPathExtension().lastPathComponent
        case .scale(let maxPixel):
            baseName = "\(sourceURL.deletingPathExtension().lastPathComponent) \(maxPixel)px"
        }

        // 通过 ExclusiveRename 原子不覆盖移动，复用 UniqueName 规则编号避开已有文件和悬空软链
        return try ExclusiveRename.move(tempFileURL, into: targetDir) { index in
            UniqueName.candidateName(baseName: baseName, ext: targetExt, counter: index)
        }
    }
}
