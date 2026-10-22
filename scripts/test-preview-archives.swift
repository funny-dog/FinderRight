import Foundation
import FinderRightKit

@main
struct TestPreviewArchives {
    static func main() throws {
        print("=== 开始测试 PreviewArchive ===")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("finderright-archive-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try testStandardFormats(in: tempDir)
        try testPackageFormats(in: tempDir)
        try testRar5Fixture(in: tempDir)
        try testDotSlashHandling(in: tempDir)
        try testTruncation(in: tempDir)
        try testPathSecurityAttacks(in: tempDir)
        try testDamagedAndInvalidArchives(in: tempDir)
        try testResourceLimits(in: tempDir)

        print("\n🎉 所有 PreviewArchive 针对性测试全部通过！")
    }

    // MARK: - 1. 标准格式（TAR / TAR.GZ / TAR.XZ / 7z）
    private static func testStandardFormats(in tempDir: URL) throws {
        print("\n--- 1. 测试 TAR / TAR.GZ / TAR.XZ / 7z 基础元数据与过滤 ---")
        let workDir = tempDir.appendingPathComponent("standard-work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir.appendingPathComponent("目录/子目录"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workDir.appendingPathComponent("目录/__MACOSX"), withIntermediateDirectories: true)

        let chineseContent = "你好，世界！这是中文内容。"
        let chineseFile = workDir.appendingPathComponent("目录/子目录/中文.txt")
        try Data(chineseContent.utf8).write(to: chineseFile)

        let regularFile = workDir.appendingPathComponent("a.txt")
        try Data("simple file".utf8).write(to: regularFile)

        // 创建符号链接
        let symlinkFile = workDir.appendingPathComponent("link_to_a.txt")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: URL(fileURLWithPath: "a.txt"))

        // 创建杂项文件
        try Data("clutter".utf8).write(to: workDir.appendingPathComponent(".DS_Store"))
        try Data("clutter".utf8).write(to: workDir.appendingPathComponent("目录/.DS_Store"))
        try Data("clutter".utf8).write(to: workDir.appendingPathComponent("目录/__MACOSX/junk.txt"))
        try Data("clutter".utf8).write(to: workDir.appendingPathComponent("目录/._resource_fork"))

        let tarURL = tempDir.appendingPathComponent("test.tar")
        let targzURL = tempDir.appendingPathComponent("test.tar.gz")
        let tarxzURL = tempDir.appendingPathComponent("test.tar.xz")
        let sevenZipURL = tempDir.appendingPathComponent("test.7z")

        // 构造 tar
        let r1 = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                      arguments: ["-cf", tarURL.path, "."],
                                      currentDirectoryURL: workDir)
        precondition(r1.status == 0, "tar 构造失败: \(r1.stderr)")

        // 构造 tar.gz
        let r2 = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                      arguments: ["-czf", targzURL.path, "."],
                                      currentDirectoryURL: workDir)
        precondition(r2.status == 0, "tar.gz 构造失败: \(r2.stderr)")

        // 构造 tar.xz
        let r3 = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                      arguments: ["-cJf", tarxzURL.path, "."],
                                      currentDirectoryURL: workDir)
        precondition(r3.status == 0, "tar.xz 构造失败: \(r3.stderr)")

        // 构造 7z
        let r4 = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                      arguments: ["--format", "7zip", "-cf", sevenZipURL.path, "."],
                                      currentDirectoryURL: workDir)
        precondition(r4.status == 0, "7z 构造失败: \(r4.stderr)")

        // 构造 tar.bz2
        let tarbz2URL = tempDir.appendingPathComponent("test.tar.bz2")
        let r5 = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                      arguments: ["-cjf", tarbz2URL.path, "."],
                                      currentDirectoryURL: workDir)
        precondition(r5.status == 0, "tar.bz2 构造失败: \(r5.stderr)")

        for (formatName, url) in [("TAR", tarURL), ("TAR.GZ", targzURL), ("TAR.XZ", tarxzURL), ("TAR.BZ2", tarbz2URL), ("7z", sevenZipURL)] {
            let listing = try PreviewArchive.read(url)
            precondition(!listing.truncated, "\(formatName) 不应截断")

            // 验证不包含杂项
            for clutter in [".DS_Store", "__MACOSX", "._resource_fork"] {
                precondition(!listing.entries.contains { $0.path.contains(clutter) },
                             "\(formatName) 泄漏了杂项: \(clutter)")
            }

            // 验证中文文件
            guard let chineseEntry = listing.entries.first(where: { $0.path == "目录/子目录/中文.txt" }) else {
                fatalError("\(formatName) 缺少中文文件条目，实际列表: \(listing.entries.map(\.path))")
            }
            precondition(!chineseEntry.isDirectory, "\(formatName) 中文文件不应是目录")
            precondition(!chineseEntry.isSymbolicLink, "\(formatName) 中文文件不应是符号链接")
            precondition(chineseEntry.size == Int64(chineseContent.utf8.count), "\(formatName) 中文文件尺寸不匹配")
            precondition(chineseEntry.modificationDate != nil, "\(formatName) 应包含修改时间")

            // 验证普通文件
            guard let aEntry = listing.entries.first(where: { $0.path == "a.txt" }) else {
                fatalError("\(formatName) 缺少 a.txt")
            }
            precondition(!aEntry.isDirectory && !aEntry.isSymbolicLink)
            precondition(aEntry.size == 11)

            // 验证符号链接（不跟随、保留标识）
            guard let linkEntry = listing.entries.first(where: { $0.path == "link_to_a.txt" }) else {
                fatalError("\(formatName) 缺少 link_to_a.txt")
            }
            precondition(linkEntry.isSymbolicLink, "\(formatName) link_to_a.txt 必须标记为符号链接")
            precondition(!linkEntry.isDirectory, "\(formatName) link_to_a.txt 不应是目录")

            print("  ✓ \(formatName) 解析成功（中文层级、大小、时间、符号链接与杂项过滤）")
        }
    }

    // MARK: - 1b. 软件包与光盘镜像（deb / rpm / iso / pkg）
    private static func testPackageFormats(in tempDir: URL) throws {
        print("\n--- 1b. 测试 deb / rpm / iso / pkg 顶层成员 ---")
        let workDir = tempDir.appendingPathComponent("package-work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir.appendingPathComponent("目录"), withIntermediateDirectories: true)
        try Data("你好".utf8).write(to: workDir.appendingPathComponent("目录/中文.txt"))
        func run(_ tool: String, _ arguments: [String]) throws {
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: tool), arguments: arguments,
                                               currentDirectoryURL: workDir)
            precondition(result.status == 0, "\(tool) 构造失败: \(result.stderr)")
        }
        func paths(_ url: URL) throws -> Set<String> { Set(try PreviewArchive.read(url).entries.map(\.path)) }

        // deb 是 GNU ar：按格式手写，避免依赖 dpkg；系统 ar 会额外写入符号表。
        let tarGz = tempDir.appendingPathComponent("data.tar.gz")
        try run("/usr/bin/tar", ["-czf", tarGz.path, "."])
        func member(_ name: String, _ data: Data) -> Data {
            func field(_ value: String, _ width: Int) -> String { value.padding(toLength: width, withPad: " ", startingAt: 0) }
            var result = Data((field(name + "/", 16) + field("0", 12) + field("0", 6) + field("0", 6) + field("100644", 8)
                               + field(String(data.count), 10) + "`\n").utf8)
            precondition(result.count == 60)
            result.append(data)
            if data.count % 2 == 1 { result.append(0x0A) }
            return result
        }
        var deb = Data("!<arch>\n".utf8)
        deb.append(member("debian-binary", Data("2.0\n".utf8)))
        deb.append(member("control.tar.gz", try Data(contentsOf: tarGz)))
        deb.append(member("data.tar.gz", try Data(contentsOf: tarGz)))
        let debURL = tempDir.appendingPathComponent("sample.deb")
        try deb.write(to: debURL)
        let debPaths = try paths(debURL)
        precondition(debPaths == ["debian-binary", "control.tar.gz", "data.tar.gz"], "deb 顶层成员不符")
        print("  ✓ deb 列出 ar 顶层成员")

        // rpm：96 字节 lead + 空签名头 + 空主头 + gzip 压缩的 cpio 负载。
        let cpio = tempDir.appendingPathComponent("payload.cpio")
        try run("/usr/bin/tar", ["--format", "newc", "-cf", cpio.path, "目录"])
        let gzip = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/gzip"), arguments: ["-kf", cpio.path])
        precondition(gzip.status == 0, gzip.stderr)
        var lead = Data(count: 96)
        lead.replaceSubrange(0..<6, with: [0xED, 0xAB, 0xEE, 0xDB, 3, 0])
        let header = Data([0x8E, 0xAD, 0xE8, 0x01] + [UInt8](repeating: 0, count: 12))
        let rpmURL = tempDir.appendingPathComponent("sample.rpm")
        try (lead + header + header + Data(contentsOf: URL(fileURLWithPath: cpio.path + ".gz"))).write(to: rpmURL)
        let rpmPaths = try paths(rpmURL)
        precondition(rpmPaths.contains("目录/中文.txt"), "rpm 应列出 cpio 负载中的文件")
        print("  ✓ rpm 列出 cpio 负载")

        let isoURL = tempDir.appendingPathComponent("sample.iso")
        try run("/usr/bin/hdiutil", ["makehybrid", "-quiet", "-iso", "-joliet", "-o", isoURL.path, workDir.path])
        let isoPaths = try paths(isoURL)
        precondition(isoPaths.contains("目录/中文.txt"), "iso 应列出 Joliet 中文文件名")
        print("  ✓ iso 列出光盘目录")

        let pkgURL = tempDir.appendingPathComponent("sample.pkg")
        try run("/usr/bin/pkgbuild", ["--quiet", "--root", workDir.path, "--identifier", "com.example.preview",
                                      "--version", "1", "--install-location", "/tmp/finderright-preview", pkgURL.path])
        let pkgPaths = try paths(pkgURL)
        precondition(pkgPaths.isSuperset(of: ["Bom", "Payload", "PackageInfo"]), "pkg 应列出 xar 顶层成员")
        print("  ✓ pkg 列出 xar 顶层成员")
    }

    // MARK: - 2. RAR5 自包含 fixture
    private static func testRar5Fixture(in tempDir: URL) throws {
        print("\n--- 2. 测试自包含 RAR5 Store Fixture ---")
        // 357 字节的自包含 RAR5 Store 测试归档
        let rar5Base64 = "UmFyIRoHAQDFGjMyAwEAANUW0owZAgJ+BH6kgwLyOxPXAAEK6K+05piOLnR4dEZpbmRlclJpZ2h0IOepuuagvOmihOiniOekuuS+iwrov5nph4zlj6rljIXlkKvkurrlt6XnlJ/miJDnmoTmtYvor5XmlbDmja7jgIIK5Y6L57yp5YyF5bqU5pi+56S65q2k5paH5Lu25Y+KIGRvY3Mg5a2Q55uu5b2V44CCCiNXu4EdAgJQBFCkgwKvKj3yAAEOZG9jcy9ub3Rlcy50eHTkuK3mlofmlofku7blkI3kuI7ltYzlpZfnm67lvZXmtYvor5XjgIIK6aKE6KeI5oiQ5Yqf5bqU6IO955yL5Yiw6L+Z5p2h5paH5a2X44CCCrp4W0gdAgIdBB2kgwKLCTODAAEOZG9jcy90YWJsZS50c3blkI3np7AJ5pWw6YePCuiLueaenAkzCuaiqAk1ChmyOjUDBQAA"

        guard let rarData = Data(base64Encoded: rar5Base64) else {
            fatalError("无法解码 RAR5 base64 fixture")
        }
        let rarURL = tempDir.appendingPathComponent("sample-rar5.rar")
        try rarData.write(to: rarURL)

        let listing = try PreviewArchive.read(rarURL)
        precondition(!listing.truncated)
        precondition(listing.entries.count == 3, "RAR5 应有 3 个条目，实际: \(listing.entries.count)")

        let paths = Set(listing.entries.map(\.path))
        precondition(paths.contains("说明.txt"), "缺少 说明.txt")
        precondition(paths.contains("docs/notes.txt"), "缺少 docs/notes.txt")
        precondition(paths.contains("docs/table.tsv"), "缺少 docs/table.tsv")

        let descEntry = listing.entries.first { $0.path == "说明.txt" }!
        precondition(descEntry.size == 126, "说明.txt 尺寸应为 126")
        precondition(!descEntry.isDirectory && !descEntry.isSymbolicLink)

        let notesEntry = listing.entries.first { $0.path == "docs/notes.txt" }!
        precondition(notesEntry.size == 80, "notes.txt 尺寸应为 80")

        let tableEntry = listing.entries.first { $0.path == "docs/table.tsv" }!
        precondition(tableEntry.size == 29, "table.tsv 尺寸应为 29")

        print("  ✓ RAR5 归档读取通过（自包含 fixture、中文文件名、子目录及尺寸准确）")
    }

    // MARK: - 3. ./ 根条目与 ./ 前缀处理
    private static func testDotSlashHandling(in tempDir: URL) throws {
        print("\n--- 3. 测试 ./ 根条目忽略与 ./ 前缀剥除 ---")
        let dotWorkDir = tempDir.appendingPathComponent("dot-work", isDirectory: true)
        try FileManager.default.createDirectory(at: dotWorkDir, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: dotWorkDir.appendingPathComponent("inner.txt"))

        let tarURL = tempDir.appendingPathComponent("dot-slash.tar")
        let res = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                       arguments: ["-cf", tarURL.path, "."],
                                       currentDirectoryURL: dotWorkDir)
        precondition(res.status == 0, res.stderr)

        let listing = try PreviewArchive.read(tarURL)
        // 单独的根 "." 或 "./" 不得展示在 entries 中
        precondition(!listing.entries.contains { $0.path == "." || $0.path == "./" },
                     "条目列表中不能包含单独根 ./ 条目")

        // 前缀 ./ 应被去除
        precondition(listing.entries.contains { $0.path == "inner.txt" },
                     "条目应剥除前缀 ./，实际: \(listing.entries.map(\.path))")

        print("  ✓ ./ 根条目与 ./ 前缀处理正确")
    }

    // MARK: - 4. 条目截断 (limit)
    private static func testTruncation(in tempDir: URL) throws {
        print("\n--- 4. 测试条目数量限制与截断 ---")
        let truncDir = tempDir.appendingPathComponent("trunc-work", isDirectory: true)
        try FileManager.default.createDirectory(at: truncDir, withIntermediateDirectories: true)
        for i in 1...10 {
            try Data("test".utf8).write(to: truncDir.appendingPathComponent("file_\(i).txt"))
        }
        let tarURL = tempDir.appendingPathComponent("trunc.tar")
        _ = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                  arguments: ["-cf", tarURL.path, "."],
                                  currentDirectoryURL: truncDir)

        let listing = try PreviewArchive.read(tarURL, limit: 3)
        precondition(listing.entries.count == 3, "数量应严格截断为 3，实际: \(listing.entries.count)")
        precondition(listing.truncated, "truncated 标志必须为 true")

        let fullListing = try PreviewArchive.read(tarURL, limit: 100)
        precondition(fullListing.entries.count == 10, "未超限时应返回全部 10 项")
        precondition(!fullListing.truncated, "未超限时 truncated 必须为 false")

        print("  ✓ 条目截断正确")
    }

    // MARK: - 5. 路径安全攻击防御
    private static func testPathSecurityAttacks(in tempDir: URL) throws {
        print("\n--- 5. 测试路径安全攻击防御（绝对路径/../反斜杠/NUL/盘符/超32层/过长路径）---")

        func expectInvalidPath(name: String, pathInTar: String) {
            let data = makeCraftedTar(name: pathInTar)
            let fileURL = tempDir.appendingPathComponent("attack-\(UUID()).tar")
            try! data.write(to: fileURL)
            defer { try? FileManager.default.removeItem(at: fileURL) }

            do {
                _ = try PreviewArchive.read(fileURL)
                fatalError("安全漏洞：路径 '\(pathInTar)' 未被拦截！")
            } catch let error as PreviewArchiveError {
                precondition(error == .invalidPath, "\(name): 期望 invalidPath，实际得到 \(error)")
                print("  ✓ 拦截 \(name): \(pathInTar)")
            } catch {
                fatalError("\(name): 期望 PreviewArchiveError.invalidPath，实际得到: \(error)")
            }
        }

        expectInvalidPath(name: "绝对路径", pathInTar: "/etc/passwd")
        expectInvalidPath(name: "目录遍历 ..", pathInTar: "foo/../bar.txt")
        expectInvalidPath(name: "开头包含 ..", pathInTar: "../escaped.txt")
        expectInvalidPath(name: "反斜杠路径", pathInTar: "dir\\secret.txt")
        expectInvalidPath(name: "Windows 盘符", pathInTar: "C:boot.ini")
        expectInvalidPath(name: "空组件 //", pathInTar: "foo//bar.txt")

        // 超过 32 层目录深度（每层单字符，在 100 字节 ustar header 限制内保持格式完整）
        let deepPath = (1...33).map { _ in "a" }.joined(separator: "/")
        expectInvalidPath(name: "超过 32 层深度", pathInTar: deepPath)
    }

    // MARK: - 6. 损坏归档与非归档文件
    private static func testDamagedAndInvalidArchives(in tempDir: URL) throws {
        print("\n--- 6. 测试损坏归档与非归档文件（不得作为空成功）---")

        // 1. 纯文本文件
        let textURL = tempDir.appendingPathComponent("plain.txt")
        try Data("Just plain text file".utf8).write(to: textURL)
        do {
            _ = try PreviewArchive.read(textURL)
            fatalError("未拦截普通文本文件")
        } catch let err as PreviewArchiveError {
            precondition(err == .unsupportedFormat || err == .invalidArchive)
            print("  ✓ 拦截普通文本文件: \(err)")
        }

        // 2. 0 字节空文件
        let emptyURL = tempDir.appendingPathComponent("empty.bin")
        try Data().write(to: emptyURL)
        do {
            _ = try PreviewArchive.read(emptyURL)
            fatalError("未拦截 0 字节空文件")
        } catch let err as PreviewArchiveError {
            precondition(err == .unsupportedFormat || err == .invalidArchive)
            print("  ✓ 拦截 0 字节空文件: \(err)")
        }

        // 3. 损坏的 tar.gz (前 16 字节被随机破坏)
        let corruptGzURL = tempDir.appendingPathComponent("corrupt.tar.gz")
        try Data([0x1f, 0x8b, 0x08, 0x00, 0xde, 0xad, 0xbe, 0xef]).write(to: corruptGzURL)
        do {
            _ = try PreviewArchive.read(corruptGzURL)
            fatalError("未拦截损坏的 gzip 归档")
        } catch let err as PreviewArchiveError {
            precondition(err == .invalidArchive || err == .unsupportedFormat)
            print("  ✓ 拦截损坏压缩包: \(err)")
        }

        // 4. 目录 URL
        do {
            _ = try PreviewArchive.read(tempDir)
            fatalError("未拦截目录 URL")
        } catch let err as CocoaError {
            precondition(err.code == .fileReadUnsupportedScheme)
            print("  ✓ 拦截目录 URL: \(err)")
        }

        // 根输入也不能跟随链接或阻塞在 FIFO 上。
        let link = tempDir.appendingPathComponent("archive-link.tar")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: textURL)
        do { _ = try PreviewArchive.read(link); fatalError("不得跟随根符号链接") } catch { }
        let fifo = tempDir.appendingPathComponent("archive-fifo.tar")
        precondition(mkfifo(fifo.path, 0o600) == 0)
        do { _ = try PreviewArchive.read(fifo); fatalError("不得读取 FIFO") } catch { }

        // 5. 不存在的文件
        let noFile = tempDir.appendingPathComponent("non-existent-\(UUID()).tar")
        do {
            _ = try PreviewArchive.read(noFile)
            fatalError("未拦截不存在的文件")
        } catch let err as CocoaError {
            precondition(err.code == .fileReadNoSuchFile)
            print("  ✓ 拦截不存在的文件: \(err)")
        }
    }

    // MARK: - 7. 资源限制验证
    private static func testResourceLimits(in tempDir: URL) throws {
        print("\n--- 7. 测试资源限制（读取超时/物理读取字节数/累计路径长度）---")

        // 构造一个包含 20 个条目的标准 tar 文件
        let workDir = tempDir.appendingPathComponent("resource-work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        for i in 1...20 {
            try Data(repeating: 0x41, count: 512).write(to: workDir.appendingPathComponent("data_file_\(i).bin"))
        }
        let tarURL = tempDir.appendingPathComponent("resource.tar")
        _ = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                  arguments: ["-cf", tarURL.path, "."],
                                  currentDirectoryURL: workDir)

        // 验证物理扫描字节限制触发 (例如设置 maxPhysicalBytes 为 200 字节，不足以读完 10KB 归档)
        do {
            _ = try PreviewArchive.read(tarURL, maxPhysicalBytes: 200)
            fatalError("未触发物理扫描字节上限！")
        } catch let err as PreviewArchiveError {
            precondition(err == .tooLarge, "期望 .tooLarge，实际: \(err)")
            print("  ✓ 成功触发物理扫描字节限制: \(err)")
        }

        // 验证累计路径长度限制触发 (例如设置 maxTotalPathBytes 为 25 字节)
        do {
            _ = try PreviewArchive.read(tarURL, maxTotalPathBytes: 25)
            fatalError("未触发累计路径长度上限！")
        } catch let err as PreviewArchiveError {
            precondition(err == .tooLarge, "期望 .tooLarge，实际: \(err)")
            print("  ✓ 成功触发累计路径长度限制: \(err)")
        }

        // 验证读取超时 (设置极小 timeout: 0 秒)
        do {
            _ = try PreviewArchive.read(tarURL, timeout: 0)
            fatalError("未触发读取超时！")
        } catch let err as PreviewArchiveError {
            precondition(err == .timeout, "期望 .timeout，实际: \(err)")
            print("  ✓ 成功触发读取超时限制: \(err)")
        }
    }

    // MARK: - 辅助：构造畸形 tar 包测试
    private static func makeCraftedTar(name: String, content: String = "attack") -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        let nameBytes = Array(name.utf8)
        for i in 0..<min(nameBytes.count, 99) { block[i] = nameBytes[i] }
        let modeStr = "0000644\0"
        for (i, b) in modeStr.utf8.enumerated() { block[100 + i] = b }
        let uidStr = "0000000\0"
        for (i, b) in uidStr.utf8.enumerated() { block[108 + i] = b }
        let gidStr = "0000000\0"
        for (i, b) in gidStr.utf8.enumerated() { block[116 + i] = b }
        let sizeOct = String(format: "%011o\0", content.utf8.count)
        for (i, b) in sizeOct.utf8.enumerated() { block[124 + i] = b }
        let mtimeOct = String(format: "%011o\0", 1700000000)
        for (i, b) in mtimeOct.utf8.enumerated() { block[136 + i] = b }
        block[156] = UInt8(ascii: "0")
        let magic = "ustar\0"
        for (i, b) in magic.utf8.enumerated() { block[257 + i] = b }
        let ver = "00"
        for (i, b) in ver.utf8.enumerated() { block[263 + i] = b }
        for i in 148..<156 { block[i] = 0x20 }
        let sum = block.reduce(0) { $0 + Int($1) }
        let chksumStr = String(format: "%06o\0 ", sum)
        for (i, b) in chksumStr.utf8.enumerated() { block[148 + i] = b }

        var result = Data(block)
        if !content.isEmpty {
            var contentData = Data(content.utf8)
            let pad = (512 - (contentData.count % 512)) % 512
            contentData.append(Data(repeating: 0, count: pad))
            result.append(contentData)
        }
        result.append(Data(repeating: 0, count: 1024))
        return result
    }
}
