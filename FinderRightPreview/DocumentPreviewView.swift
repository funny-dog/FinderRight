import AppKit
import FinderRightKit

/// 原生只读文本与表格，不创建 WebKit 子进程，也不解释文档中的 HTML 或外部链接。
/// 同时编译进文件预览扩展与 Markdown 预览扩展，文案从各自扩展的 bundle 查表。
final class DocumentPreviewView: NSScrollView, NSTextViewDelegate {
    let textView = NSTextView()

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        // 只排可见部分：长文档全量排版要数秒到数十秒（实测 300 KB Markdown 8.9 s → 0.4 s）。
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel(NSLocalizedString("File contents", bundle: Bundle(for: DocumentPreviewView.self), comment: ""))
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let storage = view.textStorage, charIndex >= 0, charIndex < storage.length,
              let target = storage.attribute(.toolTip, at: charIndex, effectiveRange: nil) as? String else { return menu }
        let item = NSMenuItem(title: NSLocalizedString("Copy link address", bundle: Bundle(for: Self.self), comment: ""),
                              action: #selector(copyLinkAddress(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target
        menu.insertItem(item, at: 0)
        return menu
    }

    @objc private func copyLinkAddress(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(target, forType: .string)
    }

    func clear() { textView.textStorage?.setAttributedString(NSAttributedString(string: "")) }

    /// 内容可在后台线程生成，主线程只负责替换与滚动到开头。
    func show(_ content: NSAttributedString) {
        textView.textStorage?.setAttributedString(content)
        textView.scrollToBeginningOfDocument(nil)
    }

    static func content(for document: PreviewDocument, language: String? = nil, text: (String) -> String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        func append(_ source: String, font: NSFont = .systemFont(ofSize: 14)) {
            result.append(NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        }
        func note(_ key: String) { append(text(key) + "\n\n") }
        func appendTable(_ table: PreviewDatabaseTable) {
            let grid = NSTextTable()
            grid.numberOfColumns = table.columns.count
            for (row, values) in ([table.columns] + table.rows).enumerated() {
                for (column, value) in values.enumerated() {
                    // Kit 生成的默认列名固定是「列 N」，英文界面换成 Column N
                    var cell = value
                    if row == 0, cell.hasPrefix("列 "), let number = Int(cell.dropFirst(2)) {
                        cell = String(format: text("Column %ld"), number)
                    }
                    result.append(NSAttributedString(string: cell + "\n", attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 13, weight: row == 0 ? .semibold : .regular),
                        .foregroundColor: NSColor.textColor,
                        .paragraphStyle: tableStyle(grid, row: row, column: column)
                    ]))
                }
            }
            if table.rows.isEmpty { note("No records") }
            if table.truncated { note("Item limit reached; showing partial contents") }
            append("\n")
        }
        switch document {
        case .text(let source, let truncated):
            if truncated { note("Large file; showing only the first 1 MB") }
            let lang = SyntaxLanguage.normalize(language)
            if let lang, source.utf8.count <= SyntaxHighlighter.maxHighlightedBytes {
                let highlighted = SyntaxHighlighter.highlight(
                    source: source,
                    language: lang,
                    baseFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    baseColor: .textColor
                )
                result.append(highlighted)
            } else {
                append(source, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
            }
        case .markdown(let source, let frontMatter):
            if let frontMatter {
                result.append(NSAttributedString(string: frontMatter + "\n", attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: codeStyle(NSTextBlock())
                ]))
            }
            result.append(markdown(source))
        case .notebook(let cells, let truncated):
            for cell in cells {
                if cell.kind == "markdown" { result.append(markdown(cell.source)) }
                else { append(cell.source + "\n", font: .monospacedSystemFont(ofSize: 13, weight: .regular)) }
                for output in cell.outputs { append(output + "\n", font: .monospacedSystemFont(ofSize: 13, weight: .regular)) }
                if cell.omittedRichOutput { note("Image and HTML outputs are not shown") }
                append("\n")
            }
            if cells.isEmpty { note("Empty notebook") }
            if truncated { note("Item limit reached; showing partial contents") }
        case .database(let tables, let truncated):
            note("Database file snapshot; uncheckpointed WAL changes are not included")
            if tables.isEmpty { note("No ordinary tables") }
            for table in tables {
                append(table.name + "\n", font: .boldSystemFont(ofSize: 20))
                appendTable(table)
            }
            if truncated { note("Item limit reached; showing partial contents") }
        case .table(let table):
            appendTable(table)
        case .propertyList(let source, let binary, let truncated):
            if binary { note("Binary property list; shown as XML") }
            if truncated { note("Large file; showing only the first 1 MB") }
            append(source, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        }
        return result
    }

    private static func tableStyle(_ table: NSTextTable, row: Int, column: Int,
                                   alignment: NSTextAlignment = .natural) -> NSMutableParagraphStyle {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(.separatorColor)
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        style.alignment = alignment
        return style
    }

    /// 代码块与元信息：整段铺底色，和正文明显区分。
    private static func codeStyle(_ block: NSTextBlock) -> NSMutableParagraphStyle {
        block.backgroundColor = .quaternaryLabelColor
        block.setWidth(10, type: .absoluteValueType, for: .padding)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        return style
    }

    private static let footnoteDefinition = try! NSRegularExpression(
        pattern: #"(?m)^([ \t>]*(?:(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)*\[\^[^\]\r\n]+\])(:)"#)

    private static func markdown(_ source: String) -> NSAttributedString {
        var input = source
        var footnoteMarker: String?
        if source.contains("[^"), footnoteDefinition.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil {
            // 临时隔开脚注标签与冒号，避免系统吞掉定义；显示前去除，代码块原文也会还原。
            var marker = "\u{E000}"
            while source.contains(marker) { marker = "\u{E000}" + UUID().uuidString + "\u{E001}" }
            input = footnoteDefinition.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source),
                                                                 withTemplate: "$1" + marker + "$2")
            footnoteMarker = marker
        }
        guard let value = try? AttributedString(markdown: input) else {
            return NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
        }
        let result = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousAttributes: [NSAttributedString.Key: Any] = [:]
        let bodyFont = NSFont.systemFont(ofSize: 14)
        var tables: [Int: NSTextTable] = [:]
        // 同一代码块或引用的多个片段共用一个文本块，才能画成连续的一整块。
        var blocks: [Int: NSTextBlock] = [:]
        // 自己记录末尾是否为换行：每次读 result.string 都会整段桥接，长文档会退化成平方复杂度。
        var endsWithNewline = true
        for run in value.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let startsBlock = block != previousBlock
            if startsBlock, result.length > 0, !endsWithNewline {
                result.append(NSAttributedString(string: "\n", attributes: previousAttributes))
                endsWithNewline = true
            }
            var font = bodyFont
            var style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
            var row = 0
            var column = 0
            var table: NSTextTable?
            var alignment: NSTextAlignment = .natural
            var prefix = ""
            var listDepth = 0
            var innermostItem: Int?
            var isCodeBlock = false
            var codeLanguageHint: String?
            // components 由内向外排列：第一个 listItem 是当前项，紧随其后的列表决定编号样式。
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header(let level): font = .boldSystemFont(ofSize: CGFloat(max(16, 28 - level * 3)))
                case .codeBlock(let languageHint):
                    isCodeBlock = true
                    codeLanguageHint = languageHint
                    font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                    let codeBlock = blocks[component.identity] ?? NSTextBlock()
                    blocks[component.identity] = codeBlock
                    style = codeStyle(codeBlock)
                case .listItem(let ordinal) where innermostItem == nil:
                    innermostItem = ordinal
                    let ordered = components.dropFirst(index + 1).first.map {
                        if case .orderedList = $0.kind { return true }; return false
                    } ?? false
                    prefix = ordered ? "\(ordinal). " : "• "
                case .orderedList, .unorderedList: listDepth += 1
                case .blockQuote:
                    let quote = blocks[component.identity] ?? NSTextBlock()
                    if blocks[component.identity] == nil {
                        quote.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                        quote.setBorderColor(.separatorColor, for: .minX)
                        quote.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
                        blocks[component.identity] = quote
                    }
                    style.textBlocks = [quote]
                    attributes[.foregroundColor] = NSColor.secondaryLabelColor
                case .tableHeaderRow: font = .boldSystemFont(ofSize: 14)
                case .tableRow(let index): row = index
                case .tableCell(let index): column = index
                case .table(let columns):
                    let grid = tables[component.identity] ?? NSTextTable()
                    grid.numberOfColumns = columns.count
                    tables[component.identity] = grid
                    table = grid
                    switch columns[column].alignment {
                    case .left: alignment = .left
                    case .center: alignment = .center
                    case .right: alignment = .right
                    @unknown default: break
                    }
                case .thematicBreak: attributes[.foregroundColor] = NSColor.separatorColor
                default: break
                }
            }
            if listDepth > 0 {
                style.firstLineHeadIndent = CGFloat(listDepth - 1) * 20
                style.headIndent = style.firstLineHeadIndent + 16
            }
            var text = String(value[run.range].characters)
            if let marker = footnoteMarker, text.contains(marker) { text = text.replacingOccurrences(of: marker, with: "") }
            // GFM 任务列表：解析器把 [ ] / [x] 留在正文开头，换成勾选框符号。
            if startsBlock, innermostItem != nil {
                for (marker, box) in [("[ ] ", "☐ "), ("[x] ", "☑ "), ("[X] ", "☑ ")] where text.hasPrefix(marker) {
                    prefix = box
                    text.removeFirst(marker.count)
                }
            }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) {
                    font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            // 不附带 .link，只提供提示与复制，避免系统自动打开地址。
            if let link = run.link {
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.toolTip] = link.absoluteString
            }
            if run.imageURL != nil {
                attributes[.foregroundColor] = NSColor.secondaryLabelColor
                text = "🖼 " + text
            }
            attributes[.font] = font
            attributes[.paragraphStyle] = table.map { tableStyle($0, row: row, column: column, alignment: alignment) } ?? style
            if startsBlock, !prefix.isEmpty {
                var prefixAttributes = attributes
                prefixAttributes.removeValue(forKey: .backgroundColor)
                prefixAttributes.removeValue(forKey: .strikethroughStyle)
                prefixAttributes.removeValue(forKey: .toolTip)
                result.append(NSAttributedString(string: prefix, attributes: prefixAttributes))
            }
            if isCodeBlock, let hint = codeLanguageHint,
               let lang = SyntaxLanguage.normalize(hint),
               text.utf8.count <= SyntaxHighlighter.maxHighlightedBytes {
                let codeHighlighted = SyntaxHighlighter.highlight(
                    source: text,
                    language: lang,
                    baseFont: font,
                    baseColor: (attributes[.foregroundColor] as? NSColor) ?? .textColor,
                    paragraphStyle: (attributes[.paragraphStyle] as? NSParagraphStyle)
                )
                result.append(codeHighlighted)
            } else {
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
            if let last = text.last ?? prefix.last { endsWithNewline = last.isNewline }
            previousBlock = block
            previousAttributes = attributes
        }
        if result.length > 0, !endsWithNewline {
            result.append(NSAttributedString(string: "\n", attributes: previousAttributes))
        }
        return result
    }
}
