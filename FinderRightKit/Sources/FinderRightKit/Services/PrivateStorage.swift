import Foundation

/// 私有存储权限收紧：目录 0700、文件 0600。
/// 配置、剪切队列与调试日志都含用户路径，默认 0755/0644 会让同机其他用户读到。
public enum PrivateStorage {
    /// 创建目录（含中间层）并把目标目录收紧为 0700；已存在的目录同样收紧。
    /// 只改目标目录本身，不动 Application Support 等共享中间层。
    public static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            let error = error as NSError
            NSLog("[PrivateStorage] 无法收紧目录权限（%@:%ld）", error.domain, error.code)
        }
    }

    /// 文件存在时收紧为 0600；不存在则不做任何事。
    public static func restrictFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            let error = error as NSError
            NSLog("[PrivateStorage] 无法收紧文件权限（%@:%ld）", error.domain, error.code)
        }
    }

    /// 以 0600 权限向日志文件追加一行（超出 maxBytes 时轮转为 `.1`）。调用方负责在后台串行队列调用。
    public static func appendLogLine(_ line: String, to fileURL: URL, maxBytes: UInt64 = 1024 * 1024) {
        let fm = FileManager.default
        try? ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64, size >= maxBytes {
            let rotated = URL(fileURLWithPath: fileURL.path + ".1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
        restrictFile(fileURL)
    }
}