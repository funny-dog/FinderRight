import Foundation
import SQLite3
import FinderRightKit

@main
struct PreviewDocumentChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finderright-documents-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for ext in ["yaml", "yml", "toml", "ini"] {
            let file = root.appendingPathComponent("中文.\(ext)")
            let source = "name = 中文\nenabled = true\n"
            try Data(source.utf8).write(to: file)
            precondition(PreviewDocument.supports(file))
            guard case .text(let actual) = try PreviewDocument.read(file) else { preconditionFailure() }
            precondition(actual == source)
        }
        let text = root.appendingPathComponent("utf16.ini")
        try "中文 = 内容".data(using: .utf16)!.write(to: text)
        guard case .text(let decoded) = try PreviewDocument.read(text) else { preconditionFailure() }
        precondition(decoded == "中文 = 内容")
        try Data([0, 1, 2]).write(to: text)
        expectFailure { _ = try PreviewDocument.read(text) }
        try Data(repeating: 65, count: 1_048_577).write(to: text)
        expectFailure { _ = try PreviewDocument.read(text) }
        let notebook = root.appendingPathComponent("sample.ipynb")
        let sample: [String: Any] = ["nbformat": 4, "cells": [
            ["cell_type": "markdown", "source": ["# 标题\n", "\n**加粗**"]],
            ["cell_type": "code", "source": "print(1)", "outputs": [
                ["output_type": "stream", "text": ["1\n"]],
                ["output_type": "display_data", "data": ["text/plain": "中文输出"]],
                ["output_type": "display_data", "data": ["text/html": "<script>bad()</script>"]]
            ]]
        ]]
        try JSONSerialization.data(withJSONObject: sample).write(to: notebook)
        guard case .notebook(let cells, let truncated) = try PreviewDocument.read(notebook) else { preconditionFailure() }
        precondition(!truncated && cells.count == 2 && cells[0].source.contains("标题"))
        precondition(cells[1].outputs == ["1\n", "中文输出"] && cells[1].omittedRichOutput)
        var many = sample
        many["cells"] = Array(repeating: ["cell_type": "raw", "source": "x"], count: 201)
        try JSONSerialization.data(withJSONObject: many).write(to: notebook)
        guard case .notebook(let limited, let reachedLimit) = try PreviewDocument.read(notebook) else { preconditionFailure() }
        precondition(limited.count == 200 && reachedLimit)
        try Data("{\"nbformat\":4,\"cells\":[{\"cell_type\":\"code\"}]}".utf8).write(to: notebook)
        expectFailure { _ = try PreviewDocument.read(notebook) }
        try Data("not json".utf8).write(to: notebook)
        expectFailure { _ = try PreviewDocument.read(notebook) }

        let database = root.appendingPathComponent("sample.sqlite")
        var connection: OpaquePointer?
        precondition(sqlite3_open(database.path, &connection) == SQLITE_OK)
        let db = connection!
        defer { sqlite3_close(db) }
        func sql(_ source: String) {
            let result = sqlite3_exec(db, source, nil, nil, nil)
            precondition(result == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        }
        sql("CREATE TABLE products (id INTEGER, name TEXT, payload BLOB, optional TEXT, doubled AS (id*2)); INSERT INTO products (id,name,payload) VALUES (1,'苹果',X'1234'); CREATE TABLE \"quote'\"\"table\" (value TEXT); CREATE VIEW ignored_view AS SELECT * FROM products;")
        let original = try Data(contentsOf: database)
        guard case .database(let tables, let databaseLimit) = try PreviewDocument.read(database) else { preconditionFailure() }
        precondition(!databaseLimit && tables.count == 2)
        let products = tables.first { $0.name == "products" }!
        precondition(products.columns.count == 4 && products.columns[1] == "name · TEXT")
        precondition(products.rows == [["1", "苹果", "BLOB (2 bytes)", "NULL"]])
        let after = try Data(contentsOf: database)
        precondition(after == original)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(names.allSatisfy { !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") })
        sql("WITH RECURSIVE n(x) AS (VALUES(2) UNION ALL SELECT x+1 FROM n WHERE x<60) INSERT INTO products(id,name) SELECT x,'测试' FROM n")
        guard case .database(let moreTables, _) = try PreviewDocument.read(database) else { preconditionFailure() }
        let moreProducts = moreTables.first { $0.name == "products" }!
        precondition(moreProducts.rows.count == 50 && moreProducts.truncated)
        let missing = root.appendingPathComponent("missing.sqlite")
        expectFailure { _ = try PreviewDocument.read(missing) }
        precondition(!FileManager.default.fileExists(atPath: missing.path))
        let broken = root.appendingPathComponent("broken.sqlite")
        try Data("not sqlite".utf8).write(to: broken)
        expectFailure { _ = try PreviewDocument.read(broken) }
        let link = root.appendingPathComponent("link.sqlite")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: database)
        expectFailure { _ = try PreviewDocument.read(link) }
        print("✓ 文档预览检查通过（配置编码与上限、Notebook 单元与输出、SQLite 普通表/只读/截断/损坏文件）")
    }

    private static func expectFailure(_ block: () throws -> Void) {
        do { try block(); preconditionFailure("应拒绝该输入") } catch { }
    }
}
