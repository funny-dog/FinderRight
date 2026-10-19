import AppKit
import FinderRightKit

/// 不开窗口：检查 ZIP 虚拟目录，以及预览控制器的异步加载和目录展开。
@main
struct PreviewChecks {
    static func main() throws {
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
        print("✓ Quick Look 集成检查通过（目录加载、排序、展开、切换、异常包、列宽与底部布局）")
    }

    private static func findOutline(_ view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        return view.subviews.compactMap(findOutline).first
    }

    private static func prepare(_ controller: PreviewController, _ url: URL) {
        var finished = false
        controller.preparePreviewOfFile(at: url) { error in
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
