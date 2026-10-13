import Foundation

/// 把文件 / 文件夹压缩为 zip。
///
/// 默认用系统 bsdtar 生成「发给别人用」的干净 zip：文件名带 UTF-8 标志（ditto 不设，Windows 上中文名会乱码），
/// 不含 `__MACOSX/`、AppleDouble `._*` 与 `.DS_Store`。选中项里有 `.app` 这类包时整体退回 ditto，
/// 保留资源分叉与扩展属性——包里的签名依赖它们。
///
/// 旧实现的三个问题在这里一并解决：
/// 1. 以「目标文件存在」判定成功 —— 压缩工具失败（如遇到不可读文件）也会留下残缺 zip，被当成成功；
/// 2. 多选复制到暂存目录的失败被吞掉 —— 压缩包悄悄少文件；
/// 3. 目标文件名在受理时就算好、稍后才执行 —— 排队中的同名任务互相覆盖。
/// 做法：所有中间产物都放在登记过的 scratch 目录里；压缩工具退出码为 0 才以 RENAME_EXCL 原子改名到
/// 最终位置（已存在则换下一个序号）；任何一步失败都抛错，scratch 由 defer 清理。
public enum ZipCompressor {

    public enum Failure: Error, Equatable {
        case nothingToCompress
        case stagingFailed(String)
        case toolFailed(status: Int32, stderr: String)
        case finalizeFailed(String)
    }

    /// - Parameters:
    ///   - items: 待压缩项；可来自不同目录，但名字不能重复
    ///   - directory: 输出目录。最终文件为 `<baseName>.zip`，重名时依次为 `<baseName> 1.zip`、`<baseName> 2.zip`…
    /// - Returns: 最终 zip 的 URL
    public static func compress(items: [URL],
                                into directory: URL,
                                baseName: String,
                                registry: ScratchDirectoryRegistry = ScratchDirectoryRegistry()) throws -> URL {
        guard !items.isEmpty else { throw Failure.nothingToCompress }

        // Services 多选可能来自不同目录：同名项在 zip 根部会冲突
        if items.count > 1 {
            var seen = Set<String>()
            for item in items where !seen.insert(item.lastPathComponent).inserted {
                throw Failure.stagingFailed("多选项重名: \(item.lastPathComponent)")
            }
        }

        let scratch: URL
        do {
            scratch = try registry.makeScratchDirectory(in: directory)
        } catch {
            throw Failure.stagingFailed("无法创建临时目录: \(error.localizedDescription)")
        }
        defer { registry.remove(scratch) }

        let partial = scratch.appendingPathComponent("archive.zip")
        if containsPackage(items) {
            try compressWithDitto(items, scratch: scratch, output: partial)
        } else if let list = try fileList(for: items) {
            try compressWithBsdtar(list: list, scratch: scratch, output: partial)
        } else {
            // 路径里有换行等清单表达不了的字符：退回 ditto，宁可带元数据也不能漏文件
            try compressWithDitto(items, scratch: scratch, output: partial)
        }
        return try moveIntoPlace(partial, directory: directory, baseName: baseName)
    }

    // MARK: - bsdtar：干净 zip

    /// AppleDouble 文件头魔数（大端 0x00051607）
    private static let appleDoubleMagic: [UInt8] = [0x00, 0x05, 0x16, 0x07]

    /// 只看选中的顶层项：任一是包（.app / .bundle / .framework …）就整体走 ditto
    static func containsPackage(_ items: [URL]) -> Bool {
        items.contains { (try? $0.resourceValues(forKeys: [.isPackageKey]).isPackage) == true }
    }

    /// 生成 bsdtar `-T` 清单：每个选中项前写「-C / 父目录」切换目录，后跟该项及其全部子路径。
    /// 目录也逐条列出，配合 `-n`（不递归）由这里完全决定打包哪些文件。
    /// 清单以换行分隔（加 --null 会让 -C 失效），路径含换行时返回 nil 交给 ditto。
    /// - Throws: 有读不了的子目录时抛 `stagingFailed`：交给 bsdtar `-n` 只会打出一个空目录条目且照样成功
    static func fileList(for items: [URL]) throws -> String? {
        var lines: [String] = []
        for item in items {
            let parent = item.deletingLastPathComponent().path
            let name = item.lastPathComponent
            // 清单里单独一行的「-C」是切换目录指令，名字恰好叫 -C 的项表达不了
            guard name != "-C", !hasLineBreak(parent), !hasLineBreak(name) else { return nil }
            lines += ["-C", parent, name]

            // 只展开真实目录：指向目录的符号链接由 bsdtar 按链接本身打包，不能再列出链接后面的内容
            let itemType = (try? FileManager.default.attributesOfItem(atPath: item.path))?[.type] as? FileAttributeType
            guard itemType == .typeDirectory else { continue }
            guard let descendants = try cleanDescendants(of: item.path) else { return nil }
            lines += descendants.map { name + "/" + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 用 fts 遍历目录，返回应打包的相对路径（排除 .DS_Store、__MACOSX、AppleDouble）。
    ///
    /// 不能用 FileManager：它的 enumerator / contentsOfDirectory 会把所有以 ._ 开头的文件藏起来，
    /// 既没法按魔数识别 AppleDouble，也会让恰好以 ._ 开头的普通文件从压缩包里消失。
    /// - Returns: 路径含换行时返回 nil
    private static func cleanDescendants(of root: String) throws -> [String]? {
        guard let rootCString = strdup(root) else { throw Failure.stagingFailed("内存不足") }
        defer { free(rootCString) }
        var roots: [UnsafeMutablePointer<CChar>?] = [rootCString, nil]
        // FTS_PHYSICAL：不跟随符号链接；FTS_NOCHDIR：fts_path 始终是完整路径
        guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            throw Failure.stagingFailed("无法遍历 \(root)")
        }
        defer { fts_close(fts) }

        var result: [String] = []
        while let entry = fts_read(fts) {
            let level = entry.pointee.fts_level
            let info = Int32(entry.pointee.fts_info)
            let path = String(cString: entry.pointee.fts_path)
            switch info {
            case FTS_DP:
                continue    // 目录的后序访问，前序已处理
            case FTS_DNR, FTS_ERR, FTS_NS:
                throw Failure.stagingFailed("无法读取: \(path)")
            default:
                break
            }
            guard level > 0 else { continue }    // 根目录本身已由调用方写入清单

            let fileName = (path as NSString).lastPathComponent
            if fileName == ".DS_Store" { continue }
            if fileName == "__MACOSX" && info == FTS_D {
                fts_set(fts, entry, FTS_SKIP)
                continue
            }
            if fileName.hasPrefix("._") && info == FTS_F && isAppleDouble(URL(fileURLWithPath: path)) { continue }

            let relative = String(path.dropFirst(root.count + 1))
            guard !hasLineBreak(relative) else { return nil }
            result.append(relative)
        }
        return result
    }

    private static func hasLineBreak(_ s: String) -> Bool {
        s.contains { $0.isNewline }
    }

    /// 按魔数识别 AppleDouble；只看文件名会误伤恰好以 ._ 开头的普通文件
    static func isAppleDouble(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)).map { [UInt8]($0) == appleDoubleMagic } ?? false
    }

    private static func compressWithBsdtar(list: String, scratch: URL, output: URL) throws {
        let listURL = scratch.appendingPathComponent("filelist.txt")
        do {
            try Data(list.utf8).write(to: listURL)
        } catch {
            throw Failure.stagingFailed("无法写入文件清单: \(error.localizedDescription)")
        }
        try runTool("/usr/bin/tar", ["--format", "zip",
                                     "--options", "zip:hdrcharset=UTF-8",
                                     "--no-mac-metadata",
                                     "-n", "-T", listURL.path,
                                     "-cf", output.path])
    }

    // MARK: - ditto：保留 Mac 元数据

    private static func compressWithDitto(_ items: [URL], scratch: URL, output: URL) throws {
        let fm = FileManager.default
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

        var arguments = ["-c", "-k", "--sequesterRsrc"]
        if keepParent { arguments.append("--keepParent") }
        arguments += [source.path, output.path]
        try runTool("/usr/bin/ditto", arguments)
    }

    // MARK: - 公共

    private static func runTool(_ executable: String, _ arguments: [String]) throws {
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: executable), arguments: arguments)
        } catch {
            throw Failure.toolFailed(status: -1, stderr: error.localizedDescription)
        }
        guard result.status == 0 else {
            throw Failure.toolFailed(status: result.status, stderr: result.stderr)
        }
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
