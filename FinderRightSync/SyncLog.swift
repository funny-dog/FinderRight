import Foundation
import FinderRightKit
import os.log

private let log = OSLog(subsystem: "com.finderright.app.sync", category: "FinderSync")

// MARK: - 日志

private let logQueue = DispatchQueue(label: "com.finderright.app.sync.log", qos: .utility)
private let logDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return df
}()

func logToFile(_ message: String) {
    // 1. 系统统一 OSLog（主线程毫秒级开销）
    // private：统一日志里路径等内容默认脱敏，避免留下可被任意进程读取的浏览记录
    os_log("%{private}@", log: log, type: .default, message)

    // 2. 本地调试文件：异步串行派发到后台队列，避免主线程磁盘 I/O 阻塞
    let timestamp = logDateFormatter.string(from: Date())
    logQueue.async {
        let fm = FileManager.default
        // 与 IPC 共用已授权目录，避免容器 Documents 日志被 TCC 阻止读取。
        let logDir = IPCBridge.rootDirectory
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("extension-debug.log")
        let oldLogFile = logDir.appendingPathComponent("extension-debug.log.1")
        let maxBytes: UInt64 = 1024 * 1024 // 1MB

        if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size >= maxBytes {
            try? fm.removeItem(at: oldLogFile)
            try? fm.moveItem(at: logFile, to: oldLogFile)
        }

        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logFile.path) {
            if let h = try? FileHandle(forWritingTo: logFile) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}
