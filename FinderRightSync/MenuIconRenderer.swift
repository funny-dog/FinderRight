import Cocoa
import FinderRightKit

// MARK: - 菜单图标


/// 菜单图标渲染：预渲染为 2x 位图并按「风格 + 符号 + 颜色 + 明暗」缓存。
///
/// 菜单要跨进程交给 Finder 绘制，图片在构建菜单时就得定型 —— 不能依赖延迟绘制或动态颜色，
/// 所以按当前系统明暗各画一份。代价是悬停高亮时彩色线条不会反白（模板图才会）。
enum MenuIconRenderer {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()
    private static let side: CGFloat = 16

    static func image(symbol: String, tint: MenuTint, style: MenuIconStyle) -> NSImage? {
        let appearance = NSApplication.shared.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "\(style.rawValue)|\(symbol)|\(tint.name)|\(dark ? "dark" : "light")"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var rendered: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            rendered = render(symbol: symbol, tint: tint, style: style, dark: dark)
        }
        guard let image = rendered else { return nil }
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }

    private static func render(symbol: String, tint: MenuTint, style: MenuIconStyle, dark: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)

        let glyphColor: NSColor
        let box: NSRect
        let config: NSImage.SymbolConfiguration
        let asTile = style == .tile
        if asTile {
            srgb(dark ? tint.tile.dark : tint.tile.light).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 4, yRadius: 4).fill()
            glyphColor = tint.darkGlyph ? srgb(0x2B2200) : .white
            box = NSRect(x: 2, y: 2, width: 12, height: 12)
            config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        } else {
            glyphColor = style == .modern ? .labelColor : srgb(dark ? tint.line.dark : tint.line.light)
            box = NSRect(x: 0, y: 0, width: side, height: side)
            config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        }
        if asTile, let letter = tileLetter(for: symbol) {
            // 方块本身就是框：字母类符号（p.square 等）去掉外框，直接画字母，避免框套框
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: glyphColor,
            ]
            let size = (letter as NSString).size(withAttributes: attrs)
            (letter as NSString).draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
        } else {
            let source = asTile ? tileSymbol(for: symbol).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } ?? base : base
            let glyph = source.withSymbolConfiguration(config.applying(.init(paletteColors: [glyphColor]))) ?? source
            glyph.draw(in: fitted(glyph.size, in: box))
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: side, height: side)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        // Finder 跨进程绘制时保留当前文字色，同时保留模板标记供菜单处理高亮。
        image.isTemplate = style == .modern
        return image
    }

    /// 单字母方框符号（如 p.square）在方块风格下改画的字母
    private static func tileLetter(for symbol: String) -> String? {
        guard symbol.hasSuffix(".square") else { return nil }
        let inner = symbol.dropLast(".square".count)
        return inner.count == 1 ? inner.uppercased() : nil
    }

    /// 自带外框的符号在方块风格下换成无框版本（如 dollarsign.square → dollarsign）
    private static func tileSymbol(for symbol: String) -> String? {
        switch symbol {
        case "dollarsign.square": return "dollarsign"
        case "play.rectangle": return "play.fill"
        default: return nil
        }
    }

    /// 等比缩小并居中，宽符号（如 </>）不会被拉伸或溢出
    private static func fitted(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(1, box.width / size.width, box.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
