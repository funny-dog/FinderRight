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

        | 列A | 列B | 列C |
        | :--- | :---: | ---: |
        | 左值 | 中值 | 右值 |

        [本地说明](./docs/install.md)

        另见脚注[^1]与第二条[^2]。

        [^1]: 补充说明

        [^2]: https://example.com/note

        ```markdown
        [^code]: 代码里的定义保持原样
        ```

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
        let codeRange = string.range(of: "let a = 1")
        let codeFont = rendered.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        precondition(codeFont?.isFixedPitch == true, "代码块必须保持等宽字体")
        let letRange = string.range(of: "let")
        let numRange = string.range(of: "1")
        let letColor = rendered.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? NSColor
        let numColor = rendered.attribute(.foregroundColor, at: numRange.location, effectiveRange: nil) as? NSColor
        precondition(letColor == SyntaxTheme.keywordColor, "Markdown 内围栏代码块中的关键字应正确着色")
        precondition(numColor == SyntaxTheme.numberColor, "Markdown 内围栏代码块中的数字应正确着色")

        let unstyledCode = DocumentPreviewView.content(for: .markdown("```\nlet a = 1\n```", frontMatter: nil), text: { $0 })
        let unstyledString = unstyledCode.string as NSString
        let unstyledLetColor = unstyledCode.attribute(.foregroundColor, at: unstyledString.range(of: "let").location, effectiveRange: nil) as? NSColor
        precondition(unstyledLetColor == .textColor, "未标语言的代码块应保持普通文本前景色")

        precondition(style(of: "title: 示例").textBlocks.first?.backgroundColor != nil, "元信息应整段铺底色")
        precondition(style(of: "引用").textBlocks.first?.width(for: .border, edge: .minX) ?? 0 > 0, "引用应有左侧竖线")
        precondition(style(of: "列A").textBlocks.first is NSTextTableBlock, "表格应原生排版")
        for (cell, alignment) in [("列A", NSTextAlignment.left), ("列B", .center), ("列C", .right),
                                   ("左值", .left), ("中值", .center), ("右值", .right)] {
            precondition(style(of: cell).alignment == alignment, "表头与数据行必须保留列对齐方式")
        }
        let linkColor = rendered.attribute(.foregroundColor, at: string.range(of: "链接").location, effectiveRange: nil) as? NSColor
        precondition(linkColor == .linkColor, "链接只做颜色区分")
        let linkIndex = string.range(of: "链接").location
        precondition(rendered.attribute(.toolTip, at: linkIndex, effectiveRange: nil) as? String == "https://example.com")
        precondition(rendered.attribute(.toolTip, at: string.range(of: "本地说明").location, effectiveRange: nil) as? String == "./docs/install.md")
        precondition(string.contains("另见脚注[^1]与第二条[^2]"), "脚注引用应保留标记，不能变成指向正文的假链接")
        precondition(string.contains("[^1]: 补充说明") && string.contains("[^2]: https://example.com/note"), "被系统当作链接定义省略的脚注正文必须补回")
        precondition(rendered.attribute(.toolTip, at: string.range(of: "[^1]").location, effectiveRange: nil) == nil)
        let codeDefinition = "[^code]: 代码里的定义保持原样"
        precondition(string.components(separatedBy: codeDefinition).count == 2, "代码块里的脚注示例不能被补回两次")
        for source in ["正文[^n]\n\n[^n]: 第一行\n    续行\n\n结尾", "正文[^n]\n\n[^n]: first **bold**\n    续行", "正文[^n]\r\n\r\n[^n]: 补充说明"] {
            let preview = DocumentPreviewView.content(for: .markdown(source, frontMatter: nil), text: { $0 }).string
            precondition(preview.contains("[^n]"))
            if source.contains("第一行") {
                precondition((preview as NSString).range(of: "第一行").location < (preview as NSString).range(of: "续行").location,
                             "多行脚注不能丢失首行或打乱顺序")
            } else if source.contains("bold") { precondition(preview.contains("bold") && preview.contains("续行")) }
            else { precondition(preview.contains("补充说明")) }
        }
        for source in ["~~~md\n[^example]: 原文\n~~~", "`跨行代码\n[^example]: 原文\n结束`",
                       "    [^example]: 原文", "> 正文[^example]\n>\n> [^example]: 原文",
                       "- 正文[^example]\n\n  [^example]: 原文", "原字符\u{E000}\n\n[^example]: 原文"] {
            let preview = DocumentPreviewView.content(for: .markdown(source, frontMatter: nil), text: { $0 }).string
            precondition(preview.contains("[^example]: 原文"), "脚注处理不能修改代码、引用或缩进中的文字")
            precondition(preview.components(separatedBy: "\u{E000}").count == (source.contains("\u{E000}") ? 2 : 1),
                         "临时标记不能进入显示内容，也不能删除原有字符")
        }

        let controller = MarkdownPreviewController()
        let document = controller.view.subviews.compactMap { $0 as? DocumentPreviewView }.first!
        prepare(controller, file)
        precondition(document.textView.string.contains("☑ 完成") && !document.textView.isEditable)
        controller.view.layoutSubtreeIfNeeded()
        precondition(document.frame.width > 100 && document.frame.height > 100, "文档区域必须有可见尺寸")
        let status = controller.view.subviews.compactMap { $0 as? NSTextField }.first!
        precondition(status.stringValue.hasPrefix("说明.md"))
        precondition(document.textView.delegate === document)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = document.textView(document.textView, menu: NSMenu(), for: event, at: linkIndex)!
        precondition(menu.items.count == 1 && menu.items[0].representedObject as? String == "https://example.com")
        precondition(menu.items[0].target === document && menu.items[0].action != nil, "复制地址菜单必须绑定当前链接")
        menu.update()
        precondition(menu.items[0].isEnabled)
        for index in [0, -1, document.textView.string.utf16.count] {
            let menu = document.textView(document.textView, menu: NSMenu(), for: event, at: index)!
            precondition(menu.items.isEmpty, "普通文字与范围外的位置不能出现复制链接菜单")
        }
        try Data([0x23, 0, 1]).write(to: file)
        prepare(controller, file)
        precondition(document.textView.string.isEmpty && status.stringValue.contains("Unable to read contents"), "读取失败应清空旧内容并提示原因")
        print("✓ Markdown 预览检查通过（独立声明、基础排版、表格对齐、脚注保全、链接提示与复制菜单、内容隔离、控制器加载与失败提示）")
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
