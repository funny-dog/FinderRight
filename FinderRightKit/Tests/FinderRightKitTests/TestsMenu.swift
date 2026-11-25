import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// 复制路径、菜单与常用目录
enum MenuTests {
    static func run() {
        // MARK: - 复制路径格式

        runTest("PathFormatter 各格式输出") {
            let home = "/Users/me"
            let file = URL(fileURLWithPath: "/Users/me/Documents/a b.txt")
            let dir = URL(fileURLWithPath: "/Users/me/项目", isDirectory: true)
            try assertEqual(PathFormatter.string(for: [file], format: .absolute, home: home), "/Users/me/Documents/a b.txt")
            try assertEqual(PathFormatter.string(for: [file], format: .tilde, home: home), "~/Documents/a b.txt")
            try assertEqual(PathFormatter.string(for: [file], format: .name, home: home), "a b.txt")
            try assertEqual(PathFormatter.string(for: [file], format: .shellEscaped, home: home), "'/Users/me/Documents/a b.txt'")
            try assertEqual(PathFormatter.string(for: [file], format: .fileURL, home: home), "file:///Users/me/Documents/a%20b.txt")
            try assertEqual(PathFormatter.string(for: [dir], format: .fileURL, home: home),
                            "file:///Users/me/%E9%A1%B9%E7%9B%AE/", "目录 URL 以 / 结尾，中文按 UTF-8 编码")
        }

        runTest("PathFormatter ~ 只替换主目录前缀") {
            let home = "/Users/me"
            try assertEqual(PathFormatter.string(for: [URL(fileURLWithPath: "/Users/me")], format: .tilde, home: home), "~")
            try assertEqual(PathFormatter.string(for: [URL(fileURLWithPath: "/Users/meow/x")], format: .tilde, home: home),
                            "/Users/meow/x", "同前缀的其他用户目录不能被替换")
            try assertEqual(PathFormatter.string(for: [URL(fileURLWithPath: "/Volumes/E/x")], format: .tilde, home: home), "/Volumes/E/x")
            try assertEqual(PathFormatter.string(for: [URL(fileURLWithPath: "/Users/me/x")], format: .tilde, home: "/Users/me/"), "~/x",
                            "主目录带结尾斜杠也能识别")
        }

        runTest("PathFormatter 多选的连接方式") {
            let urls = [URL(fileURLWithPath: "/tmp/a"), URL(fileURLWithPath: "/tmp/b c")]
            try assertEqual(PathFormatter.string(for: urls, format: .absolute, home: "/Users/me"), "/tmp/a\n/tmp/b c", "默认每行一项")
            try assertEqual(PathFormatter.string(for: urls, format: .shellEscaped, home: "/Users/me"), "/tmp/a '/tmp/b c'",
                            "终端格式以空格连接，安全路径不加引号")
        }

        runTest("PathFormatter.shellQuoted 处理单引号与特殊字符") {
            try assertEqual(PathFormatter.shellQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
            try assertEqual(PathFormatter.shellQuoted("/tmp/$HOME"), "'/tmp/$HOME'", "$ 必须被引起来，防止展开")
            try assertEqual(PathFormatter.shellQuoted("/tmp/中文"), "'/tmp/中文'", "非 ASCII 一律加引号")
            try assertEqual(PathFormatter.shellQuoted(""), "''")
        }

        runTest("复制文件名保留完整名称，多选每行一项") {
            let urls = [
                URL(fileURLWithPath: "/tmp/中文 报告.tar.gz"),
                URL(fileURLWithPath: "/tmp/.gitignore"),
                URL(fileURLWithPath: "/tmp/无扩展名"),
                URL(fileURLWithPath: "/tmp/项目 文件夹", isDirectory: true),
            ]
            try assertEqual(PathFormatter.string(for: urls, format: .name, home: "/Users/me"),
                            "中文 报告.tar.gz\n.gitignore\n无扩展名\n项目 文件夹")
            try assertEqual(PathFormatter.string(for: [], format: .name, home: "/Users/me"), "")
        }

        runTest("SharedConfig.copyPathFormat 默认绝对路径并可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertEqual(config.copyPathFormat, .absolute)
            config.copyPathFormat = .tilde
            try assertEqual(SharedConfig(fileURL: url).copyPathFormat, .tilde, "重新读取后保持")
        }

        // MARK: - 菜单顺序

        runTest("normalizedOrder 未保存时等于默认顺序") {
            try assertEqual(MenuFeatureCatalog.normalizedOrder([], defaults: ["a", "b", "c"]), ["a", "b", "c"])
            try assertEqual(MenuFeatureCatalog.ordered(by: []).map(\.id), MenuFeatureCatalog.all.map(\.id))
        }

        runTest("normalizedOrder 保留用户顺序，丢弃未知与重复 id") {
            try assertEqual(MenuFeatureCatalog.normalizedOrder(["c", "x", "a", "c", "b"], defaults: ["a", "b", "c"]), ["c", "a", "b"])
        }

        runTest("normalizedOrder 新增功能插在默认顺序中的前一项之后") {
            // 用户把 c 调到最前；新版本在 a 与 b 之间新增 n、在开头新增 z
            try assertEqual(MenuFeatureCatalog.normalizedOrder(["c", "a", "b"], defaults: ["z", "a", "n", "b", "c"]),
                            ["z", "c", "a", "n", "b"])
        }

        runTest("复制文件名默认开启，升级保留菜单顺序并支持关闭") {
            let oldSaved = [MenuFeatureCatalog.toggleHidden] + MenuFeatureCatalog.all.map(\.id).filter {
                $0 != MenuFeatureCatalog.copyFileName && $0 != MenuFeatureCatalog.toggleHidden
            }
            let ids = MenuFeatureCatalog.ordered(by: oldSaved).map(\.id)
            let copyPath = ids.firstIndex(of: MenuFeatureCatalog.copyPath)!
            try assertEqual(ids[copyPath + 1], MenuFeatureCatalog.copyFileName)
            try assertEqual(ids.filter { $0 != MenuFeatureCatalog.copyFileName }, oldSaved)

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.isActionEnabled(MenuFeatureCatalog.copyFileName))
            config.setActionEnabled(MenuFeatureCatalog.copyFileName, enabled: false)
            try assertTrue(!SharedConfig(fileURL: url).isActionEnabled(MenuFeatureCatalog.copyFileName))
        }

        runTest("SharedConfig 压缩 / 解压默认关闭，显式开启后保持开启") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(!config.isActionEnabled(MenuFeatureCatalog.compress))
            try assertTrue(!config.isActionEnabled(MenuFeatureCatalog.decompress))
            try assertTrue(config.isActionEnabled(MenuFeatureCatalog.newFile))
            config.setActionEnabled(MenuFeatureCatalog.compress, enabled: true)
            let reloaded = SharedConfig(fileURL: url)
            try assertTrue(reloaded.isActionEnabled(MenuFeatureCatalog.compress))
            try assertTrue(!reloaded.isActionEnabled(MenuFeatureCatalog.decompress))
        }

        runTest("SharedConfig.menuOrder 默认为空，清空时恢复默认") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.menuOrder.isEmpty)
            config.menuOrder = ["feature.cut", "feature.copyPath"]
            try assertEqual(SharedConfig(fileURL: url).menuOrder, ["feature.cut", "feature.copyPath"])
            config.menuOrder = []
            try assertTrue(SharedConfig(fileURL: url).menuOrder.isEmpty)
        }

        runTest("打开路径接受绝对路径、主目录与目录符号链接") {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let directory = home.appendingPathComponent("中文 目录", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let spaced = home.appendingPathComponent("目录尾部空格 ", isDirectory: true)
            try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
            let link = home.appendingPathComponent("目录链接")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
            func dir(_ input: String) throws -> String {
                guard case .directory(let url) = try DirectoryPath.resolve(input, home: home.path) else {
                    throw TestFailure(message: "应识别为目录：\(input)")
                }
                return url.path
            }
            try assertEqual(try dir(directory.path), directory.path)
            try assertEqual(try dir(spaced.path), spaced.path, "不修剪真实目录名中的空格")
            try assertEqual(try dir("~/中文 目录"), directory.path)
            try assertEqual(try dir("~"), home.path)
            try assertEqual(try dir(link.path), link.path)
            try assertEqual(try dir("/"), "/", "允许前往主目录以外的目录")
        }

        runTest("打开路径把文件识别为文件，并清理复制来的引号、空白、file URL 与转义") {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let folder = home.appendingPathComponent("项目 A", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("报告 (终版).txt")
            try Data().write(to: file)
            let encoded = URL(fileURLWithPath: file.path).absoluteString
            let inputs = [
                file.path,
                "  \(file.path)\n",
                "'\(file.path)'",
                "\"\(file.path)\"",
                "“\(file.path)”",
                encoded,
                " \(encoded) ",
                file.path.replacingOccurrences(of: " ", with: "\\ ")
                    .replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)"),
                "~/项目 A/报告 (终版).txt",
                "\"~/项目 A/报告 (终版).txt\"",
            ]
            for input in inputs {
                guard case .file(let url) = try DirectoryPath.resolve(input, home: home.path) else {
                    throw TestFailure(message: "应识别为文件：\(input)")
                }
                try assertEqual(url.path, file.path, "输入：\(input)")
            }
            guard case .directory(let url) = try DirectoryPath.resolve("'\(folder.path)/'\n", home: home.path) else {
                throw TestFailure(message: "带引号的目录应识别为目录")
            }
            try assertEqual(url.standardizedFileURL.path, folder.path)
        }

        runTest("打开路径拒绝相对路径、空输入与不存在的路径") {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let cases: [(String, DirectoryPath.ValidationError)] = [
                ("", .invalidPath), ("   ", .invalidPath), ("''", .invalidPath),
                ("Documents", .invalidPath), ("~other/Documents", .invalidPath),
                ("https://example.com/a", .invalidPath),
                (home.path + "\0ignored", .invalidPath),
                (home.appendingPathComponent("missing").path, .unavailable),
                ("'\(home.appendingPathComponent("missing").path)'", .unavailable),
            ]
            for (input, expected) in cases {
                do {
                    _ = try DirectoryPath.resolve(input, home: home.path)
                    throw TestFailure(message: "应拒绝输入：\(input)")
                } catch let error as DirectoryPath.ValidationError {
                    try assertEqual(error, expected, "输入：\(input)")
                }
            }
        }

        runTest("常用目录只接受目录，普通文件报不是目录") {
            let home = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let file = home.appendingPathComponent("报告.txt")
            try Data().write(to: file)
            try assertEqual(try DirectoryPath.url(for: home.path, home: home.path).path, home.path)
            do {
                _ = try DirectoryPath.url(for: file.path, home: home.path)
                throw TestFailure(message: "应拒绝普通文件")
            } catch let error as DirectoryPath.ValidationError {
                try assertEqual(error, .notDirectory)
            }
        }

        runTest("前往目录升级后默认显示并保留原菜单顺序") {
            let oldSaved = MenuFeatureCatalog.regular.map(\.id).filter { $0 != MenuFeatureCatalog.goToDirectory }.reversed()
            let ids = MenuFeatureCatalog.ordered(by: Array(oldSaved)).map(\.id)
            let predId = MenuFeatureCatalog.all[MenuFeatureCatalog.all.firstIndex(where: { $0.id == MenuFeatureCatalog.goToDirectory })! - 1].id
            let predIndex = ids.firstIndex(of: predId)!
            try assertEqual(ids[predIndex + 1], MenuFeatureCatalog.goToDirectory)
            try assertEqual(ids.filter { $0 != MenuFeatureCatalog.goToDirectory && !MenuFeatureCatalog.developerFeatureIds.contains($0) }, Array(oldSaved))

            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.isActionEnabled(MenuFeatureCatalog.goToDirectory))
            config.setActionEnabled(MenuFeatureCatalog.goToDirectory, enabled: false)
            try assertTrue(!SharedConfig(fileURL: url).isActionEnabled(MenuFeatureCatalog.goToDirectory))
        }

        // MARK: - 常用目录：移动到 / 复制到

        runTest("升级前保存的顺序：新增的移动到/复制到出现在粘贴之后") {
            let oldSaved = ["feature.toggleHidden", "feature.newFile", "feature.copyPath", "feature.openTerminal",
                            "feature.openEditor", "feature.cut", "feature.paste", "feature.compress", "feature.decompress"]
            let ids = MenuFeatureCatalog.ordered(by: oldSaved).map(\.id)
            // 显示大小是状态行，默认固定在菜单最前；撤销紧随其后
            try assertEqual(ids.first, MenuFeatureCatalog.diskUsage, "显示大小默认放最前")
            try assertEqual(ids[1], MenuFeatureCatalog.undo, "新增的撤销没有前一项，排在显示大小之后")
            try assertEqual(ids[2], "feature.toggleHidden", "用户的自定义顺序保持不变")
            let paste = ids.firstIndex(of: "feature.paste")!
            try assertEqual(Array(ids[paste...paste + 2]), ["feature.paste", "feature.moveTo", "feature.copyTo"])
        }

        runTest("常用目录按最近使用排序：用过的倒序在前，没用过的保持手动顺序") {
            let paths = ["/a", "/b", "/c", "/d"]
            let used = ["/c": 100.0, "/a": 200.0, "/gone": 999.0]
            try assertEqual(FavoriteDirectories.ordered(paths, lastUsed: used, byRecent: true), ["/a", "/c", "/b", "/d"])
            try assertEqual(FavoriteDirectories.ordered(paths, lastUsed: used, byRecent: false), paths, "关闭时就是手动顺序")
            try assertEqual(FavoriteDirectories.ordered(paths, lastUsed: [:], byRecent: true), paths, "都没用过时不变")
            try assertEqual(FavoriteDirectories.ordered(paths, lastUsed: ["/b": 1, "/d": 1], byRecent: true),
                            ["/b", "/d", "/a", "/c"], "同一时间按手动顺序")
        }

        runTest("常用目录使用记录：默认按最近使用排序，记录时丢掉已移除的目录") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let config = SharedConfig(fileURL: dir.appendingPathComponent("settings.plist"))
            try assertTrue(config.favoriteSortByRecent, "默认开启")
            config.favoriteDirectories = ["/a", "/b"]
            config.favoriteLastUsed = ["/removed": 1]
            config.markFavoriteUsed("/b", at: Date(timeIntervalSince1970: 50))
            try assertEqual(config.favoriteLastUsed, ["/b": 50])
            try assertEqual(config.orderedFavoriteDirectories, ["/b", "/a"])
            config.favoriteSortByRecent = false
            try assertEqual(config.orderedFavoriteDirectories, ["/a", "/b"])
            try assertEqual(SharedConfig(fileURL: dir.appendingPathComponent("settings.plist")).favoriteLastUsed, ["/b": 50], "写入磁盘")
        }

        runTest("FavoriteDirectories 显示名：重名时附上级路径") {
            let names = FavoriteDirectories.displayNames(
                for: ["/Users/me/Downloads", "/Volumes/E/Downloads", "/Users/me/项目"], home: "/Users/me")
            try assertEqual(names, ["Downloads — ~", "Downloads — /Volumes/E", "项目"])
            try assertEqual(FavoriteDirectories.displayNames(for: ["/"], home: "/Users/me"), ["/"], "根目录显示为 /")
        }

        runTest("常用目录可用性：失效目录置灰，恢复后重新可用") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let missing = dir.appendingPathComponent("missing")
            let file = dir.appendingPathComponent("file")
            let link = dir.appendingPathComponent("link")
            let dangling = dir.appendingPathComponent("dangling")
            try Data().write(to: file)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
            try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
            let paths = [dir.path, missing.path, file.path, link.path, dangling.path]
            let cache = FavoriteDirectoryAvailability()
            func waitFor(_ expected: Set<String>, now: TimeInterval) throws {
                let deadline = Date().addingTimeInterval(2)
                while cache.unavailablePaths(in: paths, now: now) != expected {
                    guard Date() < deadline else { throw TestFailure(message: "目录可用性未按预期更新") }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
            try waitFor([missing.path, file.path, dangling.path], now: 0)
            try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            try waitFor([], now: 5)
            try FileManager.default.removeItem(at: missing)
            try waitFor([missing.path, dangling.path], now: 10)
        }

        runTest("常用目录可用性：慢目录不阻塞快照或其他目录，权限不明不误禁用") {
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let lock = NSLock()
            var calls: [String: Int] = [:]
            let cache = FavoriteDirectoryAvailability { path in
                lock.lock()
                calls[path, default: 0] += 1
                lock.unlock()
                if path == "slow" {
                    _ = release.wait(timeout: .now() + 3)
                    return true
                }
                return path == "missing" ? false : nil
            }
            let paths = ["slow", "missing", "denied"]
            let deadline = Date().addingTimeInterval(2)
            while true {
                let unavailable = cache.unavailablePaths(in: paths, now: 0)
                lock.lock()
                let started = calls.count == 3
                let slowCalls = calls["slow"]
                lock.unlock()
                if started, unavailable == ["missing"] {
                    try assertEqual(slowCalls, 1, "在途检查不重复派发")
                    break
                }
                guard Date() < deadline else { throw TestFailure(message: "慢目录阻塞了其他目录或快照") }
                Thread.sleep(forTimeInterval: 0.001)
            }
            try assertEqual(cache.unavailablePaths(in: [], now: 1), [], "移除配置后不保留失效标记")
        }

        runTest("常用目录输入框：兼容复制路径的各种格式") {
            let home = "/Users/me"
            let a = URL(fileURLWithPath: "/Users/me/a b"), b = URL(fileURLWithPath: "/Users/me/it's")
            for format in CopyPathFormat.allCases where format != .name {
                let copied = PathFormatter.string(for: [a, b], format: format, home: home)
                let parsed = FavoriteDirectories.candidatePaths(fromInput: copied)
                let expected = format == .tilde ? ["~/a b", "~/it's"] : [a.path, b.path]
                try assertEqual(parsed, expected, "格式 \(format.rawValue) 应能还原")
            }
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "file:///Users/me/%E9%A1%B9%E7%9B%AE/"), ["/Users/me/项目"])
        }

        runTest("常用目录输入框：反斜杠、双引号、空行与不配对引号") {
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "/Users/me/a\\ b"), ["/Users/me/a b"], "终端拖入的反斜杠转义")
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "\"/Users/me/a b\""), ["/Users/me/a b"])
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "  /Users/me/x\r\n\n ~/y \n"), ["/Users/me/x", "~/y "], "去行首空白与空行，保留行尾空格")
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "/Users/me/Bob's"), ["/Users/me/Bob's"], "引号不配对按普通路径处理")
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "/Users/me/a b"), ["/Users/me/a b"], "无引号的空格属于路径本身")
            try assertEqual(FavoriteDirectories.candidatePaths(fromInput: "   \n"), [])
        }

        runTest("FileTransferCheck 拦截放进自身、移动到原目录") {
            try assertEqual(FileTransferCheck.check(source: "/u/a.txt", destinationDirectory: "/u/dst", mode: .move), .ok)
            try assertEqual(FileTransferCheck.check(source: "/u/a.txt", destinationDirectory: "/u", mode: .move), .alreadyInDestination)
            try assertEqual(FileTransferCheck.check(source: "/u/a.txt", destinationDirectory: "/u/", mode: .move), .alreadyInDestination, "目标带结尾斜杠")
            try assertEqual(FileTransferCheck.check(source: "/u/a.txt", destinationDirectory: "/u", mode: .copy), .ok, "复制到原目录允许（生成副本）")
            try assertEqual(FileTransferCheck.check(source: "/u/dir", destinationDirectory: "/u/dir", mode: .copy), .destinationInsideSource)
            try assertEqual(FileTransferCheck.check(source: "/u/dir", destinationDirectory: "/u/dir/sub", mode: .move), .destinationInsideSource)
            try assertEqual(FileTransferCheck.check(source: "/u/dir", destinationDirectory: "/u/dir2", mode: .move), .ok, "同前缀的兄弟目录不算内部")
        }

        runTest("常用目录白名单：系统 /Applications 拒绝，主目录下的 ~/Applications 放行") {
            let home = "/Users/me", tmp = "/private/var/folders/xx/T"
            try assertTrue(!PathAccessPolicy.isAllowed("/Applications", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(!PathAccessPolicy.isAllowed("/Users/Shared", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(PathAccessPolicy.isAllowed("/Users/me/Applications", role: .destination, home: home, temporaryDirectory: tmp))
            try assertTrue(PathAccessPolicy.isAllowed("/Volumes/E/erhu", role: .destination, home: home, temporaryDirectory: tmp))
        }

        runTest("SharedConfig.favoriteDirectories 默认为空并可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.favoriteDirectories.isEmpty)
            config.favoriteDirectories = ["/Users/me/Downloads", "/Volumes/E"]
            try assertEqual(SharedConfig(fileURL: url).favoriteDirectories, ["/Users/me/Downloads", "/Volumes/E"])
        }

        runTest("终端识别：仅接受同一文档声明中的 Shell 角色与脚本或可执行类型") {
            func info(role: String?, types: [String]) -> [String: Any] {
                var document: [String: Any] = ["LSItemContentTypes": types]
                document["CFBundleTypeRole"] = role
                return ["CFBundleDocumentTypes": [document]]
            }
            for type in ["com.apple.terminal.shell-script", "public.shell-script", "public.unix-executable"] {
                try assertTrue(TerminalCatalog.declaresShell(infoDictionary: info(role: "Shell", types: [type])))
                for role in ["Editor", "Viewer", "None", nil] as [String?] {
                    try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: info(role: role, types: [type])))
                }
            }
            try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: info(role: "Shell", types: ["public.folder"])))
            try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: [:]))
            try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: ["CFBundleDocumentTypes": "invalid"]))
            try assertTrue(!TerminalCatalog.declaresShell(infoDictionary: ["CFBundleDocumentTypes": [
                ["CFBundleTypeRole": "Shell", "LSItemContentTypes": ["public.plain-text"]],
                ["CFBundleTypeRole": "Editor", "LSItemContentTypes": ["public.unix-executable"]],
            ]]))
        }

        runTest("终端发现：任意品牌的应用须有 Shell 声明与可执行文件，去重并保留名称") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            func app(_ name: String, id: String, role: String = "Shell", executable: Bool = true) throws -> URL {
                let url = dir.appendingPathComponent("\(name).app")
                let contents = url.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                let info: [String: Any] = [
                    "CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL",
                    "CFBundleExecutable": "terminal", "CFBundleInfoDictionaryVersion": "6.0",
                    "CFBundleDocumentTypes": [["CFBundleTypeRole": role, "LSItemContentTypes": ["public.unix-executable"]]],
                ]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                if executable {
                    let binary = contents.appendingPathComponent("MacOS/terminal")
                    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                }
                return url
            }
            let cmux = try app("cmux", id: "com.cmuxterm.app")
            let unknown = try app("New Terminal", id: "org.example.new-terminal")
            let editor = try app("Editor", id: "org.example.editor", role: "Editor")
            let broken = try app("Broken", id: "org.example.broken", executable: false)
            let found = TerminalCatalog.installed(applicationURLs: [cmux, unknown, editor, broken, cmux, dir])
            try assertEqual(found.map(\.bundleIdentifier), ["com.cmuxterm.app", "org.example.new-terminal"])
            try assertEqual(found.first?.name, "cmux")
            try assertEqual(TerminalCatalog.menuTerminals(available: found, selected: ["com.cmuxterm.app"],
                                                        preferred: "com.cmuxterm.app").first?.name, "cmux")
            try assertNil(TerminalCatalog.terminal(at: editor))
            try assertNil(TerminalCatalog.terminal(at: broken))
        }

        runTest("终端菜单：单选、多选、卸载回退与全部关闭") {
            let terminal = "com.apple.Terminal"
            let ghostty = "com.mitchellh.ghostty"
            let available = [terminal, ghostty, "com.example.Terminal"].map {
                KnownTerminal(id: $0, name: $0, bundleIdentifier: $0)
            }
            func ids(_ selected: Set<String>, preferred: String = "com.apple.Terminal") -> [String] {
                TerminalCatalog.menuTerminals(available: available, selected: selected, preferred: preferred)
                    .map(\.bundleIdentifier)
            }
            try assertEqual(ids([ghostty]), [ghostty])
            try assertEqual(ids([ghostty, terminal]), [terminal, ghostty])
            try assertEqual(ids(["removed"], preferred: ghostty), [ghostty])
            try assertEqual(ids(["removed"], preferred: "removed"), [terminal])
            try assertEqual(ids(["com.example.Terminal"]), ["com.example.Terminal"])
            try assertTrue(ids([]).isEmpty, "全部关闭时不显示入口")
            try assertTrue(TerminalCatalog.menuTerminals(available: [], selected: [terminal], preferred: terminal).isEmpty)
        }

        runTest("终端排序：设置与菜单顺序一致，忽略重复和失效项") {
            let terminal = "com.apple.Terminal"
            let ghostty = "com.mitchellh.ghostty"
            let iterm = "com.googlecode.iterm2"
            let order = [ghostty, "removed", ghostty, terminal]
            let available = [terminal, ghostty, iterm].map { KnownTerminal(id: $0, name: $0, bundleIdentifier: $0) }
            try assertEqual(TerminalCatalog.ordered(available, by: order).map(\.bundleIdentifier),
                            [ghostty, terminal, iterm])
            try assertEqual(TerminalCatalog.ordered(available, by: []).map(\.bundleIdentifier),
                            available.map(\.bundleIdentifier))
            let menu = TerminalCatalog.menuTerminals(available: available, selected: [terminal, ghostty],
                                                     preferred: terminal, order: order)
            try assertEqual(menu.map(\.bundleIdentifier), [ghostty, terminal])
        }

        runTest("终端偏好：兼容旧单选、多选与空选择持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertTrue(config.followsSystemTerminal)
            try assertEqual(config.selectedTerminals, [config.preferredTerminal])
            try assertTrue(config.terminalOrder.isEmpty)
            config.preferredTerminal = "com.mitchellh.ghostty"
            try assertTrue(!config.followsSystemTerminal)
            try assertEqual(SharedConfig(fileURL: url).selectedTerminals, ["com.mitchellh.ghostty"])
            config.selectedTerminals = ["com.apple.Terminal", "com.mitchellh.ghostty"]
            config.terminalOrder = ["com.mitchellh.ghostty", "com.apple.Terminal"]
            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.selectedTerminals, config.selectedTerminals)
            try assertEqual(reloaded.terminalOrder, config.terminalOrder)
            try assertEqual(reloaded.preferredTerminal, "com.mitchellh.ghostty")
            reloaded.selectedTerminals = []
            try assertTrue(SharedConfig(fileURL: url).selectedTerminals.isEmpty)
            reloaded.preferredTerminal = ""
            reloaded.resetTerminalMenuToDefault()
            let following = SharedConfig(fileURL: url)
            try assertTrue(following.followsSystemTerminal)
            try assertEqual(following.preferredTerminal, TerminalCatalog.defaultTerminalBundleIdentifier())
            try assertEqual(following.selectedTerminals, [following.preferredTerminal])
            try assertEqual(following.terminalOrder, config.terminalOrder)
        }

        runTest("编辑器识别：要求同一文档中的 Editor 与文本类型，兼容通配符和旧文本类型") {
            func doc(_ role: String?, exts: [String] = [], types: [String] = [], osTypes: [String] = []) -> [String: Any] {
                var d: [String: Any] = ["CFBundleTypeExtensions": exts, "LSItemContentTypes": types, "CFBundleTypeOSTypes": osTypes]
                if let role { d["CFBundleTypeRole"] = role }
                return d
            }
            func check(_ docs: [[String: Any]]) -> Bool {
                EditorCatalog.declaresEditing(infoDictionary: ["CFBundleDocumentTypes": docs])
            }
            try assertTrue(check([doc("Editor", exts: ["PY"])]), "代码扩展名大小写不敏感")
            try assertTrue(check([doc("Editor", types: ["public.swift-source"])]))
            try assertTrue(check([doc("Editor", types: ["public.plain-text"])]), "文本编辑器")
            try assertTrue(check([doc("Editor", types: ["public.source-code"])]))
            try assertTrue(check([doc("Editor", exts: ["*"])]), "JetBrains 通配符")
            try assertTrue(check([doc("Editor", osTypes: ["TEXT"])]), "旧式文本类型")
            for role in ["Viewer", "Shell", "None", nil] as [String?] {
                try assertTrue(!check([doc(role, exts: ["txt", "*"])]), "角色必须明确为 Editor")
            }
            for type in ["public.image", "com.adobe.pdf", "public.folder", "public.data"] {
                try assertTrue(!check([doc("Editor", types: [type])]), "只编辑图片等非文本内容的应用不算")
            }
            try assertTrue(!check([doc("Viewer", types: ["public.text"]), doc("Editor", types: ["public.image"])]),
                           "角色和文本类型不能跨条目拼接")
            try assertTrue(!check([doc("Editor", exts: ["*"], types: ["public.image"])]),
                           "现代 UTI 声明优先于旧扩展名")
            try assertTrue(!check([doc("Editor", types: ["public.text"]), doc("Shell", types: ["public.unix-executable"])]),
                           "终端不混入编辑器")
            try assertTrue(!EditorCatalog.declaresEditing(infoDictionary: [:]))
            try assertTrue(!EditorCatalog.declaresEditing(infoDictionary: ["CFBundleURLTypes": [doc("Editor", exts: ["txt"])]]),
                           "URL 协议的 Editor 角色不代表文件编辑能力")
        }

        runTest("编辑器自动推荐：要求明确的通用编辑声明，专用格式保留手动添加") {
            func document(_ types: [String] = [], extensions: [String] = [], role: String = "Editor") -> [String: Any] {
                ["CFBundleTypeRole": role, "LSItemContentTypes": types, "CFBundleTypeExtensions": extensions]
            }
            func check(_ documents: [[String: Any]]) -> Bool {
                EditorCatalog.declaresGeneralEditing(infoDictionary: ["CFBundleDocumentTypes": documents])
            }
            for type in ["public.text", "public.plain-text", "public.source-code", "public.utf8-plain-text"] {
                try assertTrue(check([document([type])]))
            }
            for ext in ["TXT", "text", "*"] { try assertTrue(check([document(extensions: [ext])])) }
            try assertTrue(check([["CFBundleTypeRole": "Editor", "CFBundleTypeOSTypes": ["TEXT"]]]))
            for type in ["public.comma-separated-values-text", "net.daringfireball.markdown", "public.python-script", "public.json", "public.image"] {
                try assertTrue(!check([document([type])]), "文本子类型不等于通用文本声明")
            }
            for ext in ["md", "sql", "csv", "py", "json"] {
                let info: [String: Any] = ["CFBundleDocumentTypes": [document(extensions: [ext])]]
                // md、sql 的类型可能由已安装应用注册，不能假定干净系统已将它们识别为文本。
                if ["csv", "py", "json"].contains(ext) {
                    try assertTrue(EditorCatalog.declaresEditing(infoDictionary: info), "系统内建文本类型仍可手动添加：\(ext)")
                }
                try assertTrue(!EditorCatalog.declaresGeneralEditing(infoDictionary: info), "专用格式不自动推荐：\(ext)")
            }
            try assertTrue(!check([document(["public.text"], role: "Viewer"), document(["public.image"])]))
            try assertTrue(!check([document(["public.image"], extensions: ["txt", "*"])]), "UTI 声明优先")
        }

        runTest("编辑器发现：通用编辑器自动显示，手动项与系统默认仍须通过基础校验") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            func app(_ name: String, id: String, role: String?, types: [String] = ["public.plain-text"], executable: Bool = true) throws -> URL {
                let url = dir.appendingPathComponent("\(name).app")
                let contents = url.appendingPathComponent("Contents")
                try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
                var info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundlePackageType": "APPL",
                                           "CFBundleExecutable": "editor", "CFBundleInfoDictionaryVersion": "6.0"]
                if let role {
                    info["CFBundleDocumentTypes"] = [["CFBundleTypeRole": role, "LSItemContentTypes": types]]
                }
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                if executable {
                    let binary = contents.appendingPathComponent("MacOS/editor")
                    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                }
                return url
            }
            let ide = try app("Antigravity IDE", id: "com.google.antigravity-ide", role: "Editor")
            let agent = try app("Antigravity", id: "com.google.antigravity", role: nil)
            let unknown = try app("New Editor", id: "org.example.new-editor", role: "Editor")
            let viewer = try app("Viewer", id: "org.example.viewer", role: "Viewer")
            let broken = try app("Broken", id: "org.example.broken", role: "Editor", executable: false)
            let oldBrand = try app("Zed without declarations", id: "dev.zed.Zed", role: nil)
            let specific = try app("Python IDE", id: "org.example.python", role: "Editor", types: ["public.python-script"])
            let urls = [ide, agent, unknown, viewer, broken, oldBrand, specific, ide, dir]
            let available = EditorCatalog.installed(applicationURLs: urls)
            try assertEqual(available.map(\.id), ["com.google.antigravity-ide", "org.example.new-editor"])
            try assertEqual(available.first?.name, "Antigravity IDE")
            try assertNil(EditorCatalog.editor(at: agent))
            try assertNil(EditorCatalog.editor(at: broken))
            try assertNil(EditorCatalog.editor(at: oldBrand))
            try assertTrue(EditorCatalog.editor(at: specific) != nil, "专用编辑器可手动添加")
            let explicit = EditorCatalog.installed(applicationURLs: urls, including: ["org.example.python", "com.google.antigravity", "dev.zed.Zed"])
            try assertEqual(Set(explicit.map(\.id)), ["com.google.antigravity-ide", "org.example.new-editor", "org.example.python"],
                           "手动项或系统默认可放宽通用要求，但不能绕过基础编辑能力校验")
        }

        runTest("编辑器菜单：保持保存的排序和显示开关，去掉重复与失效顺序项") {
            let available = [KnownEditor(id: "org.example.alpha", name: "Alpha"), KnownEditor(id: "org.example.beta", name: "Beta")]
            let order = ["org.example.beta", "removed", "org.example.beta", "org.example.alpha"]
            try assertEqual(EditorCatalog.ordered(available, by: order).map(\.id), ["org.example.beta", "org.example.alpha"])
            let menu = EditorCatalog.menuEditors(available: available, hidden: ["org.example.alpha"], order: order)
            try assertEqual(menu.map(\.id), ["org.example.beta"])
            try assertTrue(EditorCatalog.menuEditors(available: available, hidden: Set(available.map(\.id))).isEmpty)
        }

        runTest("编辑器默认：跟随系统且只使用通过校验的应用，不受菜单可见性影响") {
            let valid: Set<String> = ["org.example.Editor", "org.example.SystemEditor", "org.example.NewSystemEditor"]
            func resolve(_ preferred: String?, systemDefault: String = "org.example.SystemEditor") -> String {
                EditorCatalog.resolvedDefault(preferred: preferred, systemDefault: systemDefault, isInstalled: valid.contains)
            }
            try assertEqual(resolve("org.example.Editor"), "org.example.Editor")
            try assertEqual(resolve(nil), "org.example.SystemEditor")
            try assertEqual(resolve(""), "org.example.SystemEditor")
            try assertEqual(resolve("com.google.antigravity"), "org.example.SystemEditor", "旧无效偏好回退")
            try assertEqual(resolve(nil, systemDefault: "org.example.NewSystemEditor"), "org.example.NewSystemEditor")
            try assertEqual(resolve(nil, systemDefault: "org.example.Viewer"), EditorCatalog.textEditBundleId,
                            "系统关联若没有编辑能力则回退到文本编辑")
        }

        runTest("EditorDiscovery 只推荐常规安装位置") {
            let home = "/Users/me"
            try assertTrue(EditorDiscovery.isStandardInstallLocation("/Applications/Zed.app", home: home))
            try assertTrue(EditorDiscovery.isStandardInstallLocation("/Applications/Utilities/X.app", home: home))
            try assertTrue(EditorDiscovery.isStandardInstallLocation("/Users/me/Applications/JetBrains Toolbox/PyCharm.app", home: home))
            try assertTrue(!EditorDiscovery.isStandardInstallLocation("/Applications/Doubao.app/Contents/Helpers/Browser.app", home: home), "内嵌 Helper")
            try assertTrue(!EditorDiscovery.isStandardInstallLocation("/Volumes/MarkEdit/MarkEdit.app", home: home), "挂载的 DMG")
            try assertTrue(!EditorDiscovery.isStandardInstallLocation("/Users/me/.cache/x/Chromium.app", home: home))
        }

        runTest("EditorDiscovery 图标来源优先常规安装位置副本") {
            let home = "/Users/me"
            let buildProduct = URL(fileURLWithPath: "/Users/me/codes/work/_build/Debug/Inkpot.app")
            let installed = URL(fileURLWithPath: "/Applications/Inkpot.app")
            let toolbox = URL(fileURLWithPath: "/Users/me/Applications/JetBrains Toolbox/PyCharm.app")
            try assertEqual(EditorDiscovery.preferredCopy(among: [buildProduct, installed], fallback: buildProduct, home: home), installed)
            try assertEqual(EditorDiscovery.preferredCopy(among: [buildProduct, toolbox], fallback: buildProduct, home: home), toolbox)
            try assertEqual(EditorDiscovery.preferredCopy(among: [buildProduct], fallback: buildProduct, home: home), buildProduct,
                            "没有常规副本时退回 LaunchServices 解析结果")
            try assertNil(EditorDiscovery.preferredCopy(among: [], fallback: nil, home: home))
        }

        runTest("SharedConfig 编辑器偏好：默认跟随系统、手动项与隐藏项可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            try assertNil(config.preferredEditor)
            try assertTrue(config.customEditors.isEmpty)
            try assertTrue(config.hiddenEditors.isEmpty)
            try assertTrue(config.editorOrder.isEmpty)

            config.preferredEditor = "dev.zed.Zed"
            config.customEditors = [KnownEditor(id: "com.example.Foo", name: "Foo")]
            config.hiddenEditors = ["com.apple.dt.Xcode"]
            config.editorOrder = ["com.example.Foo", "dev.zed.Zed"]
            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.preferredEditor, "dev.zed.Zed")
            try assertEqual(reloaded.customEditors, [KnownEditor(id: "com.example.Foo", name: "Foo")])
            try assertEqual(reloaded.hiddenEditors, ["com.apple.dt.Xcode"])
            try assertEqual(reloaded.editorOrder, config.editorOrder)

            reloaded.preferredEditor = ""
            try assertNil(SharedConfig(fileURL: url).preferredEditor, "空串恢复跟随系统")
        }

        runTest("SharedConfig 主题色偏好：默认午夜薄荷且可持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")

            let config = SharedConfig(fileURL: url)
            try assertEqual(config.appTheme, .midnight, "默认主题应为午夜薄荷")
            try assertNil(config.appThemeValue, "未显式设置时存储应为 nil")

            config.appTheme = .sunset
            try assertEqual(config.appThemeValue, .sunset)

            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.appTheme, .sunset, "重载后应保持落日橙主题")
        }

        runTest("AppLanguage 切换重启判定") {
            let available = ["zh-Hans", "en"]
            let zhSystem = ["zh-Hans-CN"]
            let enSystem = ["en-US"]

            // 跟随系统（中文）与固定中文互切：实际显示语言不变，不重启
            try assertTrue(
                !AppLanguage.requiresRelaunch(
                    currentLocalization: "zh-Hans",
                    target: "zh-Hans",
                    availableLocalizations: available,
                    systemPreferredLanguages: zhSystem
                ),
                "跟随系统为中文时切换到中文不应重启"
            )
            try assertTrue(
                !AppLanguage.requiresRelaunch(
                    currentLocalization: "zh-Hans",
                    target: "system",
                    availableLocalizations: available,
                    systemPreferredLanguages: zhSystem
                ),
                "固定中文切回中文系统下跟随系统不应重启"
            )

            // 中文与英文之间切换：实际显示语言变化，需要重启
            try assertTrue(
                AppLanguage.requiresRelaunch(
                    currentLocalization: "zh-Hans",
                    target: "en",
                    availableLocalizations: available,
                    systemPreferredLanguages: zhSystem
                ),
                "当前为中文时切换到英文应重启"
            )
            try assertTrue(
                AppLanguage.requiresRelaunch(
                    currentLocalization: "en",
                    target: "system",
                    availableLocalizations: available,
                    systemPreferredLanguages: zhSystem
                ),
                "当前为英文切回中文系统下跟随系统应重启"
            )

            // 跟随系统（英文）下的切换
            try assertTrue(
                !AppLanguage.requiresRelaunch(
                    currentLocalization: "en",
                    target: "en",
                    availableLocalizations: available,
                    systemPreferredLanguages: enSystem
                ),
                "跟随系统为英文时切换到英文不应重启"
            )
            try assertTrue(
                AppLanguage.requiresRelaunch(
                    currentLocalization: "en",
                    target: "zh-Hans",
                    availableLocalizations: available,
                    systemPreferredLanguages: enSystem
                ),
                "跟随系统为英文时切换到中文应重启"
            )
            try assertTrue(
                !AppLanguage.requiresRelaunch(
                    currentLocalization: "en",
                    target: "system",
                    availableLocalizations: available,
                    systemPreferredLanguages: enSystem
                ),
                "固定英文切回英文系统下跟随系统不应重启"
            )

            // 无法判定时保守重启
            try assertTrue(
                AppLanguage.requiresRelaunch(
                    currentLocalization: nil,
                    target: "zh-Hans",
                    availableLocalizations: available,
                    systemPreferredLanguages: zhSystem
                ),
                "当前本地化缺失时应保守重启"
            )
            try assertTrue(
                AppLanguage.requiresRelaunch(
                    currentLocalization: "zh-Hans",
                    target: "system",
                    availableLocalizations: available,
                    systemPreferredLanguages: []
                ),
                "系统偏好语言为空时切回跟随系统应保守重启"
            )
        }

        runTest("FRThemeID 调色板与外观动态解析") {
            let midnight = FRThemeID.midnight.palette
            let lightAppearance = NSAppearance(named: .aqua)
            let darkAppearance = NSAppearance(named: .darkAqua)

            let lightAccent = midnight.accent.resolved(for: lightAppearance)
            let darkAccent = midnight.accent.resolved(for: darkAppearance)
            try assertTrue(lightAccent != darkAccent, "浅色与深色下的 accent 应有区分")

            let lightOnAccent = midnight.onAccent.resolved(for: lightAppearance)
            let darkOnAccent = midnight.onAccent.resolved(for: darkAppearance)
            try assertTrue(lightOnAccent != darkOnAccent, "浅色与深色下的 onAccent 应有区分")

            let terracotta = FRThemeID.terracotta.palette
            try assertTrue(
                terracotta.window.resolved(for: lightAppearance) != terracotta.window.resolved(for: darkAppearance),
                "暖陶主题浅色与深色 window 应有区分"
            )
            try assertTrue(
                terracotta.accent.resolved(for: lightAppearance) != terracotta.accent.resolved(for: darkAppearance),
                "暖陶主题浅色与深色 accent 应有区分"
            )

            // 所有预置主题均应具备有效的标题与色块
            for theme in FRThemeID.allCases {
                try assertTrue(!theme.titleKey.isEmpty)
                try assertTrue(theme.palette.accent.light.alphaComponent > 0)
                try assertTrue(theme.palette.onAccent.light.alphaComponent > 0)
                try assertTrue(theme.palette.switchOffTrack.light.alphaComponent > 0)
                try assertTrue(theme.palette.segmentedTrack.light.alphaComponent > 0)
                try assertTrue(theme.palette.dropdownFill.light.alphaComponent > 0)
            }
        }

        runTest("FileContentReader 资格预检与多格式文本读取") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }

            let textFile = dir.appendingPathComponent("sample.txt")
            let utf8Content = "Hello, 访达右键! 🎉\nSecond Line"
            try utf8Content.data(using: .utf8)!.write(to: textFile)

            let utf16File = dir.appendingPathComponent("utf16.txt")
            try "UTF16 Content".data(using: .utf16)!.write(to: utf16File)

            let emptyFile = dir.appendingPathComponent("empty.txt")
            try Data().write(to: emptyFile)

            let binaryFile = dir.appendingPathComponent("binary.bin")
            var binData = Data([0x48, 0x65, 0x6c, 0x6c, 0x6f]) // "Hello"
            binData.append(0x00) // NUL 字节
            binData.append(contentsOf: [0x57, 0x6f, 0x72, 0x6c, 0x64])
            try binData.write(to: binaryFile)

            let subDir = dir.appendingPathComponent("folder")
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

            let nonExistentFile = dir.appendingPathComponent("missing.txt")

            // 1. 资格预检 isEligible
            let limit: Int64 = 1024 * 1024 // 1 MB
            try assertTrue(FileContentReader.isEligible(url: textFile, maxBytes: limit), "常规文本文件应满足资格")
            try assertTrue(FileContentReader.isEligible(url: emptyFile, maxBytes: limit), "空文件应满足资格")
            try assertTrue(!FileContentReader.isEligible(url: subDir, maxBytes: limit), "目录不应满足资格")
            try assertTrue(!FileContentReader.isEligible(url: nonExistentFile, maxBytes: limit), "不存在的文件不应满足资格")
            try assertTrue(!FileContentReader.isEligible(url: textFile, maxBytes: 5), "超过大小上限时不应满足资格")

            // 2. 文本读取 readText
            // UTF-8
            let readUtf8 = FileContentReader.readText(from: textFile, maxBytes: limit)
            try assertEqual(readUtf8, .success(utf8Content))

            // UTF-16
            let readUtf16 = FileContentReader.readText(from: utf16File, maxBytes: limit)
            try assertEqual(readUtf16, .success("UTF16 Content"))

            // 空文件
            let readEmpty = FileContentReader.readText(from: emptyFile, maxBytes: limit)
            try assertEqual(readEmpty, .success(""))

            // 超大文件
            let readTooLarge = FileContentReader.readText(from: textFile, maxBytes: 5)
            if case .fileTooLarge(let size, let max) = readTooLarge {
                try assertTrue(size > max)
                try assertEqual(max, 5)
            } else {
                throw TestFailure(message: "超过上限应返回 .fileTooLarge")
            }

            // 二进制含 0x00
            let readBin = FileContentReader.readText(from: binaryFile, maxBytes: limit)
            try assertEqual(readBin, .binaryFile, "含 0x00 的文件应被识别为二进制")

            let longText = Data(repeating: 0x61, count: 8193)
            try longText.write(to: binaryFile)
            try assertEqual(FileContentReader.readText(from: binaryFile, maxBytes: limit),
                            .success(String(decoding: longText, as: UTF8.self)), "超过 8KB 的正常文本仍可读取")
            try (longText + Data([0])).write(to: binaryFile)
            try assertEqual(FileContentReader.readText(from: binaryFile, maxBytes: limit),
                            .binaryFile, "8KB 之后的空字符也必须拦截")

            // 目录
            let readDir = FileContentReader.readText(from: subDir, maxBytes: limit)
            try assertEqual(readDir, .notRegularFile, "目录应返回 .notRegularFile")
        }

        runTest("SharedConfig copyFileContentMaxSizeKB 配置与持久化") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")

            let config = SharedConfig(fileURL: url)
            try assertEqual(config.copyFileContentMaxSizeKB, 1024, "默认大小上限应为 1024 KB (1MB)")
            try assertEqual(config.copyFileContentMaxBytes, 1024 * 1024)

            // 调整为 5 MB
            config.copyFileContentMaxSizeKB = 5120
            try assertEqual(config.copyFileContentMaxBytes, 5120 * 1024)

            let reloaded = SharedConfig(fileURL: url)
            try assertEqual(reloaded.copyFileContentMaxSizeKB, 5120, "重载后应保持 5120 KB 设置")
            try assertEqual(reloaded.copyFileContentMaxBytes, 5120 * 1024)
        }

        runTest("MenuFeatureCatalog 包含 copyFileContent 特性") {
            let allIds = MenuFeatureCatalog.all.map(\.id)
            try assertTrue(allIds.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(!MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.copyFileContent), "复制文件内容默认应开启")

            // 验证顺序在 copyFileName 之后
            if let nameIdx = allIds.firstIndex(of: MenuFeatureCatalog.copyFileName),
               let contentIdx = allIds.firstIndex(of: MenuFeatureCatalog.copyFileContent) {
                try assertTrue(contentIdx > nameIdx, "copyFileContent 顺序应在 copyFileName 之后")
            } else {
                throw TestFailure(message: "功能列表中未找到 copyFileName 或 copyFileContent")
            }
        }

        runTest("打开路径全局快捷键：升级默认关闭、独立持久化且不改已有组合") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appendingPathComponent("settings.plist")
            let config = SharedConfig(fileURL: url)
            let shortcut = ActionShortcut(key: "g", modifiers: (1 << 20) | (1 << 17))
            config.setShortcut(shortcut, forActionId: FinderKeyTakeover.goToDirectoryActionId)
            try assertTrue(!SharedConfig(fileURL: url).globalOpenPathShortcut, "已有快捷键升级后也不扩大作用范围")
            config.globalOpenPathShortcut = true
            let reloaded = SharedConfig(fileURL: url)
            try assertTrue(reloaded.globalOpenPathShortcut)
            try assertEqual(reloaded.shortcut(forActionId: FinderKeyTakeover.goToDirectoryActionId), shortcut)
            config.globalOpenPathShortcut = false
            try assertTrue(!SharedConfig(fileURL: url).globalOpenPathShortcut)
            config.globalOpenPathShortcut = true
            config.resetToDefaults()
            try assertTrue(!SharedConfig(fileURL: url).globalOpenPathShortcut, "恢复默认后关闭")
        }
    }
}
