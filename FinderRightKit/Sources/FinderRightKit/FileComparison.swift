import Foundation

public enum FileComparisonError: LocalizedError, Equatable {
    case notText, tooLarge, tooManyLines, comparisonFailed

    public var errorDescription: String? {
        switch self {
        case .notText: return NSLocalizedString("请选择 UTF-8 或带 BOM 的 UTF-16 文本文件", comment: "file comparison")
        case .tooLarge: return NSLocalizedString("文件超过 1 MiB，暂不支持比较", comment: "file comparison")
        case .tooManyLines: return NSLocalizedString("文件超过 20,000 行，暂不支持比较", comment: "file comparison")
        case .comparisonFailed: return NSLocalizedString("无法生成文件差异", comment: "file comparison")
        }
    }
}

public struct ComparisonDocument: Equatable {
    public let url: URL
    public let text: String
    public let lines: [String]
    public let hasFinalNewline: Bool
    public let lineEndings: String
    public static let maxBytes = 1024 * 1024

    public static func read(_ url: URL) throws -> ComparisonDocument {
        guard url.isFileURL,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw FileComparisonError.notText
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maxBytes {
            let chunk = try handle.read(upToCount: maxBytes + 1 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maxBytes else { throw FileComparisonError.tooLarge }
        guard case .success(var decoded) = FileContentReader.decodeText(data) else { throw FileComparisonError.notText }
        if decoded.first == "\u{FEFF}" { decoded.removeFirst() }
        let text = decoded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let finalNewline = text.hasSuffix("\n")
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        if finalNewline { lines.removeLast() }
        guard lines.count <= 20_000 else { throw FileComparisonError.tooManyLines }
        return ComparisonDocument(url: url, text: text, lines: lines, hasFinalNewline: finalNewline,
                                  lineEndings: decoded.unicodeScalars.filter { $0 == "\r" || $0 == "\n" }.map { String($0) }.joined())
    }
}

public struct FileDiffRow: Equatable, Identifiable {
    public enum Kind: Equatable { case unchanged, changed }
    public let id: Int
    public let leftNumber: Int?
    public let left: String?
    public let rightNumber: Int?
    public let right: String?
    public let kind: Kind
}

public struct FileComparisonResult: Equatable {
    public let rows: [FileDiffRow]
    public let additions: Int
    public let deletions: Int
    public let differentLineEndings: Bool

    public static func compare(_ left: ComparisonDocument, _ right: ComparisonDocument) throws -> FileComparisonResult {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("FinderRight-diff-\(UUID().uuidString)")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let leftFile = directory.appendingPathComponent("left")
        let rightFile = directory.appendingPathComponent("right")
        let output = directory.appendingPathComponent("diff")
        try left.text.write(to: leftFile, atomically: true, encoding: .utf8)
        try right.text.write(to: rightFile, atomically: true, encoding: .utf8)
        guard fm.createFile(atPath: output.path, contents: nil) else { throw FileComparisonError.comparisonFailed }
        let handle = try FileHandle(forWritingTo: output)
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/diff"),
                                           arguments: ["-a", "--normal", leftFile.path, rightFile.path], standardOutput: handle)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard result.status == 0 || result.status == 1 else { throw FileComparisonError.comparisonFailed }
        let patch = try String(contentsOf: output, encoding: .utf8)
        return try alignedRows(left: left, right: right, patch: patch)
    }

    private static func alignedRows(left: ComparisonDocument, right: ComparisonDocument, patch: String) throws -> FileComparisonResult {
        let header = try NSRegularExpression(pattern: #"^(\d+)(?:,(\d+))?([acd])(\d+)(?:,(\d+))?$"#)
        var rows: [FileDiffRow] = []
        var li = 0, ri = 0, additions = 0, deletions = 0

        func appendEqual(until leftEnd: Int, _ rightEnd: Int) throws {
            guard leftEnd >= li, rightEnd >= ri, leftEnd <= left.lines.count, rightEnd <= right.lines.count,
                  leftEnd - li == rightEnd - ri else { throw FileComparisonError.comparisonFailed }
            while li < leftEnd {
                guard left.lines[li] == right.lines[ri] else { throw FileComparisonError.comparisonFailed }
                rows.append(FileDiffRow(id: rows.count, leftNumber: li + 1, left: left.lines[li],
                                       rightNumber: ri + 1, right: right.lines[ri], kind: .unchanged))
                li += 1
                ri += 1
            }
        }

        for line in patch.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let match = header.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            func number(_ group: Int) -> Int? {
                let range = match.range(at: group)
                return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
            }
            guard let a = number(1), let b = number(4) else { throw FileComparisonError.comparisonFailed }
            let operation = ns.substring(with: match.range(at: 3))
            let leftStart = operation == "a" ? a : a - 1
            let leftEnd = operation == "a" ? a : number(2) ?? a
            let rightStart = operation == "d" ? b : b - 1
            let rightEnd = operation == "d" ? b : number(5) ?? b
            try appendEqual(until: leftStart, rightStart)
            guard leftEnd >= leftStart, leftEnd <= left.lines.count,
                  rightEnd >= rightStart, rightEnd <= right.lines.count else { throw FileComparisonError.comparisonFailed }
            let oldCount = leftEnd - leftStart, newCount = rightEnd - rightStart
            deletions += oldCount
            additions += newCount
            for offset in 0..<max(oldCount, newCount) {
                let l = offset < oldCount ? leftStart + offset : nil
                let r = offset < newCount ? rightStart + offset : nil
                rows.append(FileDiffRow(id: rows.count, leftNumber: l.map { $0 + 1 }, left: l.map { left.lines[$0] },
                                       rightNumber: r.map { $0 + 1 }, right: r.map { right.lines[$0] }, kind: .changed))
            }
            li = leftEnd
            ri = rightEnd
        }
        try appendEqual(until: left.lines.count, right.lines.count)
        return FileComparisonResult(rows: rows, additions: additions, deletions: deletions,
                                    differentLineEndings: left.lineEndings != right.lineEndings)
    }
}
