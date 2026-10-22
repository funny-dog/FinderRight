import Foundation
import SQLite3

public struct PreviewDatabaseTable {
    public let name: String
    public let columns: [String]
    public let rows: [[String]]
    public let truncated: Bool
}

/// 仅查询普通实体表；不执行视图、虚拟表、触发器或数据库自带的 SQL。
public enum PreviewDatabase {
    public static func read(_ url: URL) throws -> PreviewDocument {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw PreviewDocumentError.database }
        var connection: OpaquePointer?
        // immutable 避免创建/写入 WAL、SHM；预览只反映主文件中已落盘的数据。
        guard url.isFileURL, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PreviewDocumentError.database
        }
        components.queryItems = [URLQueryItem(name: "mode", value: "ro"), URLQueryItem(name: "immutable", value: "1")]
        guard sqlite3_open_v2(components.string!, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw PreviewDocumentError.database
        }
        defer { sqlite3_close(db) }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
        sqlite3_limit(db, SQLITE_LIMIT_COLUMN, 256)
        sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 65_536)
        sqlite3_busy_timeout(db, 100)
        let deadline = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
        deadline.initialize(to: DispatchTime.now().uptimeNanoseconds + 2_000_000_000)
        defer {
            sqlite3_progress_handler(db, 0, nil, nil)
            deadline.deinitialize(count: 1)
            deadline.deallocate()
        }
        sqlite3_progress_handler(db, 1000, { context in
            guard let context else { return 1 }
            return DispatchTime.now().uptimeNanoseconds > context.assumingMemoryBound(to: UInt64.self).pointee ? 1 : 0
        }, deadline)
        guard sqlite3_exec(db, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON;", nil, nil, nil) == SQLITE_OK else {
            throw PreviewDocumentError.database
        }
        func statement(_ sql: String) throws -> OpaquePointer {
            var result: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else {
                if let result { sqlite3_finalize(result) }
                throw PreviewDocumentError.database
            }
            return result
        }
        // pragma_table_list 区分普通表与 virtual/shadow，不执行 sqlite_schema 中保存的 SQL。
        let schema = try statement("SELECT name FROM pragma_table_list WHERE schema='main' AND type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name LIMIT 21")
        defer { sqlite3_finalize(schema) }
        var names: [String] = []
        var step = sqlite3_step(schema)
        while step == SQLITE_ROW {
            guard let name = sqlite3_column_text(schema, 0) else { throw PreviewDocumentError.database }
            names.append(String(cString: name))
            step = sqlite3_step(schema)
        }
        guard step == SQLITE_DONE else { throw PreviewDocumentError.database }
        var tables: [PreviewDatabaseTable] = []
        var totalBytes = 0
        var totalCells = 0
        for name in names.prefix(20) {
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            let literal = "'" + name.replacingOccurrences(of: "'", with: "''") + "'"
            let info = try statement("SELECT name FROM pragma_table_xinfo(\(literal)) WHERE hidden=0 ORDER BY cid LIMIT 257")
            var fieldNames: [String] = []
            step = sqlite3_step(info)
            while step == SQLITE_ROW {
                if let value = sqlite3_column_text(info, 0) { fieldNames.append(String(cString: value)) }
                step = sqlite3_step(info)
            }
            sqlite3_finalize(info)
            guard step == SQLITE_DONE, !fieldNames.isEmpty, fieldNames.count <= 256 else { throw PreviewDocumentError.database }
            let fields = fieldNames.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
            let query = try statement("SELECT \(fields) FROM main.\(quoted) LIMIT 51")
            defer { sqlite3_finalize(query) }
            let count = sqlite3_column_count(query)
            let columns = (0..<count).map { column -> String in
                let name = String(cString: sqlite3_column_name(query, column))
                return sqlite3_column_decltype(query, column).map { name + " · " + String(cString: $0) } ?? name
            }
            var rows: [[String]] = []
            var limited = false
            step = sqlite3_step(query)
            while step == SQLITE_ROW {
                if rows.count == 50 { limited = true; break }
                var row: [String] = []
                for column in 0..<count {
                    let value: String
                    switch sqlite3_column_type(query, column) {
                    case SQLITE_NULL: value = "NULL"
                    case SQLITE_BLOB: value = "BLOB (\(sqlite3_column_bytes(query, column)) bytes)"
                    default:
                        if let bytes = sqlite3_column_text(query, column) {
                            let size = Int(sqlite3_column_bytes(query, column))
                            value = String(decoding: UnsafeBufferPointer(start: bytes, count: min(size, 512)), as: UTF8.self) + (size > 512 ? "…" : "")
                        } else { throw PreviewDocumentError.database }
                    }
                    row.append(value)
                    totalBytes += value.utf8.count
                }
                rows.append(row)
                totalCells += row.count
                if totalBytes > 1_048_576 || totalCells >= 10_000 { limited = true; break }
                step = sqlite3_step(query)
            }
            guard limited || step == SQLITE_DONE else { throw PreviewDocumentError.database }
            tables.append(PreviewDatabaseTable(name: name, columns: columns, rows: rows, truncated: limited))
            if totalBytes > 1_048_576 || totalCells >= 10_000 { break }
        }
        return .database(tables, truncated: names.count > 20 || totalBytes > 1_048_576 || totalCells >= 10_000)
    }
}
