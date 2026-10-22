import Foundation

public enum PreviewDocumentError: String, LocalizedError {
    case invalid = "Invalid or unsupported preview document"
    case tooLarge = "The file is too large to preview"
    case database = "Unable to read the SQLite database"
    public var errorDescription: String? { rawValue }
}

public struct PreviewNotebookCell {
    public let kind: String
    public let source: String
    public let outputs: [String]
    public let omittedRichOutput: Bool
}

public enum PreviewDocument {
    case text(String)
    case notebook([PreviewNotebookCell], truncated: Bool)
    case database([PreviewDatabaseTable], truncated: Bool)
    /// frontMatter 为文件开头 `---` 包围的 YAML 元信息，单独以等宽原文显示，不参与 Markdown 解析。
    case markdown(String, frontMatter: String?)

    public static let textExtensions: Set<String> = ["yaml", "yml", "toml", "ini"]
    public static let databaseExtensions: Set<String> = ["sqlite", "sqlite3"]
    /// 系统不认识（动态 UTI）或认识但没有预览器的文本格式；扩展名不保证内容是文本，按内容判断。
    public static let sniffedTextExtensions: Set<String> = [
        // 配置
        "conf", "config", "cfg", "cnf", "properties", "env",
        // 源码（系统已认识的语言由系统文本预览处理）
        "cjs", "tsx", "jsx", "vue", "svelte", "css", "scss", "sass", "less",
        "lua", "fish", "cs", "kt", "kts", "go", "rs", "dart", "scala", "groovy", "gradle",
        "jl", "ex", "exs", "erl", "hs", "clj", "elm", "zig", "nim",
        "sql", "graphql", "gql", "proto", "tf", "hcl", "nix", "cmake",
        // 结构化文本
        "jsonl", "ndjson", "jsonc", "json5", "lock",
        // 字幕与标记文档
        "srt", "vtt", "ass", "rst", "adoc", "tex", "bib", "org"
    ]

    public static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return textExtensions.contains(ext) || databaseExtensions.contains(ext) || ext == "ipynb" || sniffsText(url)
    }

    /// 点文件与无扩展名文件（系统标为 public.data / public.unix-executable）及常见配置扩展名，
    /// 需按内容判断是否为文本；读取失败时应交回系统默认预览，而不是显示错误。
    public static func sniffsText(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || sniffedTextExtensions.contains(ext)
    }

    public static func read(_ url: URL) throws -> PreviewDocument {
        let ext = url.pathExtension.lowercased()
        if databaseExtensions.contains(ext) {
            return try PreviewDatabase.read(url)
        }
        if textExtensions.contains(ext) || sniffsText(url) {
            return .text(try decodeText(boundedData(url, limit: 1_048_576)))
        }
        guard ext == "ipynb" else { throw PreviewDocumentError.invalid }
        let data = try boundedData(url, limit: 5 * 1_048_576)
        guard let notebook = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = notebook["nbformat"] as? Int, version == 4,
              let rawCells = notebook["cells"] as? [[String: Any]] else {
            throw PreviewDocumentError.invalid
        }
        var cells: [PreviewNotebookCell] = []
        var truncated = rawCells.count > 200
        for raw in rawCells.prefix(200) {
            guard let kind = raw["cell_type"] as? String, ["markdown", "code", "raw"].contains(kind),
                  let source = notebookText(raw["source"]) else { throw PreviewDocumentError.invalid }
            var outputs: [String] = []
            var omitted = false
            if kind == "code", let rawOutputs = raw["outputs"] as? [[String: Any]] {
                truncated = truncated || rawOutputs.count > 100
                for output in rawOutputs.prefix(100) {
                    if let text = notebookText(output["text"]) { outputs.append(text) }
                    else if let data = output["data"] as? [String: Any] {
                        if let text = notebookText(data["text/plain"]) { outputs.append(text) }
                        else { omitted = true }
                    } else if let traceback = output["traceback"] as? [String] {
                        outputs.append(traceback.joined(separator: "\n"))
                    }
                }
            }
            cells.append(PreviewNotebookCell(kind: kind, source: source, outputs: outputs, omittedRichOutput: omitted))
        }
        return .notebook(cells, truncated: truncated)
    }

    /// 供独立的 Markdown 预览扩展使用；上限与纯文本一致，1 MiB 文档解析排版约需 1 秒。
    public static func readMarkdown(_ url: URL) throws -> PreviewDocument {
        var text = try decodeText(boundedData(url, limit: 1_048_576))
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        // Swift 把 \r\n 视为一个字符，按任意换行切分才能兼容 Windows 换行；拼回时统一为 \n。
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        func isFence(_ line: Substring, _ marks: Set<String>) -> Bool {
            marks.contains(line.trimmingCharacters(in: .whitespaces))
        }
        // 只认第一行就是 --- 且后面有闭合行的情况；否则开头的 --- 是普通分隔线。
        if let first = lines.first, isFence(first, ["---"]),
           let end = lines.dropFirst().firstIndex(where: { isFence($0, ["---", "..."]) }) {
            let frontMatter = lines[1..<end].joined(separator: "\n")
            return .markdown(lines[(end + 1)...].joined(separator: "\n"), frontMatter: frontMatter)
        }
        return .markdown(text, frontMatter: nil)
    }

    private static func decodeText(_ data: Data) throws -> String {
        let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
        guard let text = String(data: data, encoding: encoding), !text.contains("\0") else {
            throw PreviewDocumentError.invalid
        }
        return text
    }

    private static func notebookText(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let lines = value as? [String] { return lines.joined() }
        return nil
    }

    private static func boundedData(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PreviewDocumentError.invalid }
        guard (values.fileSize ?? 0) <= limit else { throw PreviewDocumentError.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw PreviewDocumentError.tooLarge }
        return data
    }
}
