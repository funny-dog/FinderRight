import AppKit
import FinderRightKit

/// 原生只读文本与表格，不创建 WebKit 子进程，也不解释文档中的 HTML 或外部链接。
final class DocumentPreviewView: NSScrollView {
    let textView = NSTextView()

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel(NSLocalizedString("File contents", bundle: Bundle(for: PreviewController.self), comment: ""))
        documentView = textView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clear() { textView.textStorage?.setAttributedString(NSAttributedString(string: "")) }

    func show(_ document: PreviewDocument, text: (String) -> String) {
        textView.textStorage?.setAttributedString(Self.content(for: document, text: text))
        textView.scrollToBeginningOfDocument(nil)
    }

    static func content(for document: PreviewDocument, text: (String) -> String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        func append(_ source: String, font: NSFont = .systemFont(ofSize: 14)) {
            result.append(NSAttributedString(string: source, attributes: [.font: font, .foregroundColor: NSColor.textColor]))
        }
        func note(_ key: String) { append(text(key) + "\n\n") }
        switch document {
        case .text(let source):
            append(source, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
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
                let grid = NSTextTable()
                grid.numberOfColumns = table.columns.count
                for (row, values) in ([table.columns] + table.rows).enumerated() {
                    for (column, value) in values.enumerated() {
                        result.append(NSAttributedString(string: value + "\n", attributes: [
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
            if truncated { note("Item limit reached; showing partial contents") }
        }
        return result
    }

    private static func tableStyle(_ table: NSTextTable, row: Int, column: Int) -> NSMutableParagraphStyle {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(.separatorColor)
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        let style = NSMutableParagraphStyle()
        style.textBlocks = [block]
        return style
    }

    private static func markdown(_ source: String) -> NSAttributedString {
        guard let value = try? AttributedString(markdown: source) else {
            return NSAttributedString(string: source, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
        }
        let result = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        var previousAttributes: [NSAttributedString.Key: Any] = [:]
        var tables: [Int: NSTextTable] = [:]
        for run in value.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            if block != previousBlock, result.length > 0, !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n", attributes: previousAttributes))
            }
            var font = NSFont.systemFont(ofSize: 14)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.textColor]
            var row = 0
            var column = 0
            var table: NSTextTable?
            var prefix = ""
            for component in components {
                switch component.kind {
                case .header(let level): font = .boldSystemFont(ofSize: CGFloat(max(16, 28 - level * 3)))
                case .codeBlock: font = .monospacedSystemFont(ofSize: 13, weight: .regular)
                case .listItem(let ordinal):
                    prefix = components.contains { if case .orderedList = $0.kind { return true }; return false } ? "\(ordinal). " : "• "
                case .blockQuote: style.headIndent = 16; style.firstLineHeadIndent = 16
                case .tableHeaderRow: font = .boldSystemFont(ofSize: 14)
                case .tableRow(let index): row = index
                case .tableCell(let index): column = index
                case .table(let columns):
                    let grid = tables[component.identity] ?? NSTextTable()
                    grid.numberOfColumns = columns.count
                    tables[component.identity] = grid
                    table = grid
                default: break
                }
            }
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: 13, weight: .regular) }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            }
            attributes[.font] = font
            attributes[.paragraphStyle] = table.map { tableStyle($0, row: row, column: column) } ?? style
            if block != previousBlock { result.append(NSAttributedString(string: prefix, attributes: attributes)) }
            result.append(NSAttributedString(string: String(value[run.range].characters), attributes: attributes))
            previousBlock = block
            previousAttributes = attributes
        }
        if result.length > 0, !result.string.hasSuffix("\n") {
            result.append(NSAttributedString(string: "\n", attributes: previousAttributes))
        }
        return result
    }
}
