import Foundation

/// 用系统 bsdtar 带密码解压加密 zip（ditto 解不了 AES，ZipCrypto 也没有密码回调）。
///
/// 密码经 `--passphrase` 参数传入：解压期间同一用户的进程可从 ps 看到，这是有意接受的取舍——
/// 换来的是不可信压缩包的解析留在子进程里，不碰持有完全磁盘访问的主 App。
/// 调用方不得把参数或密码写进日志。
public enum EncryptedZipExtractor {

    public enum Outcome: Equatable {
        case extracted
        /// 密码错误：输出目录已清空，可让用户重输后再调一次
        case wrongPassword
        case failed(status: Int32, stderr: String)
    }

    /// - Parameters:
    ///   - output: 已存在的空目录（通常是 scratch 下的 out）
    ///   - legacyNames: 包里有未声明编码的非 UTF-8 文件名（见 `ZipProbe`）时按 CP936 解码，
    ///     否则 bsdtar 报 Illegal byte sequence
    /// - Throws: 无法启动 bsdtar，或清空输出目录失败
    public static func extract(_ archive: URL, into output: URL, password: String, legacyNames: Bool) throws -> Outcome {
        var arguments = ["-xf", archive.path, "-C", output.path, "--passphrase", password]
        if legacyNames { arguments += ["--options", "hdrcharset=CP936"] }
        let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                           arguments: arguments,
                                           currentDirectoryURL: output)
        if result.status == 0 { return .extracted }

        // bsdtar 失败时已经建好了空壳文件：清掉，重试从空目录开始，放弃时也不会被当成产物
        try emptyDirectory(output)
        return indicatesWrongPassword(result.stderr) ? .wrongPassword : .failed(status: result.status, stderr: result.stderr)
    }

    /// stderr 是否表明密码错误。ZipCrypto 只有 1 字节校验、AES 只有 2 字节校验，少数错误密码会通过头部校验，
    /// 解到数据末尾才以 CRC / 认证码不符失败，这两种也按密码错误处理
    public static func indicatesWrongPassword(_ stderr: String) -> Bool {
        ["Incorrect passphrase", "bad CRC", "bad Authentication code"].contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    private static func emptyDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        // 用 POSIX 列目录：FileManager 会把 ._ 开头的文件藏起来，清不干净
        guard let names = try? DirectoryEntries.names(in: directory) else { return }
        for name in names {
            try fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
