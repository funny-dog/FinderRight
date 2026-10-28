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
        var inQuotes = false
        while let char = advance() {
            if inQuotes {
                if char == "\"" {
                    if lookahead == "\"" {
                        field.append("\"")
                        _ = advance()
                    } else {
                        inQuotes = false
                    }
                } else {
                    // 引号内的换行属于字段内容，显示前再清洗成空格
                    field.append(char)
                }
            } else if char == "\"", field.isEmpty {
                inQuotes = true
            } else if char == delimiter {
                row.append(field)
                field = ""
            } else if char.isNewline {
                // 与末尾收尾同一条规则：只有行内有内容才算一条记录，空行跳过
                if !row.isEmpty || !field.isEmpty {
                    row.append(field)
                    field = ""
                    rows.append(row)
                    row = []
                }
            } else {
                field.append(char)
            }
        }
        // 末尾没有换行、或引号未闭合时，把已读到的内容作为最后一行收尾
        if !row.isEmpty || !field.isEmpty {
            row.append(field)
            rows.append(row)
        }
        guard let width = rows.map(\.count).max(), width > 0 else {
            return PreviewDatabaseTable(name: "", columns: [], rows: [], truncated: false)
        }
        let columnCount = min(width, maxColumns)
        var truncated = width > maxColumns
        let columns = fit(rows[0], to: columnCount).enumerated().map { index, name in
            name.isEmpty ? "列 \(index + 1)" : clean(name)
        }
        var kept: [[String]] = []
        for fields in rows.dropFirst() {
            if kept.count >= maxRows || (kept.count + 1) * columnCount > maxCells {
                truncated = true
                break
            }
            kept.append(fit(fields, to: columnCount).map(clean(_:)))
        }
        return PreviewDatabaseTable(name: "", columns: columns, rows: kept, truncated: truncated)
    }

    /// 按内容猜分隔符：只用于 .csv；`sep=` 是 Excel 的提示行，解析时需跳过。
    public static func detectDelimiter(_ text: String) -> (delimiter: Character, skipFirstLine: Bool) {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if let first = lines.first, first.hasPrefix("sep="), first.count == 5, let delimiter = first.last {
            return (delimiter, true)
        }
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        if let line = lines.first(where: { !$0.isEmpty }) {
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

    /// 单元格清洗：换行会打乱以换行结尾的表格渲染，超长时截断并加省略号。
    private static func clean(_ field: String) -> String {
        var value = String(field.map { $0.isNewline ? " " : $0 })
        if value.count > maxCellCharacters {
            value = String(value.prefix(maxCellCharacters - 1)) + "…"
        }
        return value
    }
}
