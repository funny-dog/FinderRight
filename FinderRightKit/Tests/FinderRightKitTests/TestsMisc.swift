import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// 哈希、更新与历史展示
enum MiscTests {
    static func run() {
        // MARK: - 复制哈希 / 创建符号链接

        runTest("复制哈希：三种算法与已知摘要一致，跨块读取结果不变") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent("abc.txt")
            try Data("abc".utf8).write(to: file)
            try assertEqual(FileHasher.hexDigest(of: file, algorithm: .sha256),
                            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            try assertEqual(FileHasher.hexDigest(of: file, algorithm: .sha1), "a9993e364706816aba3e25717850c26c9cd0d89d")
            try assertEqual(FileHasher.hexDigest(of: file, algorithm: .md5), "900150983cd24fb0d6963f7d28e17f72")

            let empty = dir.appendingPathComponent("empty")
            try Data().write(to: empty)
            try assertEqual(FileHasher.hexDigest(of: empty, algorithm: .md5), "d41d8cd98f00b204e9800998ecf8427e", "空文件")

            // 超过一块（1 MiB）的文件：与一次性计算的结果一致
            let big = dir.appendingPathComponent("big.bin")
            let bytes = Data((0..<(3 << 20) + 7).map { UInt8($0 % 251) })
            try bytes.write(to: big)
            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try assertEqual(FileHasher.hexDigest(of: big, algorithm: .sha256), expected)
            try assertEqual(try FileHasher.hexDigest(reading: big, algorithm: .sha256), expected)
        }

        runTest("复制哈希：文件夹与不存在的文件不计算，取消即中止，符号链接按目标") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            try assertNil(FileHasher.hexDigest(of: dir, algorithm: .sha256), "文件夹")
            try assertNil(FileHasher.hexDigest(of: dir.appendingPathComponent("missing"), algorithm: .sha256))
            do {
                _ = try FileHasher.hexDigest(reading: dir.appendingPathComponent("missing"), algorithm: .sha256)
                throw TestFailure(message: "读取失败应抛出具体文件错误")
            } catch is TestFailure { throw TestFailure(message: "读取失败未抛错") }
            catch { try assertEqual((error as NSError).domain, NSCocoaErrorDomain) }
            let file = dir.appendingPathComponent("a")
            try Data("abc".utf8).write(to: file)
            try assertNil(FileHasher.hexDigest(of: file, algorithm: .sha256, isCancelled: { true }))
            let link = dir.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            try assertTrue(FileHasher.isRegularFile(link))
            try assertEqual(FileHasher.hexDigest(of: link, algorithm: .md5), "900150983cd24fb0d6963f7d28e17f72")
            try assertTrue(!FileHasher.isRegularFile(dir))
        }

        runTest("复制哈希：单个文件只给摘要，多个文件与 shasum 输出一致") {
            try assertEqual(FileHasher.clipboardText([("a.txt", "aa")]), "aa")
            try assertEqual(FileHasher.clipboardText([("a.txt", "aa"), ("b c.txt", "bb")]), "aa  a.txt\nbb  b c.txt")
        }

        runTest("复制哈希与创建符号链接归入开发者工具，常规功能中不包含它们") {
            try assertTrue(MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.createSymlink))
            try assertTrue(MenuFeatureCatalog.developerFeatureIds.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(MenuFeatureCatalog.developerFeatureIds.contains(MenuFeatureCatalog.createSymlink))
            let regularIds = MenuFeatureCatalog.regular.map(\.id)
            try assertTrue(!regularIds.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(!regularIds.contains(MenuFeatureCatalog.createSymlink))
            let devIds = MenuFeatureCatalog.developerFeatureIds
            try assertEqual(Array(devIds.prefix(2)), [MenuFeatureCatalog.copyFileHash, MenuFeatureCatalog.createSymlink])
        }

        runTest("符号链接命名：保留完整文件名，重名自动编号") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("报告.pdf")
            try Data().write(to: source)
            let first = SymlinkNaming.linkURL(for: source, suffix: "链接")
            try assertEqual(first.lastPathComponent, "报告.pdf 链接")
            try FileManager.default.createSymbolicLink(at: first, withDestinationURL: dir.appendingPathComponent("missing"))
            try assertEqual(SymlinkNaming.linkURL(for: source, suffix: "链接").lastPathComponent, "报告.pdf 链接 1",
                            "悬空的同名链接也算占用")
            let folder = dir.appendingPathComponent("src/")
            try assertEqual(SymlinkNaming.linkURL(for: folder, suffix: "link").lastPathComponent, "src link")
        }

        runTest("菜单单一数据源：空白处（container）右键菜单分支") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let templates = [MenuTemplateData(id: "txt", displayName: "纯文本", systemImage: "doc.text", tint: .blue, tag: 0)]
            let terminals = [MenuTerminalData(bundleIdentifier: "com.apple.Terminal", name: "终端", icon: nil, tag: 0)]
            let input = MenuBuildInput(
                location: .container,
                selection: .empty,
                enabledFeatureIds: allFeatures,
                newFileTemplates: templates,
                terminals: terminals
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            let ids = nodes.map(\.id)

            // 空白处应该有新建文件、打开路径、终端、切换隐藏文件；无剪切队列时不显示灰色粘贴
            try assertTrue(ids.contains(MenuFeatureCatalog.newFile))
            try assertTrue(ids.contains(MenuFeatureCatalog.goToDirectory))
            try assertTrue(ids.contains(MenuFeatureCatalog.openTerminal))
            try assertTrue(ids.contains(MenuFeatureCatalog.toggleHidden))
            try assertTrue(ids.contains(MenuFeatureCatalog.lineCount))
            try assertTrue(!ids.contains(MenuFeatureCatalog.paste))
            try assertTrue(!ids.contains(MenuFeatureCatalog.compareFiles))

            // 不应有依赖选中项的操作
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyPath))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileName))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(!ids.contains(MenuFeatureCatalog.cut))
            try assertTrue(!ids.contains(MenuFeatureCatalog.moveTo))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyTo))
            try assertTrue(!ids.contains(MenuFeatureCatalog.createSymlink))
            try assertTrue(!ids.contains(MenuFeatureCatalog.compress))
            try assertTrue(!ids.contains(MenuFeatureCatalog.decompress))
        }

        runTest("菜单单一数据源：侧边栏（sidebar）仅展示容器级操作，不混入选中项动作") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let templates = [MenuTemplateData(id: "txt", displayName: "纯文本", systemImage: "doc.text", tint: .blue, tag: 0)]
            let terminals = [MenuTerminalData(bundleIdentifier: "com.apple.Terminal", name: "终端", icon: nil, tag: 0)]
            let editors = [MenuEditorData(bundleIdentifier: "com.microsoft.VSCode", name: "VS Code", icon: nil, tag: 0)]
            let favs = [MenuFavoriteData(path: "/Users/test/Downloads", displayName: "下载", isUnavailable: false, canTransfer: true, tag: 0)]
            // 即便主窗口当前有选中文件/文件夹，侧边栏右键也只按容器展示
            let input = MenuBuildInput(
                location: .sidebar,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures,
                newFileTemplates: templates,
                terminals: terminals,
                editors: editors,
                favoriteDirectories: favs
            )
            let ids = MenuTreeBuilder.buildMenuTree(input: input).map(\.id)

            try assertTrue(ids.contains(MenuFeatureCatalog.newFile))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyPath))
            try assertTrue(ids.contains(MenuFeatureCatalog.goToDirectory))
            try assertTrue(ids.contains(MenuFeatureCatalog.openTerminal))
            try assertTrue(ids.contains(MenuFeatureCatalog.openEditor))
            try assertTrue(ids.contains(MenuFeatureCatalog.toggleHidden))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyDirectoryTree))
            try assertTrue(ids.contains(MenuFeatureCatalog.gitStatus))
            try assertTrue(ids.contains(MenuFeatureCatalog.lineCount))

            // 不能出现针对选中对象的破坏性/文件管理操作
            try assertTrue(!ids.contains(MenuFeatureCatalog.cut))
            try assertTrue(!ids.contains(MenuFeatureCatalog.moveTo))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyTo))
            try assertTrue(!ids.contains(MenuFeatureCatalog.compress))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileName))
            try assertTrue(!ids.contains(MenuFeatureCatalog.createSymlink))
            try assertTrue(!ids.contains(MenuFeatureCatalog.compareFiles))
        }

        runTest("菜单单一数据源：单选普通文本文件分支") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let editors = [MenuEditorData(bundleIdentifier: "com.microsoft.VSCode", name: "VS Code", icon: nil, tag: 0)]
            let favs = [MenuFavoriteData(path: "/Users/test/Downloads", displayName: "下载", isUnavailable: false, canTransfer: true, tag: 0)]
            let input = MenuBuildInput(
                location: .items,
                selection: .singleFile(isTextEligible: true, isArchive: false, isLineCountable: true, isComparable: true),
                enabledFeatureIds: allFeatures,
                editors: editors,
                favoriteDirectories: favs
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            let ids = nodes.map(\.id)

            // 单选文本代码文件包含复制内容、哈希、打开编辑器、常用目录、代码行数与比较文件；不包含目录级操作
            try assertTrue(ids.contains(MenuFeatureCatalog.copyPath))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyFileName))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(ids.contains(MenuFeatureCatalog.openEditor))
            try assertTrue(ids.contains(MenuFeatureCatalog.cut))
            try assertTrue(ids.contains(MenuFeatureCatalog.moveTo))
            try assertTrue(ids.contains(MenuFeatureCatalog.copyTo))
            try assertTrue(ids.contains(MenuFeatureCatalog.createSymlink))
            try assertTrue(ids.contains(MenuFeatureCatalog.compress))
            try assertTrue(ids.contains(MenuFeatureCatalog.lineCount))
            try assertTrue(ids.contains(MenuFeatureCatalog.compareFiles))
            try assertTrue(!ids.contains(MenuFeatureCatalog.decompress))
            try assertTrue(!ids.contains(MenuFeatureCatalog.newFile))
            try assertTrue(!ids.contains(MenuFeatureCatalog.goToDirectory))
            try assertTrue(!ids.contains(MenuFeatureCatalog.toggleHidden))
        }

        runTest("菜单单一数据源：单选非文本普通文件与文件夹差异") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let favs = [MenuFavoriteData(path: "/Users/test/Downloads", displayName: "下载", isUnavailable: false, canTransfer: true, tag: 0)]
            // 非文本非代码普通文件（如图片/压缩包）：无 copyFileContent、无 lineCount、无 compareFiles，有 copyFileHash
            let fileInput = MenuBuildInput(
                location: .items,
                selection: .singleFile(isTextEligible: false, isArchive: false, isLineCountable: false, isComparable: false),
                enabledFeatureIds: allFeatures,
                favoriteDirectories: favs
            )
            let fileIds = MenuTreeBuilder.buildMenuTree(input: fileInput).map(\.id)
            try assertTrue(!fileIds.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(!fileIds.contains(MenuFeatureCatalog.lineCount))
            try assertTrue(!fileIds.contains(MenuFeatureCatalog.compareFiles))
            try assertTrue(fileIds.contains(MenuFeatureCatalog.copyFileHash))

            // 文件夹：无 copyFileContent/copyFileHash/decompress/compareFiles，有 cut/moveTo/compress/lineCount
            let folderInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures,
                favoriteDirectories: favs
            )
            let folderNodes = MenuTreeBuilder.buildMenuTree(input: folderInput)
            let folderIds = folderNodes.map(\.id)
            try assertTrue(!folderIds.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(!folderIds.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(!folderIds.contains(MenuFeatureCatalog.decompress))
            try assertTrue(!folderIds.contains(MenuFeatureCatalog.compareFiles))
            try assertTrue(folderIds.contains(MenuFeatureCatalog.lineCount))
            try assertTrue(folderIds.contains(MenuFeatureCatalog.cut))
            try assertTrue(folderIds.contains(MenuFeatureCatalog.compress))
            try assertTrue(folderIds.contains(MenuFeatureCatalog.moveTo))
        }

        runTest("菜单单一数据源：多选且包含压缩包分支") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let input = MenuBuildInput(
                location: .items,
                selection: .multiple(count: 3, hasRegularFiles: true, hasArchives: true),
                enabledFeatureIds: allFeatures
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            let ids = nodes.map(\.id)

            // 多选：有哈希与解压，无复制内容
            try assertTrue(ids.contains(MenuFeatureCatalog.copyFileHash))
            try assertTrue(ids.contains(MenuFeatureCatalog.decompress))
            try assertTrue(!ids.contains(MenuFeatureCatalog.copyFileContent))
            try assertTrue(ids.contains(MenuFeatureCatalog.compress))
        }

        runTest("菜单单一数据源：剪切队列收拢为子菜单、已剪切项显示移出与粘贴文案格式化") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let input = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures,
                cutState: CutState(count: 3, isSelectionSubsetOfCut: true, canPasteInCurrentDirectory: true)
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)

            // 选中项已在剪切队列时，剪切项变为可执行的「移出剪切队列」且不带剪切快捷键
            let cutNode = nodes.first { $0.id == MenuFeatureCatalog.cut }!
            try assertEqual(cutNode.titleKey, "移出剪切队列")
            try assertEqual(cutNode.kind, .action(actionId: "removeFromCutQueue", tag: 0))
            try assertNil(cutNode.shortcutId)

            // 粘贴项精简文案并高亮启用
            let pasteIdx = nodes.firstIndex { $0.id == MenuFeatureCatalog.paste }!
            let pasteNode = nodes[pasteIdx]
            try assertTrue(pasteNode.isEnabled)
            try assertEqual(pasteNode.title, .formatted(key: "粘贴 (%d 项)", count: 3))

            // 剪切队列收拢为一个子菜单紧随粘贴之后，包含查看详情与取消剪切
            let queueIdx = nodes.firstIndex { $0.id == "submenu.cutQueue" }!
            try assertEqual(queueIdx, pasteIdx + 1, "剪切队列子菜单应紧随粘贴之后")
            let queueNode = nodes[queueIdx]
            try assertEqual(queueNode.title, .formatted(key: "剪切队列 (%d)", count: 3))
            guard case .submenu(let children) = queueNode.kind else {
                throw TestFailure(message: "submenu.cutQueue 必须是 submenu")
            }
            try assertEqual(children.map(\.id), ["action.showCutQueue", "action.cancelCut"])
            try assertEqual(children[0].titleKey, "查看详情…")
            try assertEqual(children[0].kind, .action(actionId: "showCutQueueDetail", tag: 0))
            try assertEqual(children[1].titleKey, "取消剪切")
            try assertEqual(children[1].kind, .action(actionId: "cancelCut", tag: 0))
        }

        runTest("菜单单一数据源：同目录剪切项在选中项隐藏粘贴、在空白处置灰粘贴") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let sameDirState = CutState.evaluate(
                cutPaths: ["/Users/demo/Desktop/a.txt", "/Users/demo/Desktop/b.txt"],
                selectedPaths: ["/Users/demo/Desktop/a.txt"],
                targetDirectory: "/Users/demo/Desktop"
            )
            try assertEqual(sameDirState.count, 2)
            try assertTrue(sameDirState.isSelectionSubsetOfCut)
            try assertTrue(!sameDirState.canPasteInCurrentDirectory)

            // 选中项上不显示无意义的同目录粘贴，剪切队列子菜单紧随移出项之后
            let itemNodes = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
                location: .items,
                selection: .singleFile(isTextEligible: true, isArchive: false),
                enabledFeatureIds: allFeatures,
                cutState: sameDirState
            ))
            try assertTrue(!itemNodes.contains { $0.id == MenuFeatureCatalog.paste })
            let cutIdx = itemNodes.firstIndex { $0.id == MenuFeatureCatalog.cut }!
            let queueIdx = itemNodes.firstIndex { $0.id == "submenu.cutQueue" }!
            try assertEqual(queueIdx, cutIdx + 1)

            // 空白处保留置灰的粘贴项，提示不能贴回原目录
            let containerNodes = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
                location: .container,
                selection: .empty,
                enabledFeatureIds: allFeatures,
                cutState: sameDirState
            ))
            let pasteNode = containerNodes.first { $0.id == MenuFeatureCatalog.paste }!
            try assertTrue(!pasteNode.isEnabled)
            try assertEqual(pasteNode.title, .formatted(key: "粘贴 (%d 项)", count: 2))

            // 混合来源队列在原目录仍可粘贴（至少有一项来自其他目录）
            let mixedState = CutState.evaluate(
                cutPaths: ["/Users/demo/Desktop/a.txt", "/Users/demo/Downloads/c.txt"],
                selectedPaths: ["/Users/demo/Desktop/a.txt"],
                targetDirectory: "/Users/demo/Desktop"
            )
            try assertTrue(mixedState.canPasteInCurrentDirectory)
        }

        runTest("菜单单一数据源：关闭剪切开关时剪切队列子菜单兜底插入粘贴之后") {
            var features = Set(MenuFeatureCatalog.all.map(\.id))
            features.remove(MenuFeatureCatalog.cut) // 关闭剪切
            let input = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: features,
                cutState: CutState(count: 2, isSelectionSubsetOfCut: false)
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            let ids = nodes.map(\.id)

            try assertTrue(!ids.contains(MenuFeatureCatalog.cut))
            let pasteIdx = ids.firstIndex(of: MenuFeatureCatalog.paste)!
            let queueIdx = ids.firstIndex(of: "submenu.cutQueue")!
            try assertEqual(queueIdx, pasteIdx + 1, "剪切队列子菜单应紧随粘贴之后插入")
        }

        runTest("UndoMenuState：右键菜单跳过延迟剪切撤销，其余操作正常展示") {
            try assertTrue(!UndoMenuState(kind: .cut, count: 3, name: "").showsInContextMenu)
            try assertTrue(UndoMenuState(kind: .paste, count: 3, name: "Dest").showsInContextMenu)
            try assertTrue(UndoMenuState(kind: .move, count: 1, name: "Dest").showsInContextMenu)
            try assertTrue(UndoMenuState(kind: .createFile, count: 1, name: "a.txt").showsInContextMenu)
        }

        runTest("菜单单一数据源：常用目录子菜单与状态展示") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            // 场景 1：无常用目录时隐藏「移动到」与「复制到」
            let emptyInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures,
                favoriteDirectories: []
            )
            let emptyIds = MenuTreeBuilder.buildMenuTree(input: emptyInput).map(\.id)
            try assertTrue(!emptyIds.contains(MenuFeatureCatalog.moveTo))
            try assertTrue(!emptyIds.contains(MenuFeatureCatalog.copyTo))

            // 场景 2：有常用目录且包含不可用目录
            let favs = [
                MenuFavoriteData(path: "/Users/test/Downloads", displayName: "下载", isUnavailable: false, canTransfer: true, tag: 0),
                MenuFavoriteData(path: "/Volumes/Lost", displayName: "外部盘", isUnavailable: true, canTransfer: false, tag: 1)
            ]
            let favInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: allFeatures,
                favoriteDirectories: favs
            )
            let favNodes = MenuTreeBuilder.buildMenuTree(input: favInput)
            let moveToNode2 = favNodes.first { $0.id == MenuFeatureCatalog.moveTo }!
            guard case .submenu(let children2) = moveToNode2.kind else {
                throw TestFailure(message: "moveTo 必须是 submenu")
            }
            try assertEqual(children2[0].title, .dynamic("下载"))
            try assertTrue(children2[0].isEnabled)
            try assertEqual(children2[1].title, .unavailableDirectory("外部盘"))
            try assertTrue(!children2[1].isEnabled)
        }

        runTest("菜单单一数据源：代码行数统计与比较文件快速文件过滤") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let swiftFile = dir.appendingPathComponent("Main.swift")
            let makefile = dir.appendingPathComponent("Makefile")
            let pngFile = dir.appendingPathComponent("image.png")
            let zipFile = dir.appendingPathComponent("archive.zip")
            try "let a = 1\n".write(to: swiftFile, atomically: true, encoding: .utf8)
            try "all:\n\techo hi\n".write(to: makefile, atomically: true, encoding: .utf8)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: pngFile)
            try Data([0x50, 0x4B, 0x03, 0x04]).write(to: zipFile)

            try assertTrue(LineCounter.isSupportedFile(swiftFile))
            try assertTrue(!LineCounter.isSupportedFile(pngFile))
            try assertTrue(!LineCounter.isSupportedFile(zipFile))

            try assertTrue(ComparisonDocument.isMenuEligible(swiftFile))
            try assertTrue(ComparisonDocument.isMenuEligible(makefile))
            try assertTrue(!ComparisonDocument.isMenuEligible(pngFile))
            try assertTrue(!ComparisonDocument.isMenuEligible(zipFile))
            try assertTrue(!ComparisonDocument.isMenuEligible(dir))
        }

        runTest("菜单单一数据源：整棵目录菜单区分同目录复制与移动") {
            let favorite = MenuFavoriteData(path: "/tmp", displayName: "临时目录", isUnavailable: false, canTransfer: false, tag: 0, canCopy: true)
            let input = MenuBuildInput(location: .items, selection: .singleFolder,
                                       enabledFeatureIds: [MenuFeatureCatalog.copyTo], favoriteDirectories: [favorite])
            let expected: [MenuDataNode] = [.submenu(id: MenuFeatureCatalog.copyTo, titleKey: "复制到", systemImage: "plus.square.on.square", tint: .green, children: [
                .dynamicAction(id: "feature.copyTo.0", title: "临时目录", systemImage: "folder", tint: .cyan, actionId: "copyToFavorite", isEnabled: true, toolTip: "/tmp"),
                .separator(id: "feature.copyTo.separator"),
                .action(id: "feature.copyTo.manage", titleKey: "管理常用目录…", systemImage: "gearshape", tint: .gray, actionId: "manageFavorites")
            ])]
            try assertEqual(MenuTreeBuilder.buildMenuTree(input: input), expected)
            let noFeatures = MenuBuildInput(location: .items, selection: .singleFolder, enabledFeatureIds: [])
            try assertEqual(MenuTreeBuilder.buildMenuTree(input: noFeatures), [])
        }

        runTest("菜单单一数据源：磁盘占用节点展示与开关过滤") {
            let inputWithUsage = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: [MenuFeatureCatalog.diskUsage],
                diskUsageTitle: "占用：1.2 GB",
                diskUsageToolTip: "/path/to/folder"
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: inputWithUsage)
            try assertEqual(nodes.count, 1)
            guard let usageNode = nodes.first else {
                throw TestFailure(message: "期望有 1 个节点")
            }
            try assertEqual(usageNode.id, MenuFeatureCatalog.diskUsage)
            try assertEqual(usageNode.title, .dynamic("占用：1.2 GB"))
            try assertEqual(usageNode.toolTip, "/path/to/folder")
            try assertTrue(!usageNode.isEnabled, "状态行默认不可点击")

            // 设为可交互时，生成可用节点与对应 action
            let interactiveInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: [MenuFeatureCatalog.diskUsage],
                diskUsageTitle: "占用：1.2 GB",
                diskUsageToolTip: "查看详情",
                isDiskUsageInteractive: true
            )
            let interactiveNodes = MenuTreeBuilder.buildMenuTree(input: interactiveInput)
            try assertTrue(interactiveNodes.first?.isEnabled == true, "文件夹且有大小时可点击")
            if case .action(let actionId, _) = interactiveNodes.first?.kind {
                try assertEqual(actionId, "showDiskUsageDetail")
            } else {
                throw TestFailure(message: "期望动作节点")
            }

            // 未开启功能时，即便传入了占用文案也不生成该节点
            let disabledInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: [],
                diskUsageTitle: "占用：1.2 GB"
            )
            try assertTrue(MenuTreeBuilder.buildMenuTree(input: disabledInput).isEmpty)

            // 无占用文案时不生成该节点
            let nilUsageInput = MenuBuildInput(
                location: .items,
                selection: .singleFolder,
                enabledFeatureIds: [MenuFeatureCatalog.diskUsage],
                diskUsageTitle: nil
            )
            try assertTrue(MenuTreeBuilder.buildMenuTree(input: nilUsageInput).isEmpty)
        }

        runTest("DiskUsage 菜单目标解析：空白处、单选文件/目录与多选规则") {
            let dirURL = URL(fileURLWithPath: "/test/current_dir")
            let folderURL = URL(fileURLWithPath: "/test/current_dir/subfolder")
            let fileURL = URL(fileURLWithPath: "/test/current_dir/document.txt")
            let otherURL = URL(fileURLWithPath: "/test/current_dir/file2.txt")

            let isDir: (URL) -> Bool = { $0 == dirURL || $0 == folderURL }
            let isFile: (URL) -> Bool = { $0 == fileURL || $0 == otherURL }

            // 1. 空白处（.container）：目标为当前目录（即使 selected 有残留也取 directory）
            let containerTarget = DiskUsage.target(
                location: .container,
                selected: [],
                directory: dirURL,
                isRegularDirectory: isDir,
                isRegularFile: isFile
            )
            try assertEqual(containerTarget, dirURL)

            let containerWithResidualSelection = DiskUsage.target(
                location: .container,
                selected: [fileURL],
                directory: dirURL,
                isRegularDirectory: isDir,
                isRegularFile: isFile
            )
            try assertEqual(containerWithResidualSelection, dirURL)

            // directory 为 nil 或非目录时返回 nil
            let containerNilDir = DiskUsage.target(
                location: .container,
                selected: [],
                directory: nil,
                isRegularDirectory: isDir,
                isRegularFile: isFile
            )
            try assertEqual(containerNilDir, nil)

            // 2. 选中项（.items）：单选有效目录或文件返回该项，多选或空选返回 nil
            let singleFolder = DiskUsage.target(
                location: .items,
                selected: [folderURL],
                directory: dirURL,
                isRegularDirectory: isDir,
                isRegularFile: isFile
            )
            try assertEqual(singleFolder, folderURL)

            let singleFile = DiskUsage.target(
                location: .items,
                selected: [fileURL],
                directory: dirURL,
                isRegularDirectory: isDir,
                isRegularFile: isFile
            )
            try assertEqual(singleFile, fileURL)

            let multiple = DiskUsage.target(
                location: .items,
                selected: [fileURL, otherURL],
                directory: dirURL,
                isRegularDirectory: isDir,
                isRegularFile: isFile
            )
            try assertEqual(multiple, nil)

            let emptySelection = DiskUsage.target(
                location: .items,
                selected: [],
                directory: dirURL,
                isRegularDirectory: isDir,
                isRegularFile: isFile
            )
            try assertEqual(emptySelection, nil)

            // 3. 侧边栏（.sidebar）：不展示
            let sidebarTarget = DiskUsage.target(
                location: .sidebar,
                selected: [folderURL],
                directory: dirURL,
                isRegularDirectory: isDir,
                isRegularFile: isFile
            )
            try assertEqual(sidebarTarget, nil)
        }

        runTest("菜单构建：访达空白处（.container）支持展示可交互磁盘占用") {
            let containerInput = MenuBuildInput(
                location: .container,
                selection: .empty,
                enabledFeatureIds: [MenuFeatureCatalog.diskUsage],
                diskUsageTitle: "占用：256.4 MB",
                diskUsageToolTip: "/test/current_dir\n点击查看子项占用排行",
                isDiskUsageInteractive: true
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: containerInput)
            guard let node = nodes.first(where: { $0.id == MenuFeatureCatalog.diskUsage }) else {
                throw TestFailure(message: "空白处应包含 diskUsage 节点")
            }
            try assertEqual(node.title, .dynamic("占用：256.4 MB"))
            try assertEqual(node.toolTip, "/test/current_dir\n点击查看子项占用排行")
            try assertTrue(node.isEnabled, "空白处为目录，必须可交互")
            if case .action(let actionId, _) = node.kind {
                try assertEqual(actionId, "showDiskUsageDetail")
            } else {
                throw TestFailure(message: "期望 showDiskUsageDetail 动作")
            }
        }

        runTest("AppUpdateTracker：应用启动与更新判定") {
            // 首次启动
            let first = AppUpdateTracker.evaluate(
                lastVersion: nil,
                lastBuild: nil,
                currentVersion: "1.12.4",
                currentBuild: "48"
            )
            try assertTrue(first.isFirstLaunch, "未记录过版本时为首次启动")
            try assertTrue(!first.isAppUpdated, "首次启动不视为更新")

            // 正常日常启动（版本一致）
            let normal = AppUpdateTracker.evaluate(
                lastVersion: "1.12.4",
                lastBuild: "48",
                currentVersion: "1.12.4",
                currentBuild: "48"
            )
            try assertTrue(!normal.isFirstLaunch)
            try assertTrue(!normal.isAppUpdated, "版本一致不视为更新")

            // 版本号升级
            let versionUpgrade = AppUpdateTracker.evaluate(
                lastVersion: "1.12.3",
                lastBuild: "47",
                currentVersion: "1.12.4",
                currentBuild: "48"
            )
            try assertTrue(!versionUpgrade.isFirstLaunch)
            try assertTrue(versionUpgrade.isAppUpdated, "版本变化视为更新")

            // 仅构建号升级
            let buildUpgrade = AppUpdateTracker.evaluate(
                lastVersion: "1.12.4",
                lastBuild: "48",
                currentVersion: "1.12.4",
                currentBuild: "49"
            )
            try assertTrue(buildUpgrade.isAppUpdated, "构建号变化视为更新")
        }

        runTest("ChangelogCatalog：版本列表有序且每个版本包含更新条目") {
            let list = ChangelogCatalog.entries
            try assertTrue(!list.isEmpty, "更新日志条目不为空")

            // 检查版本号倒序
            for i in 0..<(list.count - 1) {
                let vCurrent = list[i].version
                let vNext = list[i + 1].version
                let order = VersionComparator.compareVersions(vCurrent, vNext)
                try assertTrue(order == .orderedDescending, "版本必须严格倒序排列: \(vCurrent) > \(vNext)")
            }

            // 每个版本都有条目
            for item in list {
                try assertTrue(!item.items.isEmpty, "\(item.version) 必须包含更新详情")
            }
        }

        runTest("服务菜单防漂移：完整声明对齐时校验无 issue") {
            let testFeatures = [
                MenuFeature(id: "test.copy", nameKey: "测试复制", descriptionKey: "", systemImage: "link",
                            serviceDeclaration: ServiceMenuDeclaration(message: "testCopy", menuItemTitle: "FinderRight: Test Copy"))
            ]
            let plist = [("testCopy", "FinderRight: Test Copy")]
            let provider = "func testCopy(_ pboard: NSPasteboard) {}"
            let strings: Set<String> = ["FinderRight: Test Copy"]

            let issues = ServiceMenuDriftChecker.verify(
                features: testFeatures,
                plistServices: plist,
                providerSource: provider,
                servicesMenuKeys: strings
            )
            try assertTrue(issues.isEmpty, "对齐时 issues 必须为空")
        }

        runTest("服务菜单防漂移：缺失条目与多余条目准确报错") {
            let testFeatures = [
                MenuFeature(id: "test.copy", nameKey: "测试复制", descriptionKey: "", systemImage: "link",
                            serviceDeclaration: ServiceMenuDeclaration(message: "testCopy", menuItemTitle: "FinderRight: Test Copy"))
            ]
            // Plist 缺少该声明
            let issuesMissing = ServiceMenuDriftChecker.verify(
                features: testFeatures,
                plistServices: [],
                providerSource: "func testCopy() {}",
                servicesMenuKeys: ["FinderRight: Test Copy"]
            )
            try assertEqual(issuesMissing.count, 1)
            try assertEqual(issuesMissing[0].file, "FinderRight/Info.plist")
            try assertEqual(issuesMissing[0].featureId, "test.copy")

            // Plist 含有未声明的多余服务
            let issuesExtra = ServiceMenuDriftChecker.verify(
                features: [],
                plistServices: [("extraService", "FinderRight: Extra")],
                providerSource: "",
                servicesMenuKeys: []
            )
            try assertEqual(issuesExtra.count, 1)
            try assertEqual(issuesExtra[0].message, "extraService")

            // Provider 缺失同名处理方法
            let issuesNoMethod = ServiceMenuDriftChecker.verify(
                features: testFeatures,
                plistServices: [("testCopy", "FinderRight: Test Copy")],
                providerSource: "// 没有任何方法",
                servicesMenuKeys: ["FinderRight: Test Copy"]
            )
            try assertEqual(issuesNoMethod.count, 1)
            try assertEqual(issuesNoMethod[0].file, "FinderRight/Services/ServicesProvider.swift")

            // Strings 缺失本地化映射
            let issuesNoStrings = ServiceMenuDriftChecker.verify(
                features: testFeatures,
                plistServices: [("testCopy", "FinderRight: Test Copy")],
                providerSource: "func testCopy() {}",
                servicesMenuKeys: []
            )
            try assertEqual(issuesNoStrings.count, 1)
            try assertEqual(issuesNoStrings[0].file, "FinderRight/zh-Hans.lproj/ServicesMenu.strings")
        }

        runTest("ServiceInvocationPolicy 下沉参数校验") {
            let tempDir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let file = tempDir.appendingPathComponent("note.txt")
            try Data().write(to: file)

            // targetDirectory: 文件夹返回自身，普通文件返回父目录
            try assertEqual(ServiceInvocationPolicy.targetDirectory(for: tempDir).path, tempDir.path)
            try assertEqual(ServiceInvocationPolicy.targetDirectory(for: file).path, tempDir.path)

            // validateSingleFile
            try assertEqual(ServiceInvocationPolicy.validateSingleFile(from: [file])?.path, file.path)
            try assertNil(ServiceInvocationPolicy.validateSingleFile(from: []))
            try assertNil(ServiceInvocationPolicy.validateSingleFile(from: [file, tempDir]))

            // filterArchives
            let zip = tempDir.appendingPathComponent("a.zip")
            let doc = tempDir.appendingPathComponent("b.docx")
            try assertEqual(ServiceInvocationPolicy.filterArchives(from: [zip, doc, file]), [zip])

            // validateFavoritesTransfer
            try assertTrue(ServiceInvocationPolicy.validateFavoritesTransfer(items: [file], favorites: ["/tmp"]))
            try assertTrue(!ServiceInvocationPolicy.validateFavoritesTransfer(items: [], favorites: ["/tmp"]))
            try assertTrue(!ServiceInvocationPolicy.validateFavoritesTransfer(items: [file], favorites: []))
        }

        runTest("UpdatePolicy 备用源地址双向映射及拒绝非法 URL") {
            let tag = "v1.2.3"
            let name = "FinderRight-\(tag).zip"
            let githubZIP = URL(string: "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/\(name)")!
            let websiteZIP = URL(string: "\(UpdatePolicy.websiteOrigin)/download/\(tag)/\(name)")!

            // 双向映射正常推导
            try assertEqual(UpdatePolicy.alternateAssetURL(for: githubZIP), websiteZIP)
            try assertEqual(UpdatePolicy.alternateAssetURL(for: websiteZIP), githubZIP)

            // .sha256 校验和文件映射
            let githubSHA = URL(string: githubZIP.absoluteString + ".sha256")!
            let websiteSHA = URL(string: websiteZIP.absoluteString + ".sha256")!
            try assertEqual(UpdatePolicy.alternateAssetURL(for: githubSHA), websiteSHA)
            try assertEqual(UpdatePolicy.alternateAssetURL(for: websiteSHA), githubSHA)

            // fallbackAssetURL 判定
            try assertEqual(UpdatePolicy.fallbackAssetURL(for: githubZIP, allowFallback: true), websiteZIP)
            try assertNil(UpdatePolicy.fallbackAssetURL(for: githubZIP, allowFallback: false))

            // 拒绝非法 URL
            let invalids = [
                "http://github.com/funny-dog/FinderRight/releases/download/\(tag)/\(name)", // 非 HTTPS
                "https://github.com/other-org/FinderRight/releases/download/\(tag)/\(name)", // 跨仓库
                "https://github.com/funny-dog/FinderRight/releases/download/latest/\(name)", // latest
                "https://github.com/funny-dog/FinderRight/releases/download/v1.2.3/FinderRight-v1.2.4.zip", // 版本不匹配
                "\(UpdatePolicy.websiteOrigin)/download/\(tag)/\(name)?query=1", // 带 query
                "\(UpdatePolicy.websiteOrigin)/download/\(tag)/\(name)#hash" // 带 fragment
            ]
            for invalid in invalids {
                try assertNil(UpdatePolicy.alternateAssetURL(for: URL(string: invalid)!), "应拒绝: \(invalid)")
            }
        }

        runTest("UpdatePolicy Release 数据解析：带 digest 完整新版本") {
            let hash = String(repeating: "f", count: 64)
            let tag = "v2.0.0"
            let json = """
            {
                "tag_name": "\(tag)",
                "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
                "assets": [
                    {
                        "name": "FinderRight-\(tag).zip",
                        "browser_download_url": "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/FinderRight-\(tag).zip",
                        "digest": "sha256:\(hash)"
                    }
                ]
            }
            """
            let status = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: false, currentVersion: "1.0.0")
            let expectedURL = URL(string: "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/FinderRight-\(tag).zip")!
            try assertEqual(status, .updateAvailable(
                version: tag,
                releaseURL: URL(string: "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)")!,
                downloadURL: expectedURL,
                checksum: .digest(hash)
            ))
        }

        runTest("UpdatePolicy Release 数据解析：带 sha256 文件且走官网镜像") {
            let tag = "v2.0.0"
            let json = """
            {
                "tag_name": "\(tag)",
                "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
                "assets": [
                    {
                        "name": "FinderRight-\(tag).zip",
                        "browser_download_url": "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/FinderRight-\(tag).zip"
                    },
                    {
                        "name": "FinderRight-\(tag).zip.sha256",
                        "browser_download_url": "https://github.com/funny-dog/FinderRight/releases/download/\(tag)/FinderRight-\(tag).zip.sha256"
                    }
                ]
            }
            """
            let status = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: true, currentVersion: "1.0.0")
            let expectedDownloadURL = URL(string: "\(UpdatePolicy.websiteOrigin)/download/\(tag)/FinderRight-\(tag).zip")!
            let expectedChecksumURL = URL(string: "\(UpdatePolicy.websiteOrigin)/download/\(tag)/FinderRight-\(tag).zip.sha256")!
            try assertEqual(status, .updateAvailable(
                version: tag,
                releaseURL: URL(string: "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)")!,
                downloadURL: expectedDownloadURL,
                checksum: .file(expectedChecksumURL)
            ))
        }

        runTest("UpdatePolicy Release 数据解析：无匹配资产或跨仓库资产") {
            let tag = "v2.0.0"
            let json = """
            {
                "tag_name": "\(tag)",
                "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
                "assets": [
                    {
                        "name": "OtherApp.zip",
                        "browser_download_url": "https://example.com/OtherApp.zip"
                    }
                ]
            }
            """
            let status = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: false, currentVersion: "1.0.0")
            try assertEqual(status, .updateAvailable(
                version: tag,
                releaseURL: URL(string: "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)")!,
                downloadURL: nil,
                checksum: nil
            ))
        }

        runTest("UpdatePolicy Release 数据解析：版本相同或更旧") {
            let tagSame = "v1.0.0"
            let jsonSame = """
            {"tag_name": "\(tagSame)", "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tagSame)"}
            """
            let statusSame = try UpdatePolicy.releaseStatus(from: Data(jsonSame.utf8), viaWebsite: false, currentVersion: "1.0.0")
            try assertEqual(statusSame, .upToDate)

            let tagOlder = "v0.9.5"
            let jsonOlder = """
            {"tag_name": "\(tagOlder)", "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tagOlder)"}
            """
            let statusOlder = try UpdatePolicy.releaseStatus(from: Data(jsonOlder.utf8), viaWebsite: false, currentVersion: "1.0.0")
            try assertEqual(statusOlder, .upToDate)
        }

        runTest("UpdatePolicy Release 数据解析：draft 与 prerelease 保留现有行为") {
            let tag = "v2.1.0"
            let json = """
            {
                "tag_name": "\(tag)",
                "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)",
                "draft": true,
                "prerelease": true
            }
            """
            let status = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: false, currentVersion: "1.0.0")
            try assertEqual(status, .updateAvailable(
                version: tag,
                releaseURL: URL(string: "https://github.com/funny-dog/FinderRight/releases/tag/\(tag)")!,
                downloadURL: nil,
                checksum: nil
            ))
            let ignoredFields = json.replacingOccurrences(of: "\"draft\": true", with: "\"draft\": \"ignored\"")
                .replacingOccurrences(of: "\"prerelease\": true", with: "\"prerelease\": 1")
            try assertEqual(try UpdatePolicy.releaseStatus(from: Data(ignoredFields.utf8), viaWebsite: false, currentVersion: "1.0.0"), status)

        }

        runTest("UpdatePolicy Release 数据解析：非法标签格式抛出错误") {
            for invalidTag in ["1.0.0", "v1.0", "v1.0.0-beta", "not-a-version"] {
                let json = """
                {"tag_name": "\(invalidTag)", "html_url": "https://github.com/funny-dog/FinderRight/releases/tag/\(invalidTag)"}
                """
                var didThrow = false
                do {
                    _ = try UpdatePolicy.releaseStatus(from: Data(json.utf8), viaWebsite: false, currentVersion: "1.0.0")
                } catch {
                    didThrow = true
                }
                try assertTrue(didThrow, "非法 tag [\(invalidTag)] 应抛出错误")
            }
        }

        runTest("UpdatePolicy 补充等待窗口：没有有效结果时不能报告最新") {
            try assertEqual(UpdatePolicy.concludeSupplementalWindow(fallback: nil), .waitForRemaining(fallback: nil),
                            "两路都没有有效结果时应继续等各自超时")
            try assertEqual(UpdatePolicy.concludeSupplementalWindow(fallback: .upToDate),
                            .finish(status: .upToDate, recordSuccessDate: true),
                            "窗口结束用已收到的结论收尾")
            let partial: UpdateCheckStatus = .updateAvailable(version: "v2.0.0", releaseURL: URL(string: "https://example.com/rel")!,
                                                              downloadURL: nil, checksum: nil)
            try assertEqual(UpdatePolicy.concludeSupplementalWindow(fallback: partial),
                            .finish(status: partial, recordSuccessDate: true),
                            "缺少校验信息的版本提示不能被窗口结束覆盖")
            try assertEqual(UpdatePolicy.supplementalCheckWindow, 0.8, "内部常量固定 800 毫秒")
        }

        runTest("UpdatePolicy 检查时机：主动检查强制请求，自动检查利用旧结论") {
            let now = Date()
            let recent = now.addingTimeInterval(-60)
            let staleButUseful = now.addingTimeInterval(-30 * 60)
            let veryOld = now.addingTimeInterval(-5 * 3600)
            try assertEqual(UpdatePolicy.requestPolicy(force: false, automatic: false, currentStatus: .upToDate,
                                                       lastCheckedDate: recent, now: now).waitsForResult, false,
                            "十分钟内的结论直接复用并立即返回")
            let forced = UpdatePolicy.requestPolicy(force: true, automatic: false, currentStatus: .upToDate,
                                                       lastCheckedDate: recent, now: now)
            try assertTrue(forced.force && !forced.waitsForResult, "主动点击必须重新请求；旧结论由界面自行展示，不在回调里重放")
            try assertTrue(!UpdatePolicy.requestPolicy(force: true, automatic: false, currentStatus: .idle,
                                                       lastCheckedDate: nil, now: now).waitsForResult,
                           "没有已有结论时不先回调")
            try assertEqual(UpdatePolicy.requestPolicy(force: false, automatic: false, currentStatus: .upToDate,
                                                       lastCheckedDate: staleButUseful, now: now).force, true,
                            "结论较旧时后台请求新结果")
            let automatic = UpdatePolicy.requestPolicy(force: false, automatic: true, currentStatus: .upToDate,
                                                       lastCheckedDate: staleButUseful, now: now)
            try assertTrue(!automatic.force && automatic.waitsForResult,
                           "定时检查沿用两小时内的「最新」结论，后台静默刷新")
            try assertEqual(UpdatePolicy.requestPolicy(force: false, automatic: true, currentStatus: .upToDate,
                                                       lastCheckedDate: veryOld, now: now).force, true,
                            "超过两小时则真正请求")
        }

        // P2 回归：waitsForResult=true 的路径必须把 completion 传给后台刷新，不能丢弃
        // 这里验证 policy 层语义：10～120 分钟内旧缓存 + automatic=true 才走该路径；
        // 后续 check() 的行为属于集成层，由测试用例描述覆盖
        runTest("UpdatePolicy waitsForResult 仅在合法范围触发，不影响强制检查与超过上限的过期检查") {
            let now = Date()
            // 10～120 分钟之间：走 waitsForResult 路径
            for minutesAgo in [11, 30, 60, 90, 119] {
                let date = now.addingTimeInterval(-TimeInterval(minutesAgo * 60))
                let policy = UpdatePolicy.requestPolicy(force: false, automatic: true, currentStatus: .upToDate,
                                                       lastCheckedDate: date, now: now)
                try assertTrue(!policy.force && policy.waitsForResult,
                               "\(minutesAgo) 分钟前的旧缓存应走 waitsForResult 路径")
            }
            // 超过 120 分钟：必须真正请求，不走 waitsForResult
            let tooOld = now.addingTimeInterval(-121 * 60)
            let oldPolicy = UpdatePolicy.requestPolicy(force: false, automatic: true, currentStatus: .upToDate,
                                                      lastCheckedDate: tooOld, now: now)
            try assertTrue(oldPolicy.force && !oldPolicy.waitsForResult,
                           "超过两小时的缓存应强制重新请求，不走 waitsForResult")
            // 强制检查：不走 waitsForResult
            let forced = UpdatePolicy.requestPolicy(force: true, automatic: true, currentStatus: .upToDate,
                                                   lastCheckedDate: now.addingTimeInterval(-30 * 60), now: now)
            try assertTrue(forced.force && !forced.waitsForResult,
                           "强制检查不走 waitsForResult，completion 直接绑定网络结果")
        }

        runTest("UpdatePolicy 两路检查仲裁：首个完整可安装新版直接完成") {
            let fullStatus: UpdateCheckStatus = .updateAvailable(
                version: "v2.0.0",
                releaseURL: URL(string: "https://example.com/rel")!,
                downloadURL: URL(string: "https://example.com/dl")!,
                checksum: .digest("abcd")
            )
            let decision = UpdatePolicy.arbitrateCheck(
                result: .success(fullStatus),
                currentFallback: nil,
                remaining: 1
            )
            try assertEqual(decision, .finish(status: fullStatus, recordSuccessDate: true))
        }

        runTest("UpdatePolicy 两路检查仲裁：部分响应暂存 fallback 与最终裁决") {
            let partialStatus: UpdateCheckStatus = .updateAvailable(
                version: "v2.0.0",
                releaseURL: URL(string: "https://example.com/rel")!,
                downloadURL: nil,
                checksum: nil
            )

            // 第一路返回缺少校验和的新版，仍有 1 路待返回 -> 继续等待并暂存
            let step1 = UpdatePolicy.arbitrateCheck(
                result: .success(partialStatus),
                currentFallback: nil,
                remaining: 1
            )
            try assertEqual(step1, .waitForRemaining(fallback: partialStatus))

            // 第二路返回更高版本（同样缺少校验和），剩余 0 路 -> 决出最新版本
            let partialStatusHigher: UpdateCheckStatus = .updateAvailable(
                version: "v2.1.0",
                releaseURL: URL(string: "https://example.com/rel2")!,
                downloadURL: nil,
                checksum: nil
            )
            let step2 = UpdatePolicy.arbitrateCheck(
                result: .success(partialStatusHigher),
                currentFallback: partialStatus,
                remaining: 0
            )
            try assertEqual(step2, .finish(status: partialStatusHigher, recordSuccessDate: true))
        }

        runTest("UpdatePolicy 两路检查仲裁：一路失败一路成功与双路全败") {
            let err = UpdateError("网络错误")

            // 第一路失败，剩余 1 路 -> 继续等待
            let step1 = UpdatePolicy.arbitrateCheck(
                result: .failure(err),
                currentFallback: nil,
                remaining: 1
            )
            try assertEqual(step1, .waitForRemaining(fallback: nil))

            // 第二路也失败，剩余 0 路 -> 决出失败，且不记录成功时间
            let step2Fail = UpdatePolicy.arbitrateCheck(
                result: .failure(err),
                currentFallback: nil,
                remaining: 0
            )
            try assertEqual(step2Fail, .finish(status: .failed(err.localizedDescription), recordSuccessDate: false))

            // 若已有 fallback，第二路失败时采用已有 fallback
            let fallback: UpdateCheckStatus = .upToDate
            let step2Fallback = UpdatePolicy.arbitrateCheck(
                result: .failure(err),
                currentFallback: fallback,
                remaining: 0
            )
            try assertEqual(step2Fallback, .finish(status: fallback, recordSuccessDate: true))
        }

        runTest("UpdatePolicy 缓存复用决策与请求构造") {
            let now = Date()
            let status: UpdateCheckStatus = .upToDate

            // 10 分钟内正常复用
            try assertTrue(UpdatePolicy.shouldReuseCachedStatus(currentStatus: status, lastCheckedDate: now.addingTimeInterval(-300), now: now, force: false))
            // 超过 10 分钟不复用
            try assertTrue(!UpdatePolicy.shouldReuseCachedStatus(currentStatus: status, lastCheckedDate: now.addingTimeInterval(-700), now: now, force: false))
            // force 强制检查不复用
            try assertTrue(!UpdatePolicy.shouldReuseCachedStatus(currentStatus: status, lastCheckedDate: now.addingTimeInterval(-100), now: now, force: true))
            // failed 状态不复用
            try assertTrue(!UpdatePolicy.shouldReuseCachedStatus(currentStatus: .failed("err"), lastCheckedDate: now.addingTimeInterval(-100), now: now, force: false))

            // 请求构造
            let req = UpdatePolicy.makeCheckRequest(for: URL(string: "https://example.com")!)
            try assertEqual(req.value(forHTTPHeaderField: "User-Agent"), "FinderRight-App")
            try assertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github.v3+json")
        }

        runTest("UpdatePolicy 下载超时状态机决策") {
            var tracker = DownloadTimeoutTracker(firstByteTimeout: 3, stallTimeout: 10)
            try assertEqual(tracker.initialTimeout(), 3)
            try assertTrue(!tracker.isCompleted)

            // 收到数据，未确定预期总量
            let step1 = tracker.handleDataWritten(bytesWritten: 100, totalBytesWritten: 100, totalBytesExpected: -1)
            try assertEqual(step1?.resetTimeoutInterval, 10)
            try assertNil(step1?.progress)

            // 收到数据，进度计算与边界裁切
            let step2 = tracker.handleDataWritten(bytesWritten: 50, totalBytesWritten: 50, totalBytesExpected: 100)
            try assertEqual(step2?.progress, 0.5)

            let stepOverflow = tracker.handleDataWritten(bytesWritten: 200, totalBytesWritten: 200, totalBytesExpected: 100)
            try assertEqual(stepOverflow?.progress, 1.0)

            // 首次完成返回 true，二次完成返回 false
            try assertTrue(tracker.handleFinished())
            try assertTrue(tracker.isCompleted)
            try assertTrue(!tracker.handleFinished())
            try assertNil(tracker.handleDataWritten(bytesWritten: 10, totalBytesWritten: 10, totalBytesExpected: 10))
        }

        runTest("操作历史：未执行缩放保留失败状态并直接说明原因") {
            let reason = ImageTransformError.alreadySmallerThanTarget(longEdge: 436, target: 800).localizedDescription
            let record = OperationRecord(kind: .scaleImage, subject: "photo.heic", failure: reason)
            try assertTrue(!record.succeeded)
            try assertEqual(OperationHistoryPresentation.Outcome(record), .failed)
            try assertEqual(OperationHistoryPresentation.failureSummary(record), reason)
            try assertTrue(reason.contains("436") && reason.contains("800") && reason.contains("不放大"))
        }

        runTest("操作历史：无需缩放说明不属于失败且兼容旧记录") {
            let note = "photo.heic：图片长边（436 像素）未超过 800 像素，已跳过"
            let record = OperationRecord(kind: .scaleImage, subject: "photo.heic", note: note)
            try assertTrue(record.succeeded)
            try assertEqual(OperationHistoryPresentation.Outcome(record), .completed)
            try assertEqual(OperationHistoryFilter(searchText: "436").apply(to: [record]), [record])
            let encoded = try JSONEncoder().encode(record)
            try assertEqual(try JSONDecoder().decode(OperationRecord.self, from: encoded), record)
            var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            legacy.removeValue(forKey: "note")
            let old = try JSONDecoder().decode(OperationRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
            try assertNil(old.note)
            try assertTrue(old.succeeded)
            let failed = OperationRecord(kind: .scaleImage, subject: "bad.heic", failure: "decode failed", note: note)
            try assertEqual(OperationHistoryPresentation.Outcome(failed), .failed)
        }

        runTest("操作历史 状态搜索筛选与日期分组") {
        let ok = OperationRecord(kind: .compress, subject: "资料")
        let cancelled = OperationRecord(kind: .decompress, subject: "资料.zip", cancelled: true)
        let failed = OperationRecord(kind: .decompress, subject: "资料.zip", failure: "unsupported compression method (exit 1)")
        let partial = OperationRecord(kind: .move, subject: "3 个项目", failure: "Permission denied",
                                      results: [URL(fileURLWithPath: "/tmp/completed.txt")])
        let destination = URL(fileURLWithPath: "/tmp/目标文件夹")
        let results = [destination.appendingPathComponent("a.txt"), destination.appendingPathComponent("b.txt")]
        for (kind, action) in [(OperationRecord.Kind.move, "移动"), (.copy, "复制")] {
            let completed = OperationRecord(kind: kind, subject: "3 个项目", results: results, location: destination)
            precondition(OperationHistoryPresentation.transferSuccessMessage(completed) == "已\(action) 2 项到“目标文件夹”")
            precondition(OperationHistoryPresentation.transferSuccessMessage(
                OperationRecord(kind: kind, subject: "a", results: results, cancelled: true)) == nil)
            precondition(OperationHistoryPresentation.transferSuccessMessage(
                OperationRecord(kind: kind, subject: "a")) == nil)
        }
        for record in [ok, cancelled, failed, partial,
                       OperationRecord(kind: .paste, subject: "a", results: results)] {
            precondition(OperationHistoryPresentation.transferSuccessMessage(record) == nil)
        }
        precondition(OperationHistoryPresentation.transferSuccessMessage(
            OperationRecord(kind: .copy, subject: "a", results: [results[0]])) == "已复制 1 项到“目标文件夹”")
        precondition(OperationHistoryPresentation.status(ok) == "已完成")
        precondition(OperationHistoryPresentation.status(cancelled) == "已取消")
        precondition(OperationHistoryPresentation.status(failed) == "未完成")
        precondition(OperationHistoryPresentation.status(partial) == "部分完成")
        precondition(OperationHistoryPresentation.failureSummary(partial).contains("权限"))
        precondition(!OperationHistoryPresentation.failureSummary(failed).contains("exit"))
        precondition(OperationHistoryPresentation.failureSummary(failed).contains("格式"))
        for (reason, expected) in [("No space left on device", "空间"), ("Incorrect password", "密码"),
                                   ("No such file", "找不到"), ("File exists", "同名")] {
            precondition(OperationHistoryPresentation.failureSummary(
                OperationRecord(kind: .copy, subject: "a", failure: reason)).contains(expected))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 5))!
        precondition(OperationHistoryPresentation.dayTitle(now, now: now, calendar: calendar) == "今天")
        precondition(OperationHistoryPresentation.dayTitle(now.addingTimeInterval(-600), now: now, calendar: calendar) == "昨天")
        let groups = OperationHistoryPresentation.dayGroups([
            OperationRecord(kind: .copy, subject: "a", date: now.addingTimeInterval(60)),
            OperationRecord(kind: .copy, subject: "b", date: now.addingTimeInterval(-600)),
            OperationRecord(kind: .copy, subject: "c", date: now),
        ], calendar: calendar)
        precondition(groups.map { $0.records.map(\.subject) } == [["a", "c"], ["b"]], "按天分组：组按日期倒序，组内保持原顺序")
        precondition([ok, cancelled, failed, partial].map(OperationHistoryPresentation.Outcome.init)
                     == [.completed, .cancelled, .failed, .partial])
        print("✓ 历史状态、用户可读失败原因及跨午夜日期分组检查通过")

        let searchRecord = OperationRecord(kind: .copy, subject: "3 个项目",
                                           results: [URL(fileURLWithPath: "/tmp/Projects/Résumé.PDF")],
                                           location: URL(fileURLWithPath: "/tmp/Projects"))
        let candidates = [ok, cancelled, failed, partial, searchRecord]
        precondition(OperationHistoryFilter().apply(to: candidates) == candidates)
        precondition(OperationHistoryFilter(searchText: " \n ").apply(to: candidates) == candidates)
        precondition(!OperationHistoryFilter(searchText: " \n ").isActive)
        precondition(OperationHistoryFilter(searchText: "资料").apply(to: candidates) == [ok, cancelled, failed])
        precondition(OperationHistoryFilter(searchText: "复制 resume projects").apply(to: candidates) == [searchRecord])
        precondition(OperationHistoryFilter(searchText: "résumé.pdf").apply(to: candidates) == [searchRecord])
        precondition(OperationHistoryFilter(searchText: "权限").apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(searchText: "unsupported").apply(to: candidates) == [failed])
        precondition(OperationHistoryFilter(searchText: "move").apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(kind: .move, status: .partial).apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(kind: .compress, status: .failed).apply(to: candidates).isEmpty)
        for (status, expected) in [(OperationHistoryFilter.Status.completed, [ok, searchRecord]),
                                   (.partial, [partial]), (.failed, [failed]), (.cancelled, [cancelled])] {
            precondition(OperationHistoryFilter(status: status).apply(to: candidates) == expected)
        }
        let counts = OperationHistoryFilter(status: .failed).statusCounts(in: candidates)
        precondition(counts == [.all: 5, .completed: 2, .partial: 1, .failed: 1, .cancelled: 1], "状态数量不受当前状态筛选影响")
        precondition(OperationHistoryFilter(kind: .decompress).statusCounts(in: candidates) == [.all: 2, .failed: 1, .cancelled: 1])
        let memoryStore = RecentOperations()
        candidates.reversed().forEach { memoryStore.record($0) }
        let before = memoryStore.records
        _ = OperationHistoryFilter(searchText: "不存在的文件", kind: .move, status: .failed).apply(to: before)
        precondition(memoryStore.records == before, "搜索和筛选不得删除或修改历史")
        print("✓ 搜索覆盖名称、操作、结果文件、位置、失败说明；组合筛选与空结果检查通过")

        }

        runTest("文本预览 刚好 1 MiB 完整显示") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("exact.yaml")
            let data = Data(repeating: 65, count: 1_048_576)
            try data.write(to: file)
            guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(text.utf8.count, data.count)
            try assertTrue(!truncated)
        }

        runTest("文本预览 超出上限在最后完整换行处截断") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            for name in [".gitignore", "main.go", "settings.ini"] {
                let file = root.appendingPathComponent(name)
                let head = "# 中文注释\r\nkey = true\n"
                try (Data(head.utf8) + Data(repeating: 65, count: 1_048_576)).write(to: file)
                guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
                try assertEqual(text, head)
                try assertTrue(truncated)
            }
        }

        runTest("文本预览 截断不切开 CRLF 换行") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("windows.conf")
            let head = "first\n"
            let padding = Data(repeating: 65, count: 1_048_576 - head.utf8.count - 1)
            try (Data(head.utf8) + padding + Data("\r\nnext".utf8)).write(to: file)
            guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(text, head)
            try assertTrue(truncated)
            let padded = head + String(repeating: "a", count: (1_048_576 - 2) / 2 - head.utf16.count - 1) + "\r\nnext"
            for (encoding, bom) in [(String.Encoding.utf16LittleEndian, [UInt8(0xFF), 0xFE]), (.utf16BigEndian, [0xFE, 0xFF])] {
                try (Data(bom) + padded.data(using: encoding)!).write(to: file)
                guard case .text(let utf16Text, let limited) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
                try assertEqual(utf16Text, head)
                try assertTrue(limited)
            }

        }

        runTest("文本预览 截断不切开 UTF-8 多字节字符") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("multi.conf")
            for character in ["中", "😀"] {
                for count in 1..<character.utf8.count {
                    let prefix = Data(repeating: 65, count: 1_048_576 - count)
                    try (prefix + Data(character.utf8) + Data([66])).write(to: file)
                    guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
                    try assertEqual(Data(text.utf8), prefix)
                    try assertTrue(truncated)
                }
            }
        }

        runTest("文本预览 无换行保留限长前缀且拒绝非法内容") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("long.config")
            try Data(repeating: 65, count: 1_048_577).write(to: file)
            guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(text.utf8.count, 1_048_576)
            try assertTrue(truncated)
            for invalid in [Data([0xFF]), Data([0])] {
                try (invalid + Data(repeating: 65, count: 1_048_576)).write(to: file)
                do {
                    _ = try PreviewDocument.read(file)
                    throw TestFailure(message: "必须拒绝二进制内容")
                } catch PreviewDocumentError.invalid {}
            }
            let link = root.appendingPathComponent("link.conf")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
            for url in [link, root] {
                do {
                    _ = try PreviewDocument.read(url)
                    throw TestFailure(message: "必须拒绝符号链接与目录")
                } catch PreviewDocumentError.invalid {}
            }
        }

        runTest("文本预览 保留 UTF-16 支持与原有文档上限") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("utf16.ini")
            let head = "中文 = 内容\r\n"
            try (head + String(repeating: "中", count: 524_288)).data(using: .utf16)!.write(to: file)
            guard case .text(let text, let truncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(text, head)
            try assertTrue(truncated)
            let prefix = String(repeating: "a", count: (1_048_576 - 4) / 2)
            try (prefix + "😀").data(using: .utf16)!.write(to: file)
            guard case .text(let unicodePrefix, let unicodeTruncated) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少文本") }
            try assertEqual(unicodePrefix, prefix)
            try assertTrue(unicodeTruncated)
            for (ext, limit) in [("md", 1_048_576), ("ipynb", 5 * 1_048_576)] {
                let large = root.appendingPathComponent("large." + ext)
                try Data(repeating: 65, count: limit + 1).write(to: large)
                do {
                    if ext == "md" { _ = try PreviewDocument.readMarkdown(large) }
                    else { _ = try PreviewDocument.read(large) }
                    throw TestFailure(message: "原有文档必须保持上限")
                } catch PreviewDocumentError.tooLarge {}
            }
        }

        runTest("表格预览 简单 CSV 解析") {
            let table = PreviewDelimited.parse("a,b\n1,2\n", delimiter: ",")
            try assertEqual(table.name, "")
            try assertEqual(table.columns, ["a", "b"])
            try assertEqual(table.rows, [["1", "2"]])
            try assertTrue(!table.truncated)
        }

        runTest("表格预览 引号内逗号与转义引号") {
            let table = PreviewDelimited.parse("name,note\n\"x, y\",\"say \"\"hi\"\"\"\n", delimiter: ",")
            try assertEqual(table.columns, ["name", "note"])
            try assertEqual(table.rows, [["x, y", "say \"hi\""]])
        }

        runTest("表格预览 引号内换行清洗为空格") {
            let table = PreviewDelimited.parse("a\n\"line1\nline2\"\n", delimiter: ",")
            try assertEqual(table.rows, [["line1 line2"]])
        }

        runTest("表格预览 CRLF 与 LF 解析一致") {
            let crlf = PreviewDelimited.parse("a,b\r\n1,2\r\n", delimiter: ",")
            let lf = PreviewDelimited.parse("a,b\n1,2\n", delimiter: ",")
            try assertEqual(crlf.columns, lf.columns)
            try assertEqual(crlf.rows, lf.rows)
            try assertEqual(crlf.rows, [["1", "2"]])
        }

        runTest("表格预览 UTF-8 BOM 被去掉") {
            let table = PreviewDelimited.parse("\u{FEFF}a,b\n1,2", delimiter: ",")
            try assertEqual(table.columns, ["a", "b"])
            try assertEqual(table.rows, [["1", "2"]])
        }

        runTest("表格预览 行长度不齐末尾补空") {
            let table = PreviewDelimited.parse("a,b,c\n1\n", delimiter: ",")
            try assertEqual(table.columns, ["a", "b", "c"])
            try assertEqual(table.rows, [["1", "", ""]])
        }

        runTest("表格预览 分隔符识别与 sep 提示行") {
            try assertEqual(PreviewDelimited.detectDelimiter("a;b;c\n1;2;3").delimiter, ";")
            let sep = PreviewDelimited.detectDelimiter("sep=;\na;b\n1;2")
            try assertEqual(sep.delimiter, ";")
            try assertTrue(sep.skipFirstLine)
            let table = PreviewDelimited.parse("a;b\n1;2", delimiter: sep.delimiter)
            try assertEqual(table.columns, ["a", "b"])
            try assertEqual(table.rows, [["1", "2"]])
            try assertEqual(PreviewDelimited.detectDelimiter("a\tb").delimiter, "\t")
        }

        runTest("表格预览 超过最大行数只保留前 500 行") {
            var source = "h\n"
            for index in 0...500 { source += "\(index)\n" }
            let table = PreviewDelimited.parse(source, delimiter: ",")
            try assertEqual(table.rows.count, PreviewDelimited.maxRows)
            try assertEqual(table.rows.first, ["0"])
            try assertEqual(table.rows.last, ["499"])
            try assertTrue(table.truncated)
        }

        runTest("表格预览 超过最大列数只保留前 50 列") {
            let source = (1...60).map { "c\($0)" }.joined(separator: ",") + "\n"
                + (1...60).map { "v\($0)" }.joined(separator: ",") + "\n"
            let table = PreviewDelimited.parse(source, delimiter: ",")
            try assertEqual(table.columns.count, PreviewDelimited.maxColumns)
            try assertEqual(table.rows.count, 1)
            try assertEqual(table.rows[0].count, PreviewDelimited.maxColumns)
            try assertTrue(table.truncated)
        }

        runTest("表格预览 超长单元格截断加省略号") {
            let table = PreviewDelimited.parse("a\n\(String(repeating: "字", count: 301))\n", delimiter: ",")
            try assertEqual(table.rows[0][0].count, PreviewDelimited.maxCellCharacters)
            try assertTrue(table.rows[0][0].hasSuffix("…"))
        }

        runTest("表格预览 丢弃的末尾宽行仍决定列数与单元格上限") {
            let wide = (1...50).map { "c\($0)" }.joined(separator: ",")
            let table = PreviewDelimited.parse("h\n" + String(repeating: "v\n", count: 500) + wide, delimiter: ",")
            try assertEqual(table.columns.count, 50)
            try assertEqual(table.columns[49], "列 50")
            try assertEqual(table.rows.count, 200)
            try assertEqual(table.rows.last?.first, "v")
            try assertEqual(table.rows.last?.last, "")
            try assertTrue(table.truncated)
            for (columns, rows) in [(1, 500), (20, 500), (50, 200)] {
                let line = Array(repeating: "v", count: columns).joined(separator: ",") + "\n"
                let exact = PreviewDelimited.parse(line + String(repeating: line, count: rows), delimiter: ",")
                try assertEqual(exact.rows.count, rows)
                try assertTrue(!exact.truncated)
                let extra = PreviewDelimited.parse(line + String(repeating: line, count: rows + 1), delimiter: ",")
                try assertEqual(extra.rows.count, rows)
                try assertTrue(extra.truncated)
            }
        }

        runTest("表格预览 超出列数的字段仍正确处理引号与内嵌换行") {
            let wide = Array(repeating: "x", count: 50).joined(separator: ",")
            let table = PreviewDelimited.parse("h\n" + wide + ",\"ignored\nsay \"\"hi\"\"\"\na,b\n", delimiter: ",")
            try assertEqual(table.rows.count, 2)
            try assertEqual(table.rows[0], Array(repeating: "x", count: 50))
            try assertEqual(Array(table.rows[1].prefix(2)), ["a", "b"])
            try assertTrue(table.truncated)
        }

        runTest("表格预览 密集分隔符与空行只保留展示字段") {
            let table = PreviewDelimited.parse(String(repeating: "a,", count: 524_287) + "a", delimiter: ",")
            try assertEqual(table.columns, Array(repeating: "a", count: 50))
            try assertTrue(table.rows.isEmpty && table.truncated)
            let hint = PreviewDelimited.detectDelimiter(String(repeating: "\n", count: 10_000) + "a;b\n1;2")
            try assertEqual(hint.delimiter, ";")
            try assertTrue(!hint.skipFirstLine)
            try assertTrue(PreviewDelimited.parse("\n\"\"\n", delimiter: ",").columns.isEmpty)
        }

        runTest("表格预览 长字段截断后仍正确解析转义引号与组合字符") {
            let prefix = String(repeating: "e\u{301}", count: 299)
            let table = PreviewDelimited.parse("a,b\n\"" + prefix + "\"\"tail\",ok\nlast,row", delimiter: ",")
            try assertEqual(table.rows[0], [prefix + "…", "ok"])
            try assertEqual(table.rows[1], ["last", "row"])
            let boundary = PreviewDelimited.parse("a\n" + String(repeating: "字", count: 300), delimiter: ",")
            try assertEqual(boundary.rows[0][0], String(repeating: "字", count: 300))
            let merged = PreviewDelimited.parse("a\n\"" + String(repeating: "x", count: 298) + "\n\u{301}zq\"", delimiter: ",")
            try assertEqual(merged.rows[0][0], String(repeating: "x", count: 298) + " \u{301}…")
        }

        runTest("表格预览 GBK 编码的 CSV 读取") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            let file = root.appendingPathComponent("gbk.csv")
            try "姓名,城市\n张三,北京\n".data(using: encoding)!.write(to: file)
            try assertTrue(PreviewDocument.supports(file))
            guard case .table(let table) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少表格") }
            try assertEqual(table.columns, ["姓名", "城市"])
            try assertEqual(table.rows, [["张三", "北京"]])
            try assertTrue(!table.truncated)
        }

        runTest("表格预览 TSV 固定按制表符分列") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("data.tsv")
            try "a,b\tc\n1,2\t3\n".write(to: file, atomically: true, encoding: .utf8)
            guard case .table(let table) = try PreviewDocument.read(file) else { throw TestFailure(message: "缺少表格") }
            try assertEqual(table.columns, ["a,b", "c"])
            try assertEqual(table.rows, [["1,2", "3"]])
        }

        runTest("plist 预览 二进制转换 XML 文本") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("binary.plist")
            try PropertyListSerialization.data(fromPropertyList: ["键": "值", "n": 1], format: .binary, options: 0).write(to: file)
            try assertTrue(PreviewDocument.supports(file))
            guard case .propertyList(let text, let binary, let truncated) = try PreviewDocument.read(file) else {
                throw TestFailure(message: "缺少 plist 文本")
            }
            try assertTrue(binary)
            try assertTrue(!truncated)
            try assertTrue(text.contains("<key>键</key>"))
            try assertTrue(text.contains("<string>值</string>"))
        }

        runTest("plist 预览 XML 原文完整保留") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("plain.plist")
            let source = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
                + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
                + "<plist version=\"1.0\">\n<!-- 注释 -->\n<dict>\n\t<key>名称</key>\n\t<string>值</string>\n</dict>\n</plist>\n"
            try Data(source.utf8).write(to: file)
            guard case .propertyList(let text, let binary, let truncated) = try PreviewDocument.read(file) else {
                throw TestFailure(message: "缺少 plist 文本")
            }
            try assertEqual(text, source)
            try assertTrue(!binary)
            try assertTrue(!truncated)
        }

        runTest("plist 预览 损坏的二进制文件抛错") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("broken.plist")
            try (Data("bplist00".utf8) + Data([0x11, 0x22, 0x33, 0x44, 0x55, 0x66])).write(to: file)
            do {
                _ = try PreviewDocument.read(file)
                throw TestFailure(message: "必须拒绝损坏的二进制 plist")
            } catch PreviewDocumentError.invalid {}
        }

        runTest("表格预览 无备用编码仍拒绝非法 UTF-8") {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("invalid.conf")
            try Data([0xC3, 0x28, 0xFF]).write(to: file)
            do {
                _ = try PreviewDocument.read(file)
                throw TestFailure(message: "必须拒绝非法 UTF-8")
            } catch PreviewDocumentError.invalid {}
        }

        runTest("图片菜单：只按扩展名判定，不读取文件内容") {
            // 路径不存在也能判定：证明构建菜单时不碰磁盘
            let root = URL(fileURLWithPath: "/not-readable")
            let images = ["a.PNG", "b.jpeg", "c.heic", "d.webp", "e.tiff"].map { root.appendingPathComponent($0) }
            let state = ImageMenuState.evaluate(selection: images)
            try assertTrue(state.isAllImages)
            try assertEqual(state.formats, [.png, .jpeg, .heic, .other, .other])
            try assertTrue(ImageMenuState.evaluate(selection: [root.appendingPathComponent("x.jpg")]).allAreJPEG)
            try assertTrue(ImageMenuState.evaluate(selection: [root.appendingPathComponent("x.heif")]).allAreHEIC)
            try assertTrue(!ImageMenuState.evaluate(selection: []).isAllImages, "空选择不显示")
            try assertTrue(!ImageMenuState.evaluate(selection: images + [root.appendingPathComponent("note.txt")]).isAllImages, "混有非图片不显示")
            try assertTrue(!ImageMenuState.evaluate(selection: [root.appendingPathComponent("README")]).isAllImages, "无扩展名不显示")
            try assertTrue(!ImageMenuState.evaluate(selection: [root.appendingPathComponent("foo.png", isDirectory: true)]).isAllImages,
                           "名为 foo.png 的目录不显示")
        }

        runTest("图片菜单：按所选格式隐藏同格式转换项") {
            let allFeatures = Set(MenuFeatureCatalog.all.map(\.id))
            let detectedState = ImageMenuState.evaluate(selection: [URL(fileURLWithPath: "/tmp/photo.png")])
            let input = MenuBuildInput(
                location: .items,
                selection: .singleFile(isTextEligible: false, isArchive: false),
                enabledFeatureIds: allFeatures,
                imageMenuState: detectedState
            )
            let nodes = MenuTreeBuilder.buildMenuTree(input: input)
            guard let imgNode = nodes.first(where: { $0.id == MenuFeatureCatalog.imageTools }),
                  case .submenu(let children) = imgNode.kind else {
                throw TestFailure(message: "应该显示图片子菜单")
            }
            let childIds = children.map(\.id)
            try assertTrue(!childIds.contains("image.convertToPNG"), "PNG 应隐藏转换为 PNG")
            try assertTrue(childIds.contains("image.convertToJPEG"), "显示转换为 JPEG")
            try assertTrue(childIds.contains("image.convertToHEIC"), "显示转换为 HEIC")
            var hiddenInput = input
            hiddenInput.location = .container
            try assertTrue(!MenuTreeBuilder.buildMenuTree(input: hiddenInput).contains { $0.id == MenuFeatureCatalog.imageTools })
            hiddenInput = input
            hiddenInput.enabledFeatureIds.remove(MenuFeatureCatalog.imageTools)
            try assertTrue(!MenuTreeBuilder.buildMenuTree(input: hiddenInput).contains { $0.id == MenuFeatureCatalog.imageTools })
            try assertTrue(!MenuFeatureCatalog.disabledByDefault.contains(MenuFeatureCatalog.imageTools))
            try assertEqual(ImageSourceFormat.from(uti: "public.jpeg-2000" as CFString), .other)
            for (format, hiddenID) in [(ImageSourceFormat.jpeg, "image.convertToJPEG"), (.heic, "image.convertToHEIC")] {
                var formatInput = input
                formatInput.imageMenuState = ImageMenuState(isAllImages: true, formats: [format])
                guard let menu = MenuTreeBuilder.buildMenuTree(input: formatInput).first(where: { $0.id == MenuFeatureCatalog.imageTools }),
                      case .submenu(let formatChildren) = menu.kind else { throw TestFailure(message: "缺少图片子菜单") }
                try assertTrue(!formatChildren.contains { $0.id == hiddenID })
            }

        }

        runTest("图片处理：实际输出命名重名和悬空链接不覆盖") {
            let (file, directory) = makeTestPNG(width: 100, height: 50, fillColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            defer { try? FileManager.default.removeItem(at: directory) }
            let base = file.deletingPathExtension().lastPathComponent
            let original = try Data(contentsOf: file)
            let first = try transformTestImage(sourceURL: file, operation: .convert(format: .jpeg))
            try assertEqual(first.lastPathComponent, base + ".jpg")
            let link = directory.appendingPathComponent(base + " 1.jpg")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-target")
            let second = try transformTestImage(sourceURL: file, operation: .convert(format: .jpeg))
            try assertEqual(second.lastPathComponent, base + " 2.jpg")
            try assertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "missing-target")
            try assertEqual(try Data(contentsOf: file), original)
        }

        runTest("图片处理：实际缩放尺寸命名与不放大") {
            let (file, directory) = makeTestPNG(width: 100, height: 50, fillColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            defer { try? FileManager.default.removeItem(at: directory) }
            for target in [100, 1920] {
                do {
                    _ = try transformTestImage(sourceURL: file, operation: .scale(maxPixelSize: target))
                    throw TestFailure(message: "不得放大或重复输出相同大小图片")
                } catch ImageTransformError.alreadySmallerThanTarget(let edge, let requested) {
                    try assertEqual(edge, 100)
                    try assertEqual(requested, target)
                }
            }
            let output = try transformTestImage(sourceURL: file, operation: .scale(maxPixelSize: 40))
            try assertEqual(output.lastPathComponent, file.deletingPathExtension().lastPathComponent + " 40px.png")
            let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
            try assertEqual(CGImageSourceGetType(source) as String?, "public.png")
            let (width, height, _, _) = try ImageTransformer.inspectImageSource(source)
            try assertEqual(width, 40)
            try assertEqual(height, 20)
        }

        runTest("图片处理：异常缩放尺寸与非普通文件拒绝") {
            let (file, directory) = makeTestPNG(width: 20, height: 10, fillColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            defer { try? FileManager.default.removeItem(at: directory) }
            for target in [0, -1, 2561, Int.max] {
                do {
                    _ = try transformTestImage(sourceURL: file, operation: .scale(maxPixelSize: target))
                    throw TestFailure(message: "必须拒绝异常尺寸")
                } catch ImageTransformError.invalidScaleSize {}
            }
            do {
                _ = try transformTestImage(sourceURL: directory, operation: .convert(format: .png))
                throw TestFailure(message: "必须拒绝目录")
            } catch ImageTransformError.cannotReadImageSource {}
        }

        runTest("图片处理：非对称双色图旋转后断言两个像素方位与方向重置") {
            // 构造宽 200 高 100 的非对称双色图（左半红、右半蓝），设置 EXIF 方向 6（顺时针旋转 90 度）
            let (jpegFile, tempDir) = makeTestAsymmetricDualColorJPEG(width: 200, height: 100, orientation: 6)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 缩放到 150 像素（原长边 200 > 150，应用旋转后高为 150，宽为 75）
            let scaledURL = try transformTestImage(sourceURL: jpegFile, operation: .scale(maxPixelSize: 150))
            defer { try? FileManager.default.removeItem(at: scaledURL) }

            guard let src = CGImageSourceCreateWithURL(scaledURL as CFURL, nil) else {
                throw TestFailure(message: "无法读取缩放后的 JPEG")
            }
            let (w, h, _, props) = try ImageTransformer.inspectImageSource(src)

            // 1. 断言输出方向重置为 1
            let outOrientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
            try assertEqual(outOrientation, 1, "输出方向必须重置为 1 (TopLeft)")

            // 2. 变换后尺寸
            try assertEqual(h, 150, "顺时针旋转 90 度后高为长边 150")
            try assertEqual(w, 75, "顺时针旋转 90 度后宽为短边 75")

            // 3. 断言旋转后至少两个像素方位：
            guard let topPixel = getPixelRGB(at: CGPoint(x: 37, y: 35), from: scaledURL),
                  let bottomPixel = getPixelRGB(at: CGPoint(x: 37, y: 115), from: scaledURL) else {
                throw TestFailure(message: "无法获取变换后两个方位的像素")
            }
            // 顺时针旋转 90 度校正后，上方方位为蓝色 (B 高，R 低)，下方方位为红色 (R 高，B 低)
            try assertTrue(topPixel.b > 200 && topPixel.r < 50, "上方像素方位应为蓝色，实际: (\(topPixel.r), \(topPixel.g), \(topPixel.b))")
            try assertTrue(bottomPixel.r > 200 && bottomPixel.b < 50, "下方像素方位应为红色，实际: (\(bottomPixel.r), \(bottomPixel.g), \(bottomPixel.b))")
        }

        runTest("图片处理：HEIC 格式转换可读回与元数据清洗") {
            let (jpegFile, tempDir) = makeTestJPEGWithOldMetadata(width: 200, height: 100)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 转换为 HEIC
            let heicURL = try transformTestImage(sourceURL: jpegFile, operation: .convert(format: .heic))
            defer { try? FileManager.default.removeItem(at: heicURL) }

            // 断言可正常读回
            guard let src = CGImageSourceCreateWithURL(heicURL as CFURL, nil) else {
                throw TestFailure(message: "HEIC 转换结果无法通过 ImageIO 读回")
            }
            let (w, h, count, props) = try ImageTransformer.inspectImageSource(src)
            try assertEqual(count, 1, "单帧 HEIC")
            try assertEqual(w, 100, "应用方向校正后宽为 100")
            try assertEqual(h, 200, "应用方向校正后高为 200")

            // 元数据清洗断言：顶层方向重置为 1
            let outOrientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 0
            try assertEqual(outOrientation, 1, "HEIC 输出顶层方向必须重置为 1")

            // TIFF 字典若存在，方向重置为 1，且不应残留旧的尺寸键
            if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                let tiffOrient = (tiff[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue ?? 1
                try assertEqual(tiffOrient, 1)
                try assertNil(tiff["ImageWidth" as CFString], "TIFF 字典不应残留旧尺寸")
                try assertNil(tiff["ImageLength" as CFString], "TIFF 字典不应残留旧尺寸")
            }

            // Exif 字典若存在，不应残留旧尺寸
            if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                try assertNil(exif[kCGImagePropertyExifPixelXDimension], "Exif 字典不应残留旧尺寸")
                try assertNil(exif[kCGImagePropertyExifPixelYDimension], "Exif 字典不应残留旧尺寸")
            }
        }

        runTest("图片处理：WebP 格式支持转换输入，但直接缩放明确跳过并提示原因") {
            let (webpFile, tempDir) = makeTestWebP()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 1. 允许作为转换输入：WebP -> PNG
            let pngURL = try transformTestImage(sourceURL: webpFile, operation: .convert(format: .png))
            defer { try? FileManager.default.removeItem(at: pngURL) }
            guard let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil) else {
                throw TestFailure(message: "无法读取转换自 WebP 的 PNG")
            }
            let (w, h, _, _) = try ImageTransformer.inspectImageSource(src)
            try assertEqual(w, 100)
            try assertEqual(h, 100)

            // 2. 缩放 WebP：系统不支持写入 WebP，应明确跳过并抛出原因，禁止静默改变格式
            var rejected = false
            do {
                _ = try transformTestImage(sourceURL: webpFile, operation: .scale(maxPixelSize: 50))
            } catch let err as ImageTransformError {
                if case .unwritableSourceFormat(let ext) = err {
                    try assertEqual(ext.lowercased(), "webp")
                    rejected = true
                }
            }
            try assertTrue(rejected, "WebP 缩放应明确拒绝并告知不可写原因")
        }

        runTest("图片处理：预解码尺寸上限与乘法溢出检查") {
            try ImageTransformer.validateConversionSize(width: 8000, height: 5000)
            for (width, height) in [(10_000, 10_000), (Int.max, 2)] {
                do {
                    try ImageTransformer.validateConversionSize(width: width, height: height)
                    throw TestFailure(message: "必须在解码前拦截超大位图")
                } catch ImageTransformError.pixelCountExceedsLimit(_, let limit) {
                    try assertEqual(limit, 40_000_000)
                }
            }
        }

        runTest("图片处理：缩放撤销文案使用图片处理避免错称转换") {
            let id: (String) -> String = { $0 }
            let scaleSingle = UndoText.actionDescription(kind: .scaleImage, count: 1, name: "photo 1920px.png", localize: id)
            try assertEqual(scaleSingle, "图片处理“photo 1920px.png”")

            let scaleMultiple = UndoText.actionDescription(kind: .scaleImage, count: 3, name: "", localize: id)
            try assertEqual(scaleMultiple, "图片处理（3 项）")

            let convertSingle = UndoText.actionDescription(kind: .convertImage, count: 1, name: "photo.jpg", localize: id)
            try assertEqual(convertSingle, "转换“photo.jpg”")
        }

        runTest("图片处理：无透明通道时复用原图，不创建白底位图") {
            for alpha in [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast] {
                let space = CGColorSpace(name: alpha == .none ? CGColorSpace.genericGrayGamma2_2 : CGColorSpace.displayP3)!
                let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8,
                                        bytesPerRow: 0, space: space, bitmapInfo: alpha.rawValue)!
                context.setFillColor(CGColor(gray: 0.5, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
                let original = context.makeImage()!
                let result = try ImageTransformer.flattenOnWhiteBackground(original)
                try assertTrue(result === original, "无 Alpha 图像应直接复用，保持像素与色彩空间")
                try assertEqual(result.colorSpace?.name, space.name)
            }
        }

        runTest("图片处理：不透明图转 JPEG 保持颜色、校正方向并保留源文件") {
            let (file, directory) = makeTestAsymmetricDualColorJPEG(width: 200, height: 100, orientation: 6)
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = try Data(contentsOf: file)
            let output = try transformTestImage(sourceURL: file, operation: .convert(format: .jpeg))
            let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
            let (width, height, _, properties) = try ImageTransformer.inspectImageSource(source)
            try assertEqual(width, 100)
            try assertEqual(height, 200)
            try assertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue, 1)
            let top = getPixelRGB(at: CGPoint(x: 50, y: 40), from: output)!
            let bottom = getPixelRGB(at: CGPoint(x: 50, y: 160), from: output)!
            try assertTrue(top.b > 200 && top.r < 50)
            try assertTrue(bottom.r > 200 && bottom.b < 50)
            try assertEqual(try Data(contentsOf: file), original)
            try assertTrue(output != file)
        }

        runTest("图片处理：透明 PNG 转 JPEG 后角落像素为白色") {
            // 创建四周透明、中心红色的 PNG
            let (pngFile, tempDir) = makeTestPNG(width: 100, height: 100, fillColor: CGColor(red: 1, green: 0, blue: 0, alpha: 1), hasAlpha: true)
            defer { try? FileManager.default.removeItem(at: tempDir) }

            // 转换为 JPEG
            let jpegURL = try transformTestImage(sourceURL: pngFile, operation: .convert(format: .jpeg))
            defer { try? FileManager.default.removeItem(at: jpegURL) }

            // 检查角落 (0, 0) 像素：在透明转 JPEG 后必须铺白底，RGB 应为白色 (>= 240)
            guard let rgb = getPixelRGB(at: CGPoint(x: 0, y: 0), from: jpegURL) else {
                throw TestFailure(message: "无法获取角落像素 RGB")
            }
            try assertTrue(rgb.r >= 240 && rgb.g >= 240 && rgb.b >= 240, "透明角落转 JPEG 必须为白色，实际为: (\(rgb.r), \(rgb.g), \(rgb.b))")
        }

        runTest("图片处理：多帧图片被拒绝") {
            let (gifFile, tempDir) = makeMultiFrameGIF()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            var rejected = false
            do {
                _ = try transformTestImage(sourceURL: gifFile, operation: .convert(format: .png))
            } catch let err as ImageTransformError {
                if case .multiFrameNotSupported(let count) = err {
                    try assertEqual(count, 2)
                    rejected = true
                }
            }
            try assertTrue(rejected, "多帧动图应被明确拒绝并跳过")
        }
    }
}
