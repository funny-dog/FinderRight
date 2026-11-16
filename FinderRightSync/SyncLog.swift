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
        // 文件日志不像统一日志那样自动脱敏，落盘前自行压掉用户路径
        let line = "[\(timestamp)] \(LogRedaction.redactPaths(message))\n"
        let logFile = IPCBridge.rootDirectory.appendingPathComponent("extension-debug.log")
        PrivateStorage.appendLogLine(line, to: logFile)
    }
}
