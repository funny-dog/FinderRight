import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// 压缩解压与进程
enum ArchiveTests {
    static func run() {
        // 27. 压缩临时目录登记：正常移除、崩溃残留清扫、防篡改
        runTest("ScratchDirectoryRegistry 创建、移除与崩溃残留清扫") {
            let regDir = makeTempDirectory(), work = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: regDir)
                try? FileManager.default.removeItem(at: work)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: regDir)

            let a = try registry.makeScratchDirectory(in: work)
            try assertTrue(a.lastPathComponent.hasPrefix(ScratchDirectoryRegistry.namePrefix))
            try assertTrue(FileManager.default.fileExists(atPath: a.path))
            registry.remove(a)
            try assertTrue(!FileManager.default.fileExists(atPath: a.path), "remove 应删除目录")

            // 模拟崩溃：创建后没来得及 remove
            let b = try registry.makeScratchDirectory(in: work)
            try Data("x".utf8).write(to: b.appendingPathComponent("leftover.bin"))
            try assertEqual(ScratchDirectoryRegistry(registryDirectory: regDir).sweep(), 1)
            try assertTrue(!FileManager.default.fileExists(atPath: b.path), "sweep 应清理崩溃残留")
            try assertEqual(registry.sweep(), 0, "清扫后登记应已清空")
        }

        runTest("ScratchDirectoryRegistry 不删除被篡改登记指向的目录") {
            let regDir = makeTempDirectory(), work = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: regDir)
                try? FileManager.default.removeItem(at: work)
            }
            let victim = work.appendingPathComponent("Documents", isDirectory: true)
            try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
            let important = victim.appendingPathComponent("important.txt")
            try Data("keep".utf8).write(to: important)
            // 带前缀但实为指向受害目录的符号链接
            let link = work.appendingPathComponent(ScratchDirectoryRegistry.namePrefix + "evil")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

            let tampered = try JSONSerialization.data(withJSONObject: [victim.path, link.path])
            try tampered.write(to: regDir.appendingPathComponent(ScratchDirectoryRegistry.fileName))
            _ = ScratchDirectoryRegistry(registryDirectory: regDir).sweep()

            try assertTrue(FileManager.default.fileExists(atPath: important.path), "被篡改的登记不得导致删除用户数据")
        }

        // 28. 压缩：退出码判定成功、失败不留残留、同名不覆盖
        runTest("ZipCompressor 单文件压缩") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: reg)
            let foo = work.appendingPathComponent("foo.txt")
            try Data("hi".utf8).write(to: foo)

            let zip = try ZipCompressor.compress(items: [foo], into: work, baseName: "foo", registry: registry)
            try assertEqual(zip.lastPathComponent, "foo.zip")
            try assertEqual(try zipEntries(zip), ["foo.txt"])
            try assertEqual(try directoryListing(work), ["foo.txt", "foo.zip"], "不得残留临时目录")
        }

        runTest("ZipCompressor 文件夹压缩保留顶层目录名") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let folder = work.appendingPathComponent("Folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("a".utf8).write(to: folder.appendingPathComponent("a.txt"))

            let zip = try ZipCompressor.compress(items: [folder], into: work, baseName: "Folder",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: reg))
            try assertEqual(try zipEntries(zip), ["Folder/", "Folder/a.txt"])
        }

        runTest("ZipCompressor 多选压缩条目位于根部") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let a = work.appendingPathComponent("a.txt"), b = work.appendingPathComponent("b.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: b)

            let zip = try ZipCompressor.compress(items: [a, b], into: work, baseName: "Archive",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: reg))
            try assertEqual(zip.lastPathComponent, "Archive.zip")
            try assertEqual(try zipEntries(zip), ["a.txt", "b.txt"])
            try assertEqual(try directoryListing(work), ["Archive.zip", "a.txt", "b.txt"], "不得残留暂存目录")
        }

        runTest("ZipCompressor 同名不覆盖：已有文件与先后两次任务") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: reg)
            let existing = work.appendingPathComponent("foo.zip")
            try Data("sentinel".utf8).write(to: existing)
            let txt = work.appendingPathComponent("foo.txt"), md = work.appendingPathComponent("foo.md")
            try Data("t".utf8).write(to: txt)
            try Data("m".utf8).write(to: md)

            let first = try ZipCompressor.compress(items: [txt], into: work, baseName: "foo", registry: registry)
            let second = try ZipCompressor.compress(items: [md], into: work, baseName: "foo", registry: registry)
            try assertEqual(first.lastPathComponent, "foo 1.zip")
            try assertEqual(second.lastPathComponent, "foo 2.zip")
            try assertEqual(try String(contentsOf: existing, encoding: .utf8), "sentinel", "已有文件不得被覆盖")
            try assertEqual(try zipEntries(first), ["foo.txt"], "前一次任务的产物不得被后一次覆盖")
            try assertEqual(try zipEntries(second), ["foo.md"])
        }

        runTest("ZipCompressor 失败时不留残缺 zip 与临时目录") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            let box = work.appendingPathComponent("Box", isDirectory: true)
            let lockedInBox = box.appendingPathComponent("locked.txt")
            let lockedLoose = work.appendingPathComponent("locked2.txt")
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedInBox.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedLoose.path)
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: reg)
            try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
            try Data("ok".utf8).write(to: box.appendingPathComponent("ok.txt"))
            try Data("x".utf8).write(to: lockedInBox)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedInBox.path)

            // 单个文件夹内含不可读文件：压缩工具退出码非 0
            do {
                _ = try ZipCompressor.compress(items: [box], into: work, baseName: "Box", registry: registry)
                throw TestFailure(message: "含不可读文件时应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .toolFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
            try assertEqual(try directoryListing(work), ["Box"], "失败后不得留下 zip 或临时目录")

            // 多选中有不可读文件：同样整体失败，不产出少文件的 zip
            let plain = work.appendingPathComponent("plain.txt")
            try Data("p".utf8).write(to: plain)
            try Data("y".utf8).write(to: lockedLoose)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedLoose.path)
            do {
                _ = try ZipCompressor.compress(items: [plain, lockedLoose], into: work, baseName: "Archive", registry: registry)
                throw TestFailure(message: "多选含不可读文件时应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .toolFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
            try assertEqual(try directoryListing(work), ["Box", "locked2.txt", "plain.txt"], "失败后不得留下 zip 或临时目录")
        }

        runTest("ZipCompressor 干净 zip：中文名带 UTF-8 标志、排除 Mac 垃圾、保留正常隐藏文件") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let fm = FileManager.default
            let folder = work.appendingPathComponent("项目", isDirectory: true)
            try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
            try fm.createDirectory(at: folder.appendingPathComponent("__MACOSX"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("__MACOSX/._报告.txt"))
            try Data("r".utf8).write(to: folder.appendingPathComponent("报告.txt"))
            try Data("K=V".utf8).write(to: folder.appendingPathComponent(".env"))
            try Data().write(to: folder.appendingPathComponent(".DS_Store"))
            // 真正的 AppleDouble（魔数 0x00051607）应排除；同样以 ._ 开头的普通文件应保留
            try Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]).write(to: folder.appendingPathComponent("._报告.txt"))
            try Data("plain".utf8).write(to: folder.appendingPathComponent("._legit"))
            let csv = folder.appendingPathComponent("sub/数据.csv")
            try Data("1,2".utf8).write(to: csv)
            _ = setxattr(csv.path, "com.apple.metadata:kMDItemWhereFroms", "t", 1, 0, 0)

            let zip = try ZipCompressor.compress(items: [folder], into: work, baseName: "项目",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: reg))
            guard let entries = ZipProbe.centralDirectoryEntries(of: zip) else {
                throw TestFailure(message: "无法解析产物的中央目录")
            }
            let names = entries.map { String(decoding: $0.nameBytes, as: UTF8.self) }.sorted()
            try assertEqual(names, ["项目/", "项目/._legit", "项目/.env", "项目/sub/", "项目/sub/数据.csv", "项目/报告.txt"].sorted())
            for entry in entries where entry.nameBytes.contains(where: { $0 >= 0x80 }) {
                try assertTrue(entry.flags & 0x0800 != 0, "非 ASCII 文件名必须带 UTF-8 标志: \(String(decoding: entry.nameBytes, as: UTF8.self))")
            }
            try assertEqual(try directoryListing(work), ["项目", "项目.zip"], "不得残留临时目录")
        }

        runTest("ZipCompressor 多选可来自不同目录，同名则报错") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let registry = ScratchDirectoryRegistry(registryDirectory: reg)
            let d1 = work.appendingPathComponent("d1", isDirectory: true)
            let d2 = work.appendingPathComponent("d2", isDirectory: true)
            try FileManager.default.createDirectory(at: d2.appendingPathComponent("乙"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: d1, withIntermediateDirectories: true)
            let a = d1.appendingPathComponent("甲.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: d2.appendingPathComponent("乙/x.txt"))

            let zip = try ZipCompressor.compress(items: [a, d2.appendingPathComponent("乙")], into: d1,
                                                 baseName: "Archive", registry: registry)
            // zipinfo 在 C locale 下把 UTF-8 文件名显示成 ???，这里直接读中央目录
            let names = (ZipProbe.centralDirectoryEntries(of: zip) ?? []).map { String(decoding: $0.nameBytes, as: UTF8.self) }
            try assertEqual(names.sorted(), ["乙/", "乙/x.txt", "甲.txt"].sorted())

            let dup = d2.appendingPathComponent("甲.txt")
            try Data("c".utf8).write(to: dup)
            do {
                _ = try ZipCompressor.compress(items: [a, dup], into: d1, baseName: "Archive", registry: registry)
                throw TestFailure(message: "多选同名应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .stagingFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
        }

        runTest("ZipCompressor 子目录读不了时报错，不产出缺内容的 zip") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            let locked = work.appendingPathComponent("Box/locked", isDirectory: true)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: locked.appendingPathComponent("a.txt"))
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            do {
                _ = try ZipCompressor.compress(items: [work.appendingPathComponent("Box")], into: work, baseName: "Box",
                                               registry: ScratchDirectoryRegistry(registryDirectory: reg))
                throw TestFailure(message: "子目录不可读时应当失败")
            } catch let error as ZipCompressor.Failure {
                guard case .stagingFailed = error else { throw TestFailure(message: "错误类型不符: \(error)") }
            }
            try assertEqual(try directoryListing(work), ["Box"], "失败后不得留下 zip 或临时目录")
        }

        runTest("ZipCompressor 选中 .app 等包时退回 ditto，保留 Mac 元数据") {
            let work = makeTempDirectory(), reg = makeTempDirectory()
            defer {
                try? FileManager.default.removeItem(at: work)
                try? FileManager.default.removeItem(at: reg)
            }
            let app = work.appendingPathComponent("Foo.app", isDirectory: true)
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            let plist = app.appendingPathComponent("Contents/Info.plist")
            try Data("<plist/>".utf8).write(to: plist)
            _ = setxattr(plist.path, "com.apple.metadata:kMDItemWhereFroms", "t", 1, 0, 0)

            let zip = try ZipCompressor.compress(items: [app], into: work, baseName: "Foo",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: reg))
            let names = (ZipProbe.centralDirectoryEntries(of: zip) ?? []).map { String(decoding: $0.nameBytes, as: UTF8.self) }
            try assertTrue(names.contains("Foo.app/Contents/Info.plist"))
            try assertTrue(names.contains { $0.hasPrefix("__MACOSX/") }, "ditto 应以 __MACOSX 保存扩展属性")
        }

        // 用系统 bsdtar 现场生成测试 zip，仓库里不放二进制样本
        func makeZip(_ name: String, in dir: URL, entries: [String], options: [String]) throws -> URL {
            let output = dir.appendingPathComponent(name)
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/tar"),
                                               arguments: ["--format", "zip"] + options + ["-cf", output.path] + entries,
                                               currentDirectoryURL: dir)
            guard result.status == 0 else { throw TestFailure(message: "生成测试 zip 失败: \(result.stderr)") }
            return output
        }

        runTest("ZipProbe 识别加密条目与未声明编码的非 UTF-8 文件名") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("资料"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("资料/报告.txt"))

            let plain = try makeZip("plain.zip", in: work, entries: ["资料"], options: ["--options", "zip:hdrcharset=UTF-8"])
            try assertEqual(ZipProbe.inspect(plain), ZipProbe(hasEncryptedEntries: false, hasNonUTF8LegacyNames: false))

            let aes = try makeZip("aes.zip", in: work, entries: ["资料"],
                                  options: ["--options", "zip:encryption=aes256,zip:hdrcharset=UTF-8", "--passphrase", "pw"])
            try assertEqual(ZipProbe.inspect(aes)?.hasEncryptedEntries, true, "AES-256")

            let crypto = try makeZip("zc.zip", in: work, entries: ["资料"],
                                     options: ["--options", "zip:encryption=zipcrypt", "--passphrase", "pw"])
            try assertEqual(ZipProbe.inspect(crypto)?.hasEncryptedEntries, true, "ZipCrypto")

            // Windows 中文系统生成的 GBK 文件名、不设 UTF-8 标志
            let gbk = try makeZip("gbk.zip", in: work, entries: ["资料"], options: ["--options", "zip:hdrcharset=CP936"])
            try assertEqual(ZipProbe.inspect(gbk), ZipProbe(hasEncryptedEntries: false, hasNonUTF8LegacyNames: true))

            // 访达 / ditto 生成的包：不设标志，但文件名本身就是 UTF-8
            let dittoZip = work.appendingPathComponent("ditto.zip")
            let ditto = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                                              arguments: ["-c", "-k", "--keepParent", work.appendingPathComponent("资料").path, dittoZip.path])
            try assertEqual(ditto.status, 0, ditto.stderr)
            try assertEqual(ZipProbe.inspect(dittoZip), ZipProbe(hasEncryptedEntries: false, hasNonUTF8LegacyNames: false))
        }

        runTest("ZipProbe 无法解析时返回 nil") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try Data("hello".utf8).write(to: work.appendingPathComponent("a.txt"))
            let zip = try makeZip("a.zip", in: work, entries: ["a.txt"], options: [])

            let empty = work.appendingPathComponent("empty.zip")
            try Data().write(to: empty)
            try assertNil(ZipProbe.inspect(empty), "空文件")

            let garbage = work.appendingPathComponent("garbage.zip")
            try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }).write(to: garbage)
            try assertNil(ZipProbe.inspect(garbage), "随机字节")

            let data = try Data(contentsOf: zip)
            let truncated = work.appendingPathComponent("truncated.zip")
            try data.prefix(data.count / 2).write(to: truncated)
            try assertNil(ZipProbe.inspect(truncated), "截断")

            try assertNil(ZipProbe.inspect(work.appendingPathComponent("missing.zip")), "文件不存在")
        }

        runTest("Preview 文件夹只读当前层、包含隐藏项、不展开链接与文件包，并限制数量") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("目录/下层"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: work.appendingPathComponent("Demo.app/Contents"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("中文.txt"))
            try Data().write(to: work.appendingPathComponent(".hidden"))
            let link = work.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: work.appendingPathComponent("目录"))
            let listing = try PreviewContents.folder(work)
            try assertEqual(listing.entries.count, 5)
            try assertTrue(!listing.truncated)
            try assertTrue(listing.entries.contains { $0.path == ".hidden" })
            try assertEqual(listing.entries.first { $0.path == "中文.txt" }?.size, 5)
            try assertEqual(listing.entries.first { $0.path == "Demo.app" }?.isDirectory, false)
            try assertEqual(listing.entries.first { $0.path == "link" }?.isSymbolicLink, true)
            try assertTrue(!listing.entries.contains { $0.path.contains("/") })
            try assertTrue(try PreviewContents.folder(work, limit: 1).truncated)
            try assertEqual(try PreviewContents.folder(work, limit: 0).entries.count, 0)
            do {
                _ = try PreviewContents.folder(link)
                throw TestFailure(message: "不应跟随链接枚举目录")
            } catch is CocoaError {}
        }

        runTest("Preview 文件夹始终过滤 .DS_Store 与 ._*，其余隐藏项照常展示") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            for name in [".DS_Store", "._报告.txt", ".env", "flagged", "报告.txt"] {
                try Data().write(to: work.appendingPathComponent(name))
            }
            try FileManager.default.createDirectory(at: work.appendingPathComponent(".git"), withIntermediateDirectories: true)
            let chflags = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/chflags"),
                                                arguments: ["hidden", work.appendingPathComponent("flagged").path])
            try assertEqual(chflags.status, 0, chflags.stderr)
            try assertEqual(try PreviewContents.folder(work).entries.map(\.path).sorted(),
                            [".env", ".git", "flagged", "报告.txt"])
            // 上限按可见项计算：被过滤的项不占名额，也不触发截断
            try assertTrue(!(try PreviewContents.folder(work, limit: 4)).truncated)
            try assertTrue(try PreviewContents.folder(work, limit: 3).truncated)
        }

        runTest("Preview ZIP 始终过滤 __MACOSX/._*/.DS_Store，其余点文件照常展示") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            for dir in ["资料/.cache", "__MACOSX/资料", ".git"] {
                try FileManager.default.createDirectory(at: work.appendingPathComponent(dir), withIntermediateDirectories: true)
            }
            for file in ["资料/报告.txt", "资料/.env", "资料/.cache/x", "资料/.DS_Store", "__MACOSX/资料/._报告.txt",
                         "._top", ".git/config", "a.txt"] {
                try Data("x".utf8).write(to: work.appendingPathComponent(file))
            }
            let zip = try makeZip("hidden.zip", in: work, entries: ["资料", "__MACOSX", "._top", ".git", "a.txt"],
                                  options: ["--options", "zip:hdrcharset=UTF-8"])
            // tar 可能为扩展属性额外写入 ._* 条目，一并验证被过滤
            let expected = [".git/", ".git/config", "a.txt", "资料/", "资料/.cache/", "资料/.cache/x",
                            "资料/.env", "资料/报告.txt"]
            try assertEqual(try PreviewContents.zip(zip).entries.map(\.path).sorted(), expected)
            try assertTrue(!(try PreviewContents.zip(zip, limit: expected.count)).truncated)
            try assertTrue(try PreviewContents.zip(zip, limit: expected.count - 1).truncated)
        }

        runTest("Preview 中文 ZIP 的元数据、GBK、加密目录和数量上限") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("资料"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("资料/报告.txt"))
            for (name, options) in [("utf8", ["--options", "zip:hdrcharset=UTF-8"]),
                                     ("gbk", ["--options", "zip:hdrcharset=CP936"]),
                                     ("encrypted", ["--options", "zip:encryption=zipcrypt,zip:hdrcharset=UTF-8", "--passphrase", "pw"])] {
                let zip = try makeZip(name + ".zip", in: work, entries: ["资料"], options: options)
                let listing = try PreviewContents.zip(zip)
                let file = listing.entries.first { $0.path == "资料/报告.txt" }
                try assertEqual(file?.size, 5, name)
                try assertTrue(file?.modificationDate != nil, name)
                try assertTrue(listing.entries.contains { $0.isDirectory && $0.path == "资料/" }, name)
                try assertTrue(try PreviewContents.zip(zip, limit: 1).truncated, name)
            }
        }

        runTest("Preview ZIP 隐式目录与符号链接只读元数据") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("test.zip")
            try previewZipFixture("a/b/中文.txt").write(to: zip)
            let listing = try PreviewContents.zip(zip)
            try assertEqual(listing.entries.map(\.path), ["a/b/中文.txt"])
            try assertEqual(listing.entries.first?.size, 5)
            try previewZipFixture("link", mode: 0o120777).write(to: zip)
            try assertEqual(try PreviewContents.zip(zip).entries.first?.isSymbolicLink, true)
        }

        runTest("Preview ZIP 空包与注释中的伪 EOCD") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("test.zip")
            var empty = Data(repeating: 0, count: 22)
            putZipField(0x06054b50, at: 0, into: &empty)
            try empty.write(to: zip)
            try assertEqual(try PreviewContents.zip(zip).entries.count, 0)
            var data = previewZipFixture("file.txt")
            putZipField(22, at: data.count - 2, bytes: 2, into: &data)
            data.append(empty)
            try data.write(to: zip)
            try assertEqual(try PreviewContents.zip(zip).entries.map(\.path), ["file.txt"])
        }

        runTest("Preview ZIP 拒绝损坏、ZIP64、分卷和异常目录字段") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("test.zip")
            func rejects(_ data: Data, _ expected: PreviewError) throws {
                try data.write(to: zip)
                let result = Result { try PreviewContents.zip(zip) }
                guard case let .failure(error) = result else {
                    throw TestFailure(message: "应拒绝异常 ZIP")
                }
                try assertEqual(error as? PreviewError, expected)
            }
            try rejects(Data("broken".utf8), .invalidArchive)
            let original = previewZipFixture("file.txt")
            try rejects(Data(original.dropLast()), .invalidArchive)
            var zip64 = original
            putZipField(0xFFFF, at: zip64.count - 12, bytes: 2, into: &zip64)
            try rejects(zip64, .zip64NotSupported)
            var split = original
            putZipField(1, at: split.count - 18, bytes: 2, into: &split)
            try rejects(split, .multiDiskNotSupported)
            var overflow = original
            putZipField(0xFFFF_FFFE, at: overflow.count - 10, into: &overflow)
            try rejects(overflow, .invalidArchive)
            try rejects(previewZipFixture("file.txt", flags: 0x2000), .encryptedDirectory)
        }

        runTest("Preview ZIP 拒绝绝对路径、穿越、空组件及过深路径") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let zip = work.appendingPathComponent("test.zip")
            for name in ["../x", "/x", "a//x", "a/./x", "C:/x", "a\\..\\x", String(repeating: "a/", count: 32) + "x"] {
                try previewZipFixture(name).write(to: zip)
                do {
                    _ = try PreviewContents.zip(zip)
                    throw TestFailure(message: "应拒绝路径 \(name)")
                } catch let error as PreviewError { try assertEqual(error, .invalidPath, name) }
            }
        }

        runTest("Preview ZIP 不读取管道或符号链接") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let fifo = work.appendingPathComponent("pipe.zip")
            try assertEqual(mkfifo(fifo.path, 0o600), 0)
            let file = work.appendingPathComponent("file.zip")
            try previewZipFixture("a.txt").write(to: file)
            let link = work.appendingPathComponent("link.zip")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            for url in [fifo, link] {
                do {
                    _ = try PreviewContents.zip(url)
                    throw TestFailure(message: "应拒绝非普通文件 \(url)")
                } catch let error as CocoaError { try assertEqual(error.code, .fileReadUnsupportedScheme) }
            }
        }

        runTest("EncryptedZipExtractor 正确密码解出、错误密码识别并清空输出目录") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("资料"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("资料/报告.txt"))
            let out = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            for encryption in ["aes256", "zipcrypt"] {
                let zip = try makeZip("\(encryption).zip", in: work, entries: ["资料"],
                                      options: ["--options", "zip:encryption=\(encryption),zip:hdrcharset=UTF-8", "--passphrase", "right"])
                try assertEqual(try EncryptedZipExtractor.extract(zip, into: out, password: "wrong", legacyNames: false),
                                .wrongPassword, encryption)
                try assertEqual(try directoryListing(out), [], "错误密码后不得留下空壳文件: \(encryption)")

                try assertEqual(try EncryptedZipExtractor.extract(zip, into: out, password: "right", legacyNames: false),
                                .extracted, encryption)
                try assertEqual(try String(contentsOf: out.appendingPathComponent("资料/报告.txt"), encoding: .utf8), "hello")
                try FileManager.default.removeItem(at: out.appendingPathComponent("资料"))
            }
        }

        runTest("EncryptedZipExtractor 加密且 GBK 文件名的包按 CP936 还原中文名") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("资料"), withIntermediateDirectories: true)
            try Data("hello".utf8).write(to: work.appendingPathComponent("资料/报告.txt"))
            let zip = try makeZip("gbk.zip", in: work, entries: ["资料"],
                                  options: ["--options", "zip:encryption=zipcrypt,zip:hdrcharset=CP936", "--passphrase", "pw"])
            try assertEqual(ZipProbe.inspect(zip), ZipProbe(hasEncryptedEntries: true, hasNonUTF8LegacyNames: true))

            let out = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try assertEqual(try EncryptedZipExtractor.extract(zip, into: out, password: "pw", legacyNames: true), .extracted)
            try assertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("资料/报告.txt").path))
        }

        runTest("EncryptedZipExtractor 非密码问题如实报失败") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let bogus = work.appendingPathComponent("bogus.zip")
            try Data("not a zip at all".utf8).write(to: bogus)
            let out = work.appendingPathComponent("out", isDirectory: true)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let outcome = try EncryptedZipExtractor.extract(bogus, into: out, password: "pw", legacyNames: false)
            guard case .failed = outcome else { throw TestFailure(message: "应为 failed，实际 \(outcome)") }
            try assertTrue(!EncryptedZipExtractor.indicatesWrongPassword("tar: Error opening archive: Unrecognized archive format"))
            try assertTrue(EncryptedZipExtractor.indicatesWrongPassword("a.txt: Incorrect passphrase: Unknown error: -1"))
            try assertTrue(EncryptedZipExtractor.indicatesWrongPassword("a.txt: ZIP bad CRC: 0x1234 should be 0x5678"))
            try assertTrue(EncryptedZipExtractor.indicatesWrongPassword("资料/报告.txt: ZIP decompression failed (-5): Unknown error: -1"))
        }

        runTest("ProcessRunner 子进程 stdin 接 /dev/null，不会等待输入") {
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [])
            try assertEqual(result.status, 0)
        }

        // 29. .xz 进程内解压（替代外部 xz / python3）
        // 由 Python lzma 以标准 xz 格式生成，内容为 "hello finderright\n"
        let xzFixtureBase64 = "/Td6WFoAAATm1rRGAgAhARYAAAB0L+WjAQARaGVsbG8gZmluZGVycmlnaHQKAAAAdqeazgeF0CQAASoSSwhUvB+2830BAAAAAARZWg=="

        runTest("XZDecompressor 解压标准 .xz 文件") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let src = work.appendingPathComponent("hello.txt.xz")
            try Data(base64Encoded: xzFixtureBase64)!.write(to: src)
            let out = work.appendingPathComponent("hello.txt")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try XZDecompressor.decompress(from: src, to: handle)
            try handle.close()
            try assertEqual(try String(contentsOf: out, encoding: .utf8), "hello finderright\n")
        }

        runTest("XZDecompressor 多块输入往返一致") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let raw = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) })
            var encoded = Data()
            let encoder = try OutputFilter(.compress, using: .lzma) { if let d = $0 { encoded.append(d) } }
            try encoder.write(raw)
            try encoder.finalize()
            let src = work.appendingPathComponent("big.bin.xz")
            try encoded.write(to: src)
            let out = work.appendingPathComponent("big.bin")
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            try XZDecompressor.decompress(from: src, to: handle, chunkSize: 4096)
            try handle.close()
            try assertTrue(try Data(contentsOf: out) == raw, "小块读取下内容必须完全一致")
        }

        runTest("XZDecompressor 拒绝损坏、非 xz 与空输入") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let cases: [(String, Data)] = [
                ("截断", Data(base64Encoded: xzFixtureBase64)!.prefix(30)),
                ("非 xz", Data("plain text, not xz".utf8)),
                ("空文件", Data()),
            ]
            for (label, content) in cases {
                let src = work.appendingPathComponent("bad.xz")
                try content.write(to: src)
                let out = work.appendingPathComponent("bad.out")
                FileManager.default.createFile(atPath: out.path, contents: nil)
                let handle = try FileHandle(forWritingTo: out)
                defer { try? handle.close() }
                do {
                    try XZDecompressor.decompress(from: src, to: handle)
                    throw TestFailure(message: "\(label)：应当抛错")
                } catch is TestFailure {
                    throw TestFailure(message: "\(label)：应当抛错")
                } catch {
                    // 预期：Compression 框架报 invalidData
                }
            }
        }

        // 30. 后台任务跟踪：退出前可等待完成
        runTest("BackgroundJobs 跟踪在途任务并可等待完成") {
            let jobs = BackgroundJobs()
            let queue = DispatchQueue(label: "test.jobs")
            try assertTrue(jobs.isIdle, "初始空闲")
            jobs.run(on: queue) { Thread.sleep(forTimeInterval: 0.3) }
            try assertTrue(!jobs.isIdle, "任务进行中不空闲")
            try assertTrue(jobs.waitUntilIdle(timeout: 5), "应在超时前完成")
            try assertTrue(jobs.isIdle, "完成后空闲")
        }

        runTest("BackgroundJobs 等待超时返回 false") {
            let jobs = BackgroundJobs()
            let queue = DispatchQueue(label: "test.jobs.timeout")
            jobs.run(on: queue) { Thread.sleep(forTimeInterval: 1) }
            try assertTrue(!jobs.waitUntilIdle(timeout: 0.1), "任务未完成时应超时")
            try assertTrue(jobs.waitUntilIdle(timeout: 5), "最终应完成")
        }

        // 30b. 退出交接：关闭后不再接受新任务，避免「确认空闲 → 接受任务 → 立刻退出」
        runTest("BackgroundJobs 关闭后等待在途任务并拒绝新任务") {
            let jobs = BackgroundJobs()
            let queue = DispatchQueue(label: "test.jobs.close")
            let started = DispatchSemaphore(value: 0)
            try assertTrue(jobs.run(on: queue) { started.signal(); Thread.sleep(forTimeInterval: 0.3) }, "关闭前应接受任务")
            started.wait()
            try assertTrue(jobs.closeAndWait(timeout: 5), "关闭应等待在途任务完成")
            try assertTrue(jobs.isIdle, "关闭后应空闲")
            var ran = false
            try assertTrue(!jobs.run(on: queue) { ran = true }, "关闭后不应再接受任务")
            queue.sync {}
            try assertTrue(!ran, "被拒绝的任务不应执行")
        }

        // 30c. 退出开关：关闭后拒绝新任务；只判断空闲挡不住「确认后挤进新任务」
        runTest("BackgroundJobs 关闭后拒绝新任务") {
            let jobs = BackgroundJobs()
            try assertTrue(jobs.isAcceptingJobs, "默认接受")
            jobs.close()
            try assertTrue(!jobs.isAcceptingJobs, "关闭后拒绝")
        }

        // 32. IPC 请求闸门：退出排空必须异步——已受理请求可能回到发起关闭的线程完成收尾
        runTest("RequestDrainGate 关闭后排空已受理请求并拒绝新请求") {
            let queue = DispatchQueue(label: "test.drain.queue")
            let gate = RequestDrainGate(queue: queue)
            var order: [String] = []
            try assertTrue(gate.accept { order.append("a") }, "关闭前应受理")
            try assertTrue(gate.accept { order.append("b") }, "关闭前应受理")
            let drained = DispatchSemaphore(value: 0)
            gate.close(notifyDrained: { drained.signal() })
            try assertTrue(!gate.accept { order.append("late") }, "关闭后应拒绝新请求")
            queue.sync {}
            try assertEqual(order, ["a", "b"], "排空回调应排在全部已受理请求之后")
            try assertTrue(drained.wait(timeout: .now() + 5) == .success, "排空回调应恰好到达一次")
        }

        runTest("RequestDrainGate 关闭不阻塞，请求可在发起关闭的队列上完成收尾") {
            let queue = DispatchQueue(label: "test.drain.queue2")
            let mainLike = DispatchQueue(label: "test.drain.mainlike")
            let gate = RequestDrainGate(queue: queue)
            let started = DispatchSemaphore(value: 0)
            let drained = DispatchSemaphore(value: 0)
            var completed = false
            // 请求块模拟「回主线程写剪贴板」：最后一步要在发起关闭的队列上同步完成
            try assertTrue(gate.accept {
                started.signal()
                mainLike.sync { completed = true }
            })
            // 等请求真正运行并卡在 mainLike.sync（模拟主线程正忙于退出流程）
            try assertTrue(started.wait(timeout: .now() + 5) == .success)
            // 关闭调用绝不能阻塞在队列上——旧实现在这里 queue.sync 会死锁
            gate.close(notifyDrained: { drained.signal() })
            try assertTrue(!gate.accept { }, "关闭后应拒绝新请求")
            // 服务「主线程」，让请求完成收尾
            mainLike.sync {}
            try assertTrue(completed, "请求应能在发起关闭的队列上完成收尾")
            try assertTrue(drained.wait(timeout: .now() + 5) == .success, "请求完成后排空回调应到达")
        }

        // 32b. 更新退出：IPC 排空须无限等待，不被 30 秒超时放行
        // 模拟"在途请求完成"场景：关闭后等待排空，排空信号延迟到达也应正确等到
        runTest("RequestDrainGate 更新退出：排空不设时限（延迟完成的请求也等到）") {
            let queue = DispatchQueue(label: "test.drain.update-quit")
            let gate = RequestDrainGate(queue: queue)
            let release = DispatchSemaphore(value: 0)
            let drained = DispatchSemaphore(value: 0)
            // 受理一个"慢请求"（需要外部释放才完成）
            try assertTrue(gate.accept { release.wait() }, "关闭前应受理")
            gate.close(notifyDrained: { drained.signal() })
            // 在同一线程检查，避免后台等待者抢走请求完成后的排空信号。
            try assertTrue(drained.wait(timeout: .now() + 0.05) == .timedOut, "请求完成前排空不应到达")
            // 释放在途请求
            release.signal()
            // 排空应在请求完成后到达
            try assertTrue(drained.wait(timeout: .now() + 5) == .success, "请求完成后排空应到达")
        }

        runTest("RequestDrainGate 空闲时同步关闭并在有在途请求时拒绝早关") {
            let queue = DispatchQueue(label: "test.drain.idle")
            let gate = RequestDrainGate(queue: queue)
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            try assertTrue(gate.accept { started.signal(); release.wait() })
            try assertTrue(started.wait(timeout: .now() + 5) == .success)
            try assertTrue(!gate.closeIfIdle(), "有在途请求时不应同步早关")
            try assertTrue(gate.accept {}, "拒绝早关后门应仍开启")
            release.signal()
            queue.sync {}
            try assertTrue(gate.closeIfIdle(), "全部请求完成后应能同步关闭")
            try assertTrue(!gate.accept {}, "同步关闭后应拒绝新请求")
        }

        runTest("BackgroundJobs 关闭时未完成的任务让等待超时") {
            let jobs = BackgroundJobs()
            let release = DispatchSemaphore(value: 0)
            let started = DispatchSemaphore(value: 0)
            jobs.run(on: DispatchQueue(label: "test.jobs.close.timeout")) { started.signal(); release.wait() }
            started.wait()
            try assertTrue(!jobs.closeAndWait(timeout: 0.1), "任务未完成时关闭等待应超时")
            release.signal()
            try assertTrue(jobs.waitUntilIdle(timeout: 5))
        }

        // 31. 代码签名校验（以系统自带、Apple 签名的 /bin/ls 和测试进程自身为样本）
        runTest("CodeSignatureCheck 读取签名规则与证书指纹") {
            let ls = URL(fileURLWithPath: "/bin/ls")
            let requirement = CodeSignatureCheck.designatedRequirement(ofCodeAt: ls) ?? ""
            try assertTrue(requirement.contains("com.apple.ls"), "签名规则应包含标识: \(requirement)")
            guard case .certificate(let leaf) = CodeSignatureCheck.signatureStatus(ofCodeAt: ls) else {
                throw TestFailure(message: "系统二进制应为证书签名")
            }
            try assertEqual(leaf.count, 40, "SHA-1 指纹应为 40 位十六进制")
            try assertTrue(CodeSignatureCheck.codeAt(ls, satisfies: "certificate leaf = H\"\(leaf)\""), "应满足自己的叶子证书规则")
            try assertTrue(CodeSignatureCheck.codeAt(ls, satisfies: requirement), "应满足自己的签名规则")
        }

        runTest("CodeSignatureCheck 拒绝标识不符、规则无效与内容被改动的代码") {
            let ls = URL(fileURLWithPath: "/bin/ls")
            try assertTrue(!CodeSignatureCheck.codeAt(ls, satisfies: "identifier \"com.finderright.app\""), "标识不符")
            try assertTrue(!CodeSignatureCheck.codeAt(ls, satisfies: "不是合法的规则"), "规则文本无效")
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let modified = work.appendingPathComponent("ls-modified")
            var bytes = try Data(contentsOf: ls)
            bytes[bytes.count / 2] ^= 0xFF
            try bytes.write(to: modified)
            try assertTrue(!CodeSignatureCheck.codeAt(modified, satisfies: "identifier \"com.apple.ls\" and anchor apple"), "内容被改动后签名应失效")
        }

        runTest("CodeSignatureCheck 识别 ad-hoc 签名") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let copy = work.appendingPathComponent("ls-adhoc")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: copy)
            let sign = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                                             arguments: ["-s", "-", "--force", copy.path])
            try assertEqual(sign.status, 0, "ad-hoc 签名失败: \(sign.stderr)")
            try assertTrue(CodeSignatureCheck.designatedRequirement(ofCodeAt: copy)?.hasPrefix("cdhash") == true, "ad-hoc 签名规则应为 cdhash")
            try assertEqual(CodeSignatureCheck.signatureStatus(ofCodeAt: copy), .adHoc, "应明确识别为 ad-hoc")
        }

        runTest("CodeSignatureCheck 区分证书签名与无法读取的签名") {
            let ls = URL(fileURLWithPath: "/bin/ls")
            guard case .certificate = CodeSignatureCheck.signatureStatus(ofCodeAt: ls) else {
                throw TestFailure(message: "系统二进制应识别为证书签名")
            }
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try assertEqual(CodeSignatureCheck.signatureStatus(ofCodeAt: missing), .unreadable, "不存在的路径不能当作 ad-hoc")
        }

        // 31b. 安装前校验：版本一直带到安装阶段，四个 bundle 一致且高于当前版本
        runTest("UpdatePackageCheck 正常新版本通过校验") {
            let root = try makeUpdateAppFixture(version: "1.2.3", build: "10")
            defer { try? FileManager.default.removeItem(at: root) }
            try UpdatePackageCheck.validate(appAt: root, expectation: expectation(version: "v1.2.3"))
        }

        runTest("UpdatePackageCheck 拒绝与预期版本不符或比当前更旧的包") {
            let root = try makeUpdateAppFixture(version: "1.2.3", build: "10")
            defer { try? FileManager.default.removeItem(at: root) }
            try assertThrows(UpdatePackageCheck.Failure.versionMismatch(expected: "1.2.4", actual: "1.2.3"),
                             "检查到 v1.2.4 却下载到 1.2.3") {
                try UpdatePackageCheck.validate(appAt: root, expectation: expectation(version: "v1.2.4"))
            }
            try assertThrows(UpdatePackageCheck.Failure.notNewer(version: "1.2.3", current: "1.2.3"), "不高于当前版本") {
                try UpdatePackageCheck.validate(appAt: root, expectation: expectation(version: "v1.2.3", current: "1.2.3"))
            }
        }

        runTest("UpdatePackageCheck 拒绝四个 bundle 版本不一致与系统不兼容") {
            let root = try makeUpdateAppFixture(version: "1.2.3", build: "10", overrides: [
                "FinderRightMarkdown.appex": ("CFBundleShortVersionString", "1.2.2"),
            ])
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try UpdatePackageCheck.validate(appAt: root, expectation: expectation(version: "v1.2.3"))
                throw TestFailure(message: "版本不一致应被拒绝")
            } catch let error as UpdatePackageCheck.Failure {
                if case .inconsistentBundles(let details) = error {
                    try assertTrue(details.contains("FinderRightMarkdown.appex") && details.contains("1.2.2"), "错误信息应明确指出具体组件与版本")
                } else {
                    throw TestFailure(message: "应抛出 inconsistentBundles，实际 \(error)")
                }
            } catch {
                throw TestFailure(message: "应抛出 UpdatePackageCheck.Failure，实际 \(error)")
            }
            let old = try makeUpdateAppFixture(version: "1.2.3", build: "10", overrides: [
                "FinderRightSync.appex": ("CFBundleVersion", "9"),
            ])
            defer { try? FileManager.default.removeItem(at: old) }
            do {
                try UpdatePackageCheck.validate(appAt: old, expectation: expectation(version: "v1.2.3"))
                throw TestFailure(message: "构建号不一致应被拒绝")
            } catch let error as UpdatePackageCheck.Failure {
                if case .inconsistentBundles(let details) = error {
                    try assertTrue(details.contains("FinderRightSync.appex"), "构建号不一致应指出具体组件")
                } else {
                    throw TestFailure(message: "应抛出 inconsistentBundles，实际 \(error)")
                }
            } catch {
                throw TestFailure(message: "应抛出 UpdatePackageCheck.Failure，实际 \(error)")
            }

            let future = try makeUpdateAppFixture(version: "1.2.3", build: "10", overrides: [
                "FinderRight.app": ("LSMinimumSystemVersion", "26.0"),
            ])
            defer { try? FileManager.default.removeItem(at: future) }
            try assertThrows(UpdatePackageCheck.Failure.unsupportedSystem(required: "26.0", current: "13.6.1"), "系统不兼容") {
                try UpdatePackageCheck.validate(appAt: future, expectation: expectation(version: "v1.2.3"))
            }
            try assertTrue(UpdatePackageCheck.version("13.6.1", isAtLeast: "13.0"), "13.6 满足 13.0")
            try assertTrue(!UpdatePackageCheck.version("12.7", isAtLeast: "13.0"), "12.7 不满足 13.0")
            try assertTrue(UpdatePackageCheck.version("14", isAtLeast: "13.0.1"), "14 满足 13.0.1")
        }

        runTest("UpdateIntegrity 校验更新包签名与当前应用一致性") {
            let missing1 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let missing2 = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let ls = URL(fileURLWithPath: "/bin/ls")
            try assertThrows(UpdateIntegrity.SignatureFailure.currentSignatureUnreadable, "当前应用签名无法读取") {
                try UpdateIntegrity.verifyUpdateSignatures(candidateApp: ls, currentApp: missing1)
            }
            try assertThrows(UpdateIntegrity.SignatureFailure.candidateSignatureUnreadable, "更新包签名无法读取") {
                try UpdateIntegrity.verifyUpdateSignatures(candidateApp: missing2, currentApp: ls)
            }

            // 签名可读但标识不符（/bin/ls 虽证书相同但标识是 com.apple.ls）应拒绝
            try assertThrows(UpdateIntegrity.SignatureFailure.signatureMismatch, "签名可读但应用标识不符") {
                try UpdateIntegrity.verifyUpdateSignatures(candidateApp: ls, currentApp: ls)
            }

            // ad-hoc 旧版过渡期兼容路径：两端均为合法 ad-hoc 时通过
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let copy = work.appendingPathComponent("adhoc-app")
            try FileManager.default.copyItem(at: ls, to: copy)
            let sign = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                                             arguments: ["-s", "-", "--force", copy.path])
            try assertEqual(sign.status, 0, "制作 ad-hoc fixture 失败: \(sign.stderr)")
            try UpdateIntegrity.verifyUpdateSignatures(candidateApp: copy, currentApp: copy)
        }

        runTest("CodeSignatureCheck 按 audit token 校验运行中的进程") {
            guard let token = currentProcessAuditToken(), let me = Bundle.main.executableURL else {
                throw TestFailure(message: "无法取得当前进程的 audit token 或可执行文件路径")
            }
            try assertTrue(CodeSignatureCheck.process(auditToken: token, satisfiesDesignatedRequirementOf: me), "当前进程应满足自身可执行文件的签名规则")
            try assertTrue(!CodeSignatureCheck.process(auditToken: token, satisfiesDesignatedRequirementOf: URL(fileURLWithPath: "/bin/ls")), "不应满足其他程序的签名规则")
            try assertTrue(!CodeSignatureCheck.process(auditToken: Data(count: 32), satisfiesDesignatedRequirementOf: me), "无效的 audit token 应被拒绝")
        }

        // 32. 更新包签名规则：同一证书 + 标识不变
        runTest("UpdateIntegrity 生成新版本签名规则") {
            let rules = UpdateIntegrity.signingRequirements(leafCertificateSHA1: "ABCDEF")
            try assertEqual(rules.app, "identifier \"com.finderright.app\" and certificate leaf = H\"ABCDEF\"")
            try assertEqual(rules.appex, "identifier \"com.finderright.app.sync\" and certificate leaf = H\"ABCDEF\"")
        }

        runTest("UpdateIntegrity 签名规则同时约束证书与标识") {
            let ls = URL(fileURLWithPath: "/bin/ls")
            guard case .certificate(let leaf) = CodeSignatureCheck.signatureStatus(ofCodeAt: ls) else {
                throw TestFailure(message: "系统二进制应识别为证书签名")
            }
            // /bin/ls 与规则证书相同但标识不同，必须被拒绝：只比证书会放行同一证书签出的其他程序
            try assertTrue(!CodeSignatureCheck.codeAt(ls, satisfies: UpdateIntegrity.signingRequirements(leafCertificateSHA1: leaf).app))
            // 同样写法、换成 /bin/ls 自己的标识则应通过：确认规则模板本身语法有效
            try assertTrue(CodeSignatureCheck.codeAt(ls, satisfies: "identifier \"com.apple.ls\" and certificate leaf = H\"\(leaf)\""))
        }

        // 33. IPC execute URL：携带请求文件摘要
        runTest("IPCBridge execute URL 携带请求摘要并可往返解析") {
            let id = UUID().uuidString
            let data = Data("{\"id\":\"x\"}".utf8)
            guard let url = IPCBridge.executeURL(id: id, requestData: data) else {
                throw TestFailure(message: "URL 构造失败")
            }
            try assertTrue(url.absoluteString.hasPrefix("finderright://execute?id="), url.absoluteString)
            let parsed = IPCBridge.parseExecuteURL(url)
            try assertEqual(parsed?.id, id)
            try assertEqual(parsed?.digest, IPCBridge.requestDigest(data))
            try assertEqual(IPCBridge.requestDigest(Data("abc".utf8)),
                            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256 标准测试向量")
        }

        runTest("IPCBridge 拒绝不合规的 execute URL") {
            let id = UUID().uuidString, digest = String(repeating: "a", count: 64)
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "finderright://execute?id=\(id)")!), "旧格式（无摘要）")
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "finderright://execute?id=not-a-uuid&digest=\(digest)")!), "id 不是 UUID")
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "finderright://execute?id=\(id)&digest=xyz")!), "摘要格式错误")
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "finderright://settings?id=\(id)&digest=\(digest)")!), "host 不是 execute")
            try assertNil(IPCBridge.parseExecuteURL(URL(string: "https://execute?id=\(id)&digest=\(digest)")!), "scheme 不符")
        }

        // 34. 下沉到 Kit 的小工具
        runTest("ArchiveKind 识别可解压文件") {
            for name in ["a.zip", "A.ZIP", "a.tar.gz", "a.tgz", "a.tar.bz2", "a.xz", "a.7z", "a.rar", "a.tar"] {
                try assertTrue(ArchiveKind.isArchive(fileName: name), name)
            }
            for name in ["a.txt", "zip", "a.zipx", "a.gzip"] {
                try assertTrue(!ArchiveKind.isArchive(fileName: name), name)
            }
        }

        runTest("BundleIdentifier 校验字符集与长度") {
            try assertTrue(BundleIdentifier.isValid("com.mitchellh.ghostty"))
            try assertTrue(BundleIdentifier.isValid("dev.warp.Warp-Stable"))
            try assertTrue(!BundleIdentifier.isValid(""), "空")
            try assertTrue(!BundleIdentifier.isValid("com.example app"), "含空格")
            try assertTrue(!BundleIdentifier.isValid("com.example/../x"), "含斜杠")
            try assertTrue(!BundleIdentifier.isValid(String(repeating: "a", count: 129)), "超长")
        }

        runTest("UniqueName 依次编号避开已有文件") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try assertEqual(UniqueName.fileURL(baseName: "untitled", ext: "txt", in: dir).lastPathComponent, "untitled.txt")
            try Data().write(to: dir.appendingPathComponent("untitled.txt"))
            try assertEqual(UniqueName.fileURL(baseName: "untitled", ext: "txt", in: dir).lastPathComponent, "untitled 1.txt")
            try Data().write(to: dir.appendingPathComponent("untitled 1.txt"))
            try assertEqual(UniqueName.fileURL(baseName: "untitled", ext: "txt", in: dir).lastPathComponent, "untitled 2.txt")
            try assertEqual(UniqueName.fileURL(baseName: "README", ext: "", in: dir).lastPathComponent, "README", "无后缀")
            try Data().write(to: dir.appendingPathComponent("README"))
            try assertEqual(UniqueName.fileURL(baseName: "README", ext: "", in: dir).lastPathComponent, "README 1", "无后缀时同样编号")
        }

        runTest("UniqueName 正确识别并避开悬空符号链接") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let danglingTarget = dir.appendingPathComponent("nonexistent_target.txt")
            let linkURL = dir.appendingPathComponent("untitled.txt")
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: danglingTarget)

            // fileExists 会跟随符号链接返回 false，但 itemExists 能正确识别悬空链接
            try assertTrue(UniqueName.itemExists(atPath: linkURL.path), "悬空符号链接应被识别为已存在")
            try assertEqual(UniqueName.fileURL(baseName: "untitled", ext: "txt", in: dir).lastPathComponent, "untitled 1.txt")
        }
    }
}
