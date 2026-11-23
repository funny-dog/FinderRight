import CoreGraphics
import Foundation

/// 截图入口的触发方式（默认系统原生）
public enum ScreenshotMode: String, Codable, CaseIterable, Identifiable {
    /// 唤起 macOS 原生「截屏」面板（⌘⇧5），无需额外权限
    case system
    /// 瞬时抓取屏幕静态快照，全屏框选并复制或保存到常用目录
    case snapshot

    public var id: String { rawValue }

    /// 设置界面显示名的本地化 key
    public var titleKey: String {
        switch self {
        case .system: return "系统原生"
        case .snapshot: return "FinderRight 快照"
        }
    }
}

/// FinderRight 快照截图的纯几何与命名逻辑（脱离 AppKit 窗口以便单元测试）。
public enum ScreenshotSnapshotGeometry {

    /// 默认截图文件名（不含扩展名），例如 "截图 2026-11-23 04.25.00"
    public static func defaultBaseName(at date: Date = Date(),
                                       timeZone: TimeZone = .current,
                                       prefix: String = NSLocalizedString("截图", comment: "default screenshot filename prefix")) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date))"
    }

    /// 将 AppKit 视图坐标（左下角为原点）下的选区，换算为 CGImage 像素坐标（左上角为原点）下的裁剪矩形。
    /// 若选区无效或宽高不足 2 像素则返回 nil。
    public static func pixelCropRect(selectionInView rect: CGRect,
                                     viewSize: CGSize,
                                     imageWidth: Int,
                                     imageHeight: Int) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0,
              imageWidth > 0, imageHeight > 0 else { return nil }
        let normalized = rect.standardized
        let viewBounds = CGRect(origin: .zero, size: viewSize)
        let clipped = normalized.intersection(viewBounds)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }

        let scaleX = CGFloat(imageWidth) / viewSize.width
        let scaleY = CGFloat(imageHeight) / viewSize.height

        let pixelRect = CGRect(
            x: clipped.minX * scaleX,
            y: (viewSize.height - clipped.maxY) * scaleY,
            width: clipped.width * scaleX,
            height: clipped.height * scaleY
        )
        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let integral = pixelRect.integral.intersection(imageBounds)
        guard !integral.isNull, integral.width >= 2, integral.height >= 2 else { return nil }
        return integral
    }

    /// 在当前 CoreGraphics 上下文中绘制画笔轨迹。
    public static func drawStrokes(_ strokes: [ScreenshotBrushStroke], in context: CGContext) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)

        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let color = stroke.color.cgColor
            let width = max(1, stroke.lineWidth)
            let isSinglePoint = stroke.points.count == 1
                || stroke.points.allSatisfy { hypot($0.x - first.x, $0.y - first.y) < 0.01 }

            if isSinglePoint {
                let radius = width / 2
                let dotRect = CGRect(x: first.x - radius, y: first.y - radius, width: width, height: width)
                context.setFillColor(color)
                context.fillEllipse(in: dotRect)
            } else {
                context.beginPath()
                context.move(to: first)
                for point in stroke.points.dropFirst() {
                    context.addLine(to: point)
                }
                context.setStrokeColor(color)
                context.setLineWidth(width)
                context.strokePath()
            }
        }

        context.restoreGState()
    }

    /// 将视图坐标系下的画笔轨迹按裁剪像素区域合成到裁剪后的截图上。
    public static func renderCroppedImage(_ croppedImage: CGImage,
                                          strokes: [ScreenshotBrushStroke],
                                          viewSize: CGSize,
                                          imageWidth: Int,
                                          imageHeight: Int,
                                          cropRect: CGRect) -> CGImage {
        guard !strokes.isEmpty,
              viewSize.width > 0, viewSize.height > 0,
              imageWidth > 0, imageHeight > 0 else {
            return croppedImage
        }

        let width = croppedImage.width
        let height = croppedImage.height
        let fallbackSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let preferredSpace: CGColorSpace
        if let imageSpace = croppedImage.colorSpace, imageSpace.model == .rgb {
            preferredSpace = imageSpace
        } else {
            preferredSpace = fallbackSpace
        }

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: preferredSpace,
            bitmapInfo: bitmapInfo
        ) ?? CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: fallbackSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return croppedImage
        }

        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scaleX = CGFloat(imageWidth) / viewSize.width
        let scaleY = CGFloat(imageHeight) / viewSize.height
        context.translateBy(x: -cropRect.minX, y: -(CGFloat(imageHeight) - cropRect.maxY))
        context.scaleBy(x: scaleX, y: scaleY)

        drawStrokes(strokes, in: context)
        return context.makeImage() ?? croppedImage
    }
}

public struct ScreenshotRGBA: Equatable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

public struct ScreenshotBrushStroke: Equatable {
    public var points: [CGPoint]
    public var color: ScreenshotRGBA
    public var lineWidth: CGFloat

    public init(points: [CGPoint], color: ScreenshotRGBA, lineWidth: CGFloat) {
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
    }
}
