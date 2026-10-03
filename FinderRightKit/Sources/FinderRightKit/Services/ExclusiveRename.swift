import Foundation

/// 以 RENAME_EXCL 原子改名到第一个未被占用的候选名：查重与改名之间不存在覆盖窗口。
/// 压缩产物（ZipCompressor）与解压产物（ExtractedOutput）共用。
enum ExclusiveRename {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// - Parameter name: 第 n 次尝试的文件名（n 从 0 开始）
    static func move(_ source: URL, into directory: URL, name: (Int) -> String) throws -> URL {
        for n in 0..<10_000 {
            let candidate = directory.appendingPathComponent(name(n))
            if renamex_np(source.path, candidate.path, UInt32(RENAME_EXCL)) == 0 {
                return candidate
            }
            let err = errno
            switch err {
            case EEXIST, ENOTEMPTY:
                continue
            case ENOTSUP, EINVAL:
                // 部分文件系统（exFAT、SMB 等）不支持 RENAME_EXCL：退回「查重 + 不覆盖的移动」
                guard !FileManager.default.fileExists(atPath: candidate.path) else { continue }
                do {
                    try FileManager.default.moveItem(at: source, to: candidate)
                    return candidate
                } catch {
                    throw Failure(message: error.localizedDescription)
                }
            default:
                throw Failure(message: String(cString: strerror(err)))
            }
        }
        throw Failure(message: "可用文件名已耗尽")
    }
}
