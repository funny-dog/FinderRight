import AppKit
import FinderRightKit

// 与 FinderRightSync/*.swift 一起编译，并链接 FinderRightKit 后运行；不打开菜单或更改系统外观。
@main
struct MenuIconCheck {
    static func main() throws {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        defer { app.appearance = originalAppearance }

        // 浅 → 深 → 浅也检查缓存不会留下上一种外观的颜色。
        for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
            let appearance = NSAppearance(named: name)!
            app.appearance = appearance
            var expected: NSColor!
            appearance.performAsCurrentDrawingAppearance {
                expected = NSColor.labelColor.usingColorSpace(.sRGB)!
            }

            let image = MenuIconRenderer.image(symbol: "doc.on.clipboard", tint: .graphite, style: .modern)!
            assert(image.isTemplate, "单色图标必须保留模板标记")
            assert(image.size == NSSize(width: 16, height: 16))
            let bitmap = image.representations.first as! NSBitmapImageRep
            assert(bitmap.pixelsWide == 32 && bitmap.pixelsHigh == 32)

            // 即使接收端只取位图，实色笔画也必须与当前文字色一致。
            let transferred = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let colors = (0..<transferred.pixelsHigh).flatMap { y in
                (0..<transferred.pixelsWide).compactMap { x in
                    transferred.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                }
            }
            let ink = colors.max { $0.alphaComponent < $1.alphaComponent }!
            assert(ink.alphaComponent > 0.5, "图标不能是空白")
            assert(colors.contains { $0.alphaComponent == 0 }, "背景必须透明")
            assert(abs(ink.redComponent - expected.redComponent) < 0.03)
            assert(abs(ink.greenComponent - expected.greenComponent) < 0.03)
            assert(abs(ink.blueComponent - expected.blueComponent) < 0.03)

            let archived = try NSKeyedArchiver.archivedData(withRootObject: image, requiringSecureCoding: true)
            let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: NSImage.self, from: archived)!
            assert(restored.isTemplate, "归档后仍应保留模板标记")
            for style in [MenuIconStyle.tinted, .tile] {
                let colored = MenuIconRenderer.image(symbol: "doc.on.clipboard", tint: .blue, style: style)!
                assert(!colored.isTemplate, "彩色图标不应被系统改为单色")
            }
        }
        print("PASS: 单色图标随文字色切换、外观缓存、2x 透明位图、序列化与模板标记、彩色风格隔离")
    }
}
