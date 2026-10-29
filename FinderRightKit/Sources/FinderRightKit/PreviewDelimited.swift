import Foundation

/// CSV / TSV 表格解析：纯 Swift 逐字符扫描，按 RFC 4180 处理引号与换行。
public enum PreviewDelimited {
    public static let csvExtensions: Set<String> = ["csv"]
    public static let tsvExtensions: Set<String> = ["tsv"]
    public static let maxRows = 500        // 不含表头的数据行
    public static let maxColumns = 50
    public static let maxCells = 10_000
    public static let maxCellCharacters = 300

    /// 纯函数：把整段文本解析为表格，便于单测。
    public static func parse(_ text: String, delimiter: Character) -> PreviewDatabaseTable {
        var source = text
        // Excel 导出的「CSV UTF-8」带 BOM，不去掉第一列表头会多一个看不见的字符。
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        var iterator = source.makeIterator()
        var lookahead = iterator.next()
        func advance() -> Character? {
            defer { lookahead = iterator.next() }
            return lookahead
        }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var fieldCharacters = 0
        var fieldHasContent = false
        var fieldTruncated = false
        var column = 0
        var width = 0
        var rowCount = 0
        var inQuotes = false

        func append(_ char: Character) {
            fieldHasContent = true
            guard rowCount <= maxRows, column < maxColumns, !fieldTruncated else { return }
            field.append(char.isNewline ? " " : char)
            fieldCharacters += 1
            if fieldCharacters > maxCellCharacters {
                // 仅在边界重数：换行清洗后组合字符可能合并，逐字符 count 会反复扫描长字段。
                fieldCharacters = field.count
                if fieldCharacters > maxCellCharacters {
                    field = String(field.prefix(maxCellCharacters - 1)) + "…"
                    fieldTruncated = true
                }
            }
        }
        func finishField() {
            if rowCount <= maxRows, column < maxColumns { row.append(field) }
            column += 1
            field = ""
            fieldCharacters = 0
            fieldHasContent = false
            fieldTruncated = false
        }
        func finishRow() {
            finishField()
            width = max(width, column)
            if rowCount <= maxRows { rows.append(row) }
            rowCount += 1
            row = []
            column = 0
        }
        // 超出展示范围仍扫描引号和列数，但不再保存字段；末尾的宽行也会影响展示列数。
        while let char = advance() {
            if inQuotes {
                if char == "\"" {
                    if lookahead == "\"" {
                        append("\"")
                        _ = advance()
                    } else {
                        inQuotes = false
                    }
                } else {
                    append(char)
                }
            } else if char == "\"", !fieldHasContent {
                inQuotes = true
            } else if char == delimiter {
                finishField()
            } else if char.isNewline {
                // 与末尾收尾同一条规则：只有行内有内容才算一条记录，空行跳过
                if column > 0 || fieldHasContent { finishRow() }
            } else {
                append(char)
            }
        }
        // 末尾没有换行、或引号未闭合时，把已读到的内容作为最后一行收尾
        if column > 0 || fieldHasContent { finishRow() }
        guard width > 0 else {
            return PreviewDatabaseTable(name: "", columns: [], rows: [], truncated: false)
        }
        let columnCount = min(width, maxColumns)
        var truncated = width > maxColumns || rowCount > rows.count
        let columns = fit(rows[0], to: columnCount).enumerated().map { index, name in
            name.isEmpty ? "列 \(index + 1)" : name
        }
        var kept: [[String]] = []
        for fields in rows.dropFirst() {
            if kept.count >= maxRows || (kept.count + 1) * columnCount > maxCells {
                truncated = true
                break
            }
            kept.append(fit(fields, to: columnCount))
        }
        return PreviewDatabaseTable(name: "", columns: columns, rows: kept, truncated: truncated)
    }

    /// 按内容猜分隔符：只用于 .csv；`sep=` 是 Excel 的提示行，解析时需跳过。
    public static func detectDelimiter(_ text: String) -> (delimiter: Character, skipFirstLine: Bool) {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let first = source.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first
        if let first, first.hasPrefix("sep="), first.count == 5, let delimiter = first.last {
            return (delimiter, true)
        }
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        if let line = source.split(maxSplits: 1, whereSeparator: \.isNewline).first {
            var inQuotes = false
            for char in line {
                if char == "\"" { inQuotes.toggle() }
                else if !inQuotes, counts[char] != nil { counts[char]! += 1 }
            }
        }
        var delimiter: Character = ","
        var highest = 0
        let candidates: [Character] = [",", ";", "\t"]
        for candidate in candidates where counts[candidate]! > highest {
            highest = counts[candidate]!
            delimiter = candidate
        }
        return (delimiter, false)
    }

    public static func read(_ url: URL) throws -> PreviewDocument {
        // GB18030 兜底：国内 Excel 默认导出的 CSV 是 GBK 编码，UTF-8 严格解码会失败
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let (text, truncated) = try PreviewDocument.readTextPrefix(url, fallbackEncoding: gb18030)
        var body = text
        let delimiter: Character
        if url.pathExtension.lowercased() == "tsv" {
            delimiter = "\t"
        } else {
            let detected = detectDelimiter(text)
            delimiter = detected.delimiter
            if detected.skipFirstLine, let newline = body.firstIndex(where: \.isNewline) {
                body = String(body[body.index(after: newline)...])
            }
        }
        let table = parse(body, delimiter: delimiter)
        return .table(PreviewDatabaseTable(name: table.name, columns: table.columns, rows: table.rows,
                                           truncated: table.truncated || truncated))
    }

    /// 不足的行在末尾补空字段，超出列数的部分丢弃，使每行长度一致。
    private static func fit(_ fields: [String], to count: Int) -> [String] {
        var fitted = Array(fields.prefix(count))
        fitted.append(contentsOf: repeatElement("", count: count - fitted.count))
        return fitted
    }
}
