import AppKit
import FinderRightKit

/// 不开窗口：检查 Markdown 预览扩展的声明、渲染内容隔离与控制器加载。
@main
struct MarkdownPreviewChecks {
    static func main() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func plist(_ path: String) throws -> [String: Any] {
            let data = try Data(contentsOf: repository.appendingPathComponent(path))
            return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        }
        let info = try plist("FinderRightMarkdown/Info.plist")
        let preview = try plist("FinderRightPreview/Info.plist")
        precondition(info["CFBundleIdentifier"] as? String == "com.finderright.app.markdown")
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            precondition(info[key] as? String == preview[key] as? String, "Markdown 扩展的 \(key) 必须与其他 bundle 一致")
        }
        let ext = info["NSExtension"] as! [String: Any]
        precondition(ext["NSExtensionPrincipalClass"] as? String == "$(PRODUCT_MODULE_NAME).MarkdownPreviewController")
        let types = Set((ext["NSExtensionAttributes"] as! [String: Any])["QLSupportedContentTypes"] as! [String])
        precondition(types.contains("net.daringfireball.markdown"))
        // 只接 Markdown：纯文本由系统处理，避免关掉开关后影响其他文本文件。
        precondition(!types.contains("public.plain-text") && !types.contains("public.text"))
        let previewTypes = Set(((preview["NSExtension"] as! [String: Any])["NSExtensionAttributes"] as! [String: Any])["QLSupportedContentTypes"] as! [String])
        precondition(types.isDisjoint(with: previewTypes), "Markdown 类型只能由独立扩展声明，开关才能单独生效")
        precondition(NSClassFromString("FinderRightMarkdown.MarkdownPreviewController") != nil)

        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finderright-markdown-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("说明.md")
        try Data("""
        ---
        title: 示例
        ---
        # 标题
        正文含 **粗体**、`代码` 与 [链接](https://example.com)。

        - [ ] 待办
        - [x] 完成
        - 外层
          - 内层

        > 引用

        ```swift
        let a = 1
        ```

        | 列A | 列B |
        | --- | --- |
        | 1 | 2 |

        ![示意图](https://example.com/a.png)
        <script>bad()</script>
        """.utf8).write(to: file)

        let rendered = DocumentPreviewView.content(for: try PreviewDocument.readMarkdown(file), text: { $0 })
        let string = rendered.string as NSString
        precondition(string.hasPrefix("title: 示例\n"), "开头元信息应以原文显示")
        precondition(!string.contains("---"), "元信息分隔行不应出现在正文")
        precondition(string.contains("☐ 待办") && string.contains("☑ 完成") && !string.contains("[x]"), "任务列表应换成勾选框")
        precondition(string.contains("🖼 示意图") && string.contains("<script>bad()</script>"), "图片只显示替代文字，HTML 按原文显示")
        rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, _, _ in
            precondition(attributes[.link] == nil && attributes[.attachment] == nil, "预览不能包含可点击链接或附件")
        }
        func style(of text: String) -> NSParagraphStyle {
            rendered.attribute(.paragraphStyle, at: string.range(of: text).location, effectiveRange: nil) as! NSParagraphStyle
        }
        precondition(style(of: "内层").firstLineHeadIndent > style(of: "外层").firstLineHeadIndent, "嵌套列表应逐级缩进")
        precondition(style(of: "let a = 1").textBlocks.first?.backgroundColor != nil, "代码块应整段铺底色")
        precondition(style(of: "title: 示例").textBlocks.first?.backgroundColor != nil, "元信息应整段铺底色")
        precondition(style(of: "引用").textBlocks.first?.width(for: .border, edge: .minX) ?? 0 > 0, "引用应有左侧竖线")
        precondition(style(of: "列A").textBlocks.first is NSTextTableBlock, "表格应原生排版")
        let linkColor = rendered.attribute(.foregroundColor, at: string.range(of: "链接").location, effectiveRange: nil) as? NSColor
        precondition(linkColor == .linkColor, "链接只做颜色区分")

        let controller = MarkdownPreviewController()
        let document = controller.view.subviews.compactMap { $0 as? DocumentPreviewView }.first!
        prepare(controller, file)
        precondition(document.textView.string.contains("☑ 完成") && !document.textView.isEditable)
        controller.view.layoutSubtreeIfNeeded()
        precondition(document.frame.width > 100 && document.frame.height > 100, "文档区域必须有可见尺寸")
        let status = controller.view.subviews.compactMap { $0 as? NSTextField }.first!
        precondition(status.stringValue.hasPrefix("说明.md"))
        try Data([0x23, 0, 1]).write(to: file)
        prepare(controller, file)
        precondition(document.textView.string.isEmpty && status.stringValue.contains("Unable to read contents"), "读取失败应清空旧内容并提示原因")
        print("✓ Markdown 预览检查通过（独立声明、元信息、任务列表、嵌套缩进、代码块与引用、链接与图片隔离、控制器加载与失败提示）")
    }

    private static func prepare(_ controller: MarkdownPreviewController, _ url: URL) {
        var finished = false
        controller.preparePreviewOfFile(at: url) { error in
            precondition(error == nil, String(describing: error))
            finished = true
        }
        let deadline = Date().addingTimeInterval(10)
        while !finished && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(finished, "预览异步操作超时")
    }
}
