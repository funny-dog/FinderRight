import AppKit

/// 只保留显示所需的 2x 位图；修改 NSImage.size 不会移除原图的多尺寸表示。
public enum IconThumbnail {
    public static func make(from source: NSImage, pointSize: Int) -> NSImage? {
        guard pointSize > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: pointSize * 2, pixelsHigh: pointSize * 2,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.scaleBy(x: 2, y: 2)
        let size = NSSize(width: pointSize, height: pointSize)
        source.draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        bitmap.size = size
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        image.isTemplate = source.isTemplate
        return image
    }
}
