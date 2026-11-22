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
}
