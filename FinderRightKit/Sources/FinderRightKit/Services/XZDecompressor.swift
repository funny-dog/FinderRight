import Foundation
import Compression

/// .xz 单文件流式解压（进程内，基于系统 Compression 框架的 xz 解码器）。
///
/// macOS 不自带 xz 命令：旧实现会以「完全磁盘访问」身份执行用户可写的 /opt/homebrew/bin/xz，
/// 或调用 /usr/bin/python3——后者在未装开发者工具的机器上会弹出安装对话框。
public enum XZDecompressor {

    /// - Throws: 输入不是合法 .xz、被截断或为空时抛错（Compression 框架报 invalidData）
    public static func decompress(from source: URL, to output: FileHandle, chunkSize: Int = 64 * 1024) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let filter = try OutputFilter(.decompress, using: .lzma) { data in
            if let data { try output.write(contentsOf: data) }
        }
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
            try filter.write(chunk)
        }
        try filter.finalize()
    }
}
