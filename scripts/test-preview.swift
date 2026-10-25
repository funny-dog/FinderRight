import AppKit
import FinderRightKit
import UniformTypeIdentifiers

/// 不开窗口：检查目录、压缩包与文档预览，以及异步切换和布局。
@main
struct PreviewChecks {
    static func main() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let plistData = try Data(contentsOf: repository.appendingPathComponent("FinderRightPreview/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as! [String: Any]
        let ext = plist["NSExtension"] as! [String: Any]
        let attributes = ext["NSExtensionAttributes"] as! [String: Any]
        let types = attributes["QLSupportedContentTypes"] as! [String]
        precondition(!types.contains("public.text") && !types.contains("public.json") && !types.contains("net.daringfireball.markdown"))
        // 点文件与无扩展名文件的具体类型就是 public.data / public.unix-executable，Quick Look 按具体类型分发。
        precondition(types.contains("public.data") && types.contains("public.unix-executable"))
        let imported = plist["UTImportedTypeDeclarations"] as! [[String: Any]]
        for type in imported { precondition(types.contains(type["UTTypeIdentifier"] as! String)) }
        let appPlistData = try Data(contentsOf: repository.appendingPathComponent("FinderRight/Info.plist"))
        let appPlist = try PropertyListSerialization.propertyList(from: appPlistData, format: nil) as! [String: Any]
        let appImported = (appPlist["UTImportedTypeDeclarations"] as! [[String: Any]]).map { $0["UTTypeIdentifier"] as! String }
        precondition(Set(appImported) == Set(imported.map { $0["UTTypeIdentifier"] as! String }), "主 App 与预览扩展的导入类型必须一致")
        // 动态 UTI 的扩展名必须有导入声明，否则 Quick Look 收不到；系统已有类型的直接列在支持类型里。
        let declaredExtensions = Set(imported.flatMap { (($0["UTTypeTagSpecification"] as! [String: Any])["public.filename-extension"] as! [String]) })
        let systemTyped: [String: String] = ["css": "public.css", "ndjson": "public.ndjson", "vtt": "org.w3.webvtt"]
        for ext in PreviewDocument.sniffedTextExtensions.subtracting(declaredExtensions) {
            precondition(systemTyped[ext].map(types.contains) == true, "扩展名 \(ext) 缺少类型声明")
        }
        for ext in ["deb", "rpm", "whl"] { precondition(declaredExtensions.contains(ext)) }
        // 系统按扩展名查类型时只认继承 public.data 的声明；public.archive 本身不继承它，单写会退回动态 UTI。
        for type in imported {
            let parents = type["UTTypeConformsTo"] as! [String]
            precondition(parents.contains { $0 == "public.data" || UTType($0)?.conforms(to: .data) == true },
                         "\(type["UTTypeIdentifier"]!) 必须继承 public.data")
        }
        for type in ["public.bzip2-archive", "public.tar-bzip2-archive", "public.iso-image", "com.apple.installer-package-archive",
                     "public.archive.apk", "com.apple.itunes.ipa", "com.sun.java-archive", "com.sun.web-application-archive"] {
            precondition(types.contains(type), "缺少压缩包类型 \(type)")
        }
        // 自定义类型名称会显示在访达「种类」列，中文系统需要译名。
        for bundle in ["FinderRight", "FinderRightPreview"] {
            let strings = NSDictionary(contentsOf: repository.appendingPathComponent("\(bundle)/zh-Hans.lproj/InfoPlist.strings")) as! [String: String]
            for type in imported {
                let description = type["UTTypeDescription"] as! String
                precondition(["YAML", "TOML", "Jupyter Notebook"].contains(description) || strings[description] != nil,
                             "\(bundle) 缺少类型名称「\(description)」的中文")
            }
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finderright-preview-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("目录/子目录"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("hello".utf8).write(to: root.appendingPathComponent("目录/子目录/中文.txt"))
        try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("longer text".utf8).write(to: root.appendingPathComponent("z.txt"))
        let zip = root.appendingPathComponent("example.zip")
        let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
                                           arguments: ["-q", zip.path, "目录/子目录/中文.txt"], currentDirectoryURL: root)
        precondition(result.status == 0, result.stderr)
        let listing = try PreviewContents.zip(zip)
        let tree = try PreviewNode.archiveTree(listing.entries)
        precondition(tree.count == 1 && tree[0].name == "目录")
        precondition(tree[0].children.count == 1 && tree[0].children[0].name == "子目录")
        precondition(tree[0].children[0].children[0].name == "中文.txt")
        precondition(!tree[0].children[0].children[0].isDirectory)
        let controller = PreviewController()
        precondition(NSClassFromString("FinderRightPreview.PreviewController") != nil)
        let outline = findOutline(controller.view)!
        precondition(outline.tableColumns.count == 4)
        prepare(controller, root)
        precondition(outline.numberOfRows == 4)
        outline.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        precondition((outline.item(atRow: 0) as? PreviewNode)?.isDirectory == true)
        precondition((outline.item(atRow: 2) as? PreviewNode)?.name == "z.txt")
        precondition((outline.item(atRow: 3) as? PreviewNode)?.name == "a.txt")
        let directory = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? PreviewNode }
            .first { $0.name == "目录" }!
        precondition(!directory.loaded)
        outline.expandItem(directory)
        wait { directory.loaded }
        precondition(directory.children.count == 1 && directory.children[0].name == "子目录")
        prepare(controller, zip)
        precondition(outline.numberOfRows == 1)
        let archiveDirectory = outline.item(atRow: 0) as! PreviewNode
        outline.expandItem(archiveDirectory)
        precondition(outline.numberOfRows == 2)
        precondition(archiveDirectory.children[0].loaded)
        var cancelled = false
        var newestFinished = false
        controller.preparePreviewOfFile(at: root) { error in
            precondition((error as? CocoaError)?.code == .userCancelled)
            cancelled = true
        }
        controller.preparePreviewOfFile(at: zip) { error in
            precondition(error == nil)
            newestFinished = true
        }
        wait { cancelled && newestFinished }
        precondition(outline.numberOfRows == 1)
        let bad = root.appendingPathComponent("bad.zip")
        try Data("broken".utf8).write(to: bad)
        prepare(controller, bad)
        precondition(outline.numberOfRows == 0)
        let many = root.appendingPathComponent("many", isDirectory: true)
        try FileManager.default.createDirectory(at: many, withIntermediateDirectories: true)
        for index in 0..<30 { try Data().write(to: many.appendingPathComponent("file-\(index).sh")) }
        prepare(controller, many)
        let scroll = outline.enclosingScrollView!
        for width in [760.0, 640.0, 960.0, 320.0] {
            controller.view.setFrameSize(NSSize(width: width, height: 500))
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            // 无窗口测试显式派发布局回调，避免依赖不同系统的控制器生命周期。
            controller.viewDidLayout()
            if width >= 640 {
                precondition(outline.frame.width <= scroll.contentView.bounds.width + 1, "宽度 \(width) 不应出现横向溢出")
                precondition(outline.rect(ofColumn: 3).maxX <= scroll.contentView.bounds.width + 1, "宽度 \(width) 的最后一列应在可视范围内")
            }
            precondition(outline.rect(ofColumn: 3).maxX <= outline.frame.width + 1, "窄窗口中的最后一列必须可通过横向滚动访问")
        }
        let footer = controller.view.subviews.compactMap { $0 as? NSStackView }.first!
        precondition(controller.view.bounds.contains(footer.frame), "状态栏必须在预览边界内")
        precondition(footer.frame.maxY < scroll.frame.minY, "状态栏不能与内容区重叠")
        let config = root.appendingPathComponent("sample.toml")
        try Data("name = \"中文\"\n".utf8).write(to: config)
        prepare(controller, config)
        let document = controller.view.subviews.compactMap { $0 as? DocumentPreviewView }.first!
        precondition(!document.isHidden && scroll.isHidden)
        precondition(!document.textView.isEditable && document.textView.isSelectable)
        precondition(document.textView.string.contains("中文"))
        controller.view.layoutSubtreeIfNeeded()
        document.tile()
        precondition(document.frame.width > 100 && document.frame.height > 100)
        precondition(document.textView.frame.width > 100, "文本视图必须具有可见宽度")
        document.textView.layoutManager?.ensureLayout(for: document.textView.textContainer!)
        precondition(document.textView.layoutManager!.numberOfGlyphs > 0)
        precondition(document.textView.frame.height > 20 && document.textView.visibleRect.height > 20,
                     "文本内容不能位于零高度的文档视图中")
        let literal = DocumentPreviewView.content(for: .text("<script>bad()</script>"), text: { $0 })
        precondition(literal.string == "<script>bad()</script>")
        precondition(literal.attribute(.attachment, at: 0, effectiveRange: nil) == nil)
        let notebook = root.appendingPathComponent("sample.ipynb")
        let content: [String: Any] = ["nbformat": 4, "cells": [
            ["cell_type": "markdown", "source": "# 标题\n\n**加粗**\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n![remote](https://example.com/image.png)\n\n<script>bad()</script>"],
            ["cell_type": "code", "source": "print(1)", "outputs": [["text": "1\n"]]]
        ]]
        try JSONSerialization.data(withJSONObject: content).write(to: notebook)
        prepare(controller, notebook)
        precondition(!document.isHidden && outline.numberOfRows == 0)
        let rendered = document.textView.attributedString()
        precondition(rendered.string.contains("标题") && rendered.string.contains("加粗"))
        let boldRange = (rendered.string as NSString).range(of: "加粗")
        let boldFont = rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as! NSFont
        precondition(NSFontManager.shared.traits(of: boldFont).contains(.boldFontMask))
        let cellRange = (rendered.string as NSString).range(of: "A")
        let tableStyle = rendered.attribute(.paragraphStyle, at: cellRange.location, effectiveRange: nil) as! NSParagraphStyle
        precondition(tableStyle.textBlocks.first is NSTextTableBlock)
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            precondition(attributes[.link] == nil && attributes[.attachment] == nil)
        }
        precondition(rendered.string.contains("print(1)"))
        let database = root.appendingPathComponent("sample.sqlite")
        let databaseResult = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: [database.path, "CREATE TABLE products (name TEXT); INSERT INTO products VALUES ('苹果');"])
        precondition(databaseResult.status == 0, databaseResult.stderr)
        prepare(controller, database)
        precondition(!document.isHidden && document.textView.string.contains("苹果"))
        precondition(document.textView.string.contains("name · TEXT"))
        document.textView.layoutManager?.ensureLayout(for: document.textView.textContainer!)
        let tableBounds = document.textView.layoutManager!.usedRect(for: document.textView.textContainer!)
        precondition(tableBounds.width > 0 && tableBounds.height > 0, "SQLite 表格必须完成原生排版")
        cancelled = false
        newestFinished = false
        controller.preparePreviewOfFile(at: notebook) { error in
            precondition(Thread.isMainThread)
            precondition((error as? CocoaError)?.code == .userCancelled)
            cancelled = true
        }
        controller.preparePreviewOfFile(at: database) { error in
            precondition(Thread.isMainThread && error == nil)
            newestFinished = true
        }
        wait { cancelled && newestFinished }
        precondition(document.textView.string.contains("苹果") && !document.textView.string.contains("print(1)"),
                     "快速切换文档后，旧的后台富文本结果不能覆盖新预览")
        prepare(controller, zip)
        precondition(document.isHidden && !scroll.isHidden && outline.numberOfRows == 1)
        let tar = root.appendingPathComponent("sample.tar")
        let tarResult = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                              arguments: ["-cf", tar.path, "-C", root.path, "a.txt"])
        precondition(tarResult.status == 0, tarResult.stderr)
        prepare(controller, tar)
        precondition(document.isHidden && outline.numberOfRows == 1)
        precondition((outline.item(atRow: 0) as? PreviewNode)?.name == "a.txt")
        for ext in ["apk", "ipa", "whl", "jar", "war"] {
            let package = root.appendingPathComponent("package.\(ext)")
            try? FileManager.default.removeItem(at: package)
            try FileManager.default.copyItem(at: zip, to: package)
            prepare(controller, package)
            precondition(document.isHidden && (outline.item(atRow: 0) as? PreviewNode)?.name == "目录", "\(ext) 应按 ZIP 列出内容")
        }
        prepare(controller, config)
        try Data([0, 1]).write(to: config)
        prepare(controller, config)
        precondition(document.isHidden && !scroll.isHidden, "文档失败不能留下上一个文档的预览")
        let dotfile = root.appendingPathComponent(".gitignore")
        try Data("build/\n*.log\n".utf8).write(to: dotfile)
        prepare(controller, dotfile)
        precondition(!document.isHidden && document.textView.string.contains("*.log"))
        let binary = root.appendingPathComponent(".DS_Store")
        try Data([0, 0, 0, 1, 0x42, 0x75, 0x64, 0x31]).write(to: binary)
        var fellBack = false
        controller.preparePreviewOfFile(at: binary) { error in
            precondition(error != nil, "非文本的嗅探文件必须交回系统默认预览")
            fellBack = true
        }
        wait { fellBack }
        precondition(document.isHidden, "交回系统预览时不能残留上一个文档")
        print("✓ Quick Look 集成检查通过（目录/压缩包加载、排序、展开、文档切换、静态内容隔离与布局）")
    }

    private static func findOutline(_ view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.compactMap(findOutline).first
    }

    private static func prepare(_ controller: PreviewController, _ url: URL) {
        var finished = false
        controller.preparePreviewOfFile(at: url) { error in
            precondition(Thread.isMainThread, "预览完成回调必须在主线程执行")
            precondition(error == nil, String(describing: error))
            finished = true
        }
        wait { finished }
    }

    private static func wait(_ completed: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !completed() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(completed(), "预览异步操作超时")
    }
}
