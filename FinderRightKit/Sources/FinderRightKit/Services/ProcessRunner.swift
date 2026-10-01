import Foundation

/// 同步执行子进程并收集 stderr 的统一入口。
///
/// 必须**先把 stderr 读到 EOF 再 waitUntilExit**：管道内核缓冲约 64KB，子进程 stderr 写满后会阻塞在
/// write 上等人读，而父进程若先 wait 则在等子进程退出——双方互等，永久死锁。解压 Linux rootfs /
/// Docker 镜像层这类 tar 时，每个设备节点都会打印一行错误，很容易超过 64KB。
///
/// stdout 只接受 FileHandle（默认丢弃到 /dev/null）：若传入 Pipe 而无人读取，会以同样方式死锁。
public enum ProcessRunner {

    /// stderr 只保留尾部这么多字节用于日志，避免异常输出撑爆内存
    public static let defaultStderrTailLimit = 64 * 1024

    public struct Result {
        public let status: Int32
        /// stderr 尾部（已去首尾空白）
        public let stderr: String
    }

    public static func run(executableURL: URL,
                           arguments: [String],
                           currentDirectoryURL: URL? = nil,
                           standardOutput: FileHandle? = nil,
                           stderrTailLimit: Int = defaultStderrTailLimit) throws -> Result {
        let proc = Process()
        proc.executableURL = executableURL
        proc.arguments = arguments
        if let currentDirectoryURL { proc.currentDirectoryURL = currentDirectoryURL }
        proc.standardOutput = standardOutput ?? FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()

        // 边读边丢弃旧数据：availableData 阻塞到有数据，子进程关闭 stderr（退出）时返回空
        let reader = errPipe.fileHandleForReading
        var tail = Data()
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            tail.append(chunk)
            if tail.count > stderrTailLimit {
                tail = Data(tail.suffix(stderrTailLimit))
            }
        }
        proc.waitUntilExit()

        let text = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: proc.terminationStatus, stderr: text)
    }
}
