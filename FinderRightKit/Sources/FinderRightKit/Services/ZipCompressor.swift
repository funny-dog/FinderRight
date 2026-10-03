import Foundation

/// 把文件 / 文件夹压缩为 zip（基于系统 ditto，保留 macOS 元数据）。
///
/// 旧实现的三个问题在这里一并解决：
/// 1. 以「目标文件存在」判定成功 —— ditto 失败（如遇到不可读文件）也会留下残缺 zip，被当成成功；
/// 2. 多选复制到暂存目录的失败被吞掉 —— 压缩包悄悄少文件；
/// 3. 目标文件名在受理时就算好、稍后才执行 —— 排队中的同名任务互相覆盖。
/// 做法：所有中间产物都放在登记过的 scratch 目录里；ditto 退出码为 0 才以 RENAME_EXCL 原子改名到
/// 最终位置（已存在则换下一个序号）；任何一步失败都抛错，scratch 由 defer 清理。
public enum ZipCompressor {

    public enum Failure: Error, Equatable {
        case nothingToCompress
        case stagingFailed(String)
        case dittoFailed(status: Int32, stderr: String)
        case finalizeFailed(String)
    }

    /// - Parameters:
    ///   - items: 待压缩项；只有一项时可以是文件或文件夹
    ///   - directory: 输出目录。最终文件为 `<baseName>.zip`，重名时依次为 `<baseName> 1.zip`、`<baseName> 2.zip`…
    /// - Returns: 最终 zip 的 URL
    public static func compress(items: [URL],
                                into directory: URL,
                                baseName: String,
                                registry: ScratchDirectoryRegistry = ScratchDirectoryRegistry()) throws -> URL {
        guard !items.isEmpty else { throw Failure.nothingToCompress }
        let fm = FileManager.default

        let scratch: URL
        do {
            scratch = try registry.makeScratchDirectory(in: directory)
        } catch {
            throw Failure.stagingFailed("无法创建临时目录: \(error.localizedDescription)")
        }
        defer { registry.remove(scratch) }

        let source: URL
        var keepParent = false
        if items.count == 1 {
            source = items[0]
            var isDir: ObjCBool = false
            keepParent = fm.fileExists(atPath: source.path, isDirectory: &isDir) && isDir.boolValue
        } else {
            // ditto -c 只接受一个源：把多选项放进同卷的暂存目录（APFS 上 cp -c 为零开销克隆）
            let stage = scratch.appendingPathComponent("stage", isDirectory: true)
            do {
                try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            } catch {
                throw Failure.stagingFailed("无法创建暂存目录: \(error.localizedDescription)")
            }
            for item in items {
                let target = stage.appendingPathComponent(item.lastPathComponent)
                // Services 多选可能来自不同目录：同名项放进同一暂存目录会嵌套或冲突
                guard !fm.fileExists(atPath: target.path) else {
                    throw Failure.stagingFailed("多选项重名: \(item.lastPathComponent)")
                }
                let clone = try? ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/cp"),
                                                   arguments: ["-cR", item.path, target.path])
                if clone?.status != 0 {
                    // 非 APFS 卷不支持克隆：清掉 cp 可能留下的半份，退回普通复制；仍失败就整体中止
                    try? fm.removeItem(at: target)
                    do {
                        try fm.copyItem(at: item, to: target)
                    } catch {
                        throw Failure.stagingFailed("\(item.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            source = stage
        }

        let partial = scratch.appendingPathComponent("archive.zip")
        var arguments = ["-c", "-k", "--sequesterRsrc"]
        if keepParent { arguments.append("--keepParent") }
        arguments += [source.path, partial.path]
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: arguments)
        } catch {
            throw Failure.dittoFailed(status: -1, stderr: error.localizedDescription)
        }
        guard result.status == 0 else {
            throw Failure.dittoFailed(status: result.status, stderr: result.stderr)
        }
        return try moveIntoPlace(partial, directory: directory, baseName: baseName)
    }

    /// 原子改名到第一个未被占用的 `<baseName>.zip` / `<baseName> N.zip`
    static func moveIntoPlace(_ partial: URL, directory: URL, baseName: String) throws -> URL {
        do {
            return try ExclusiveRename.move(partial, into: directory) { n in
                n == 0 ? "\(baseName).zip" : "\(baseName) \(n).zip"
            }
        } catch let failure as ExclusiveRename.Failure {
            throw Failure.finalizeFailed(failure.message)
        }
    }
}
