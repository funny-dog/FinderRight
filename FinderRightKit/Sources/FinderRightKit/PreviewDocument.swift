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

    public static let textExtensions: Set<String> = ["yaml", "yml", "toml", "ini"]
    public static let databaseExtensions: Set<String> = ["sqlite", "sqlite3"]

    public static func supports(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return textExtensions.contains(ext) || databaseExtensions.contains(ext) || ext == "ipynb"
    }

    public static func read(_ url: URL) throws -> PreviewDocument {
        let ext = url.pathExtension.lowercased()
        if databaseExtensions.contains(ext) {
            return try PreviewDatabase.read(url)
        }
        if textExtensions.contains(ext) {
            let data = try boundedData(url, limit: 1_048_576)
            let encoding: String.Encoding = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) ? .utf16 : .utf8
            guard let text = String(data: data, encoding: encoding), !text.contains("\0") else {
                throw PreviewDocumentError.invalid
            }
            return .text(text)
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
