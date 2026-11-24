import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

// 解压落位与操作记录
enum ExtractTests {
    static func run() {
        // MARK: - ExtractedOutput（解压产物落位）

        /// 在 work 下建一个模拟的解压输出目录，按 names 创建内容（以 / 结尾为目录）
        func makeExtractedRoot(in work: URL, _ names: [String]) throws -> URL {
            let root = work.appendingPathComponent(".scratch/out", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for name in names {
                let url = root.appendingPathComponent(name)
                if name.hasSuffix("/") {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    try Data("x".utf8).write(to: url.appendingPathComponent("inner.txt"))
                } else {
                    try Data("x".utf8).write(to: url)
                }
            }
            return root
        }

        runTest("ExtractedOutput 顶层唯一文件夹直接放出，忽略 __MACOSX 与 .DS_Store") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let root = try makeExtractedRoot(in: work, ["foo/", "__MACOSX/", ".DS_Store"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "foo")
            try assertEqual(placed.lastPathComponent, "foo")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("inner.txt").path), "不应出现 foo/foo 嵌套")
        }

        runTest("ExtractedOutput 唯一文件夹重名时编号为 -2") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("foo"), withIntermediateDirectories: false)
            let root = try makeExtractedRoot(in: work, ["foo/"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "foo")
            try assertEqual(placed.lastPathComponent, "foo-2")
        }

        runTest("ExtractedOutput 唯一文件重名时保留扩展名") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try Data().write(to: work.appendingPathComponent("report.pdf"))
            let root = try makeExtractedRoot(in: work, ["report.pdf"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "report")
            try assertEqual(placed.lastPathComponent, "report-2.pdf")
        }

        runTest("ExtractedOutput 多项时整体放入同名文件夹") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            try FileManager.default.createDirectory(at: work.appendingPathComponent("bundle"), withIntermediateDirectories: false)
            let root = try makeExtractedRoot(in: work, ["a.txt", "b/"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "bundle")
            try assertEqual(placed.lastPathComponent, "bundle-2", "已有同名文件夹时编号")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("a.txt").path))
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("b/inner.txt").path))
        }

        runTest("ExtractedOutput 唯一项为隐藏文件或空包时仍放入文件夹") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let hidden = try makeExtractedRoot(in: work, [".env"])
            let placedHidden = try ExtractedOutput.place(extractedRoot: hidden, into: work, folderName: "cfg")
            try assertEqual(placedHidden.lastPathComponent, "cfg")
            try assertTrue(FileManager.default.fileExists(atPath: placedHidden.appendingPathComponent(".env").path))

            let empty = try makeExtractedRoot(in: work, [])
            let placedEmpty = try ExtractedOutput.place(extractedRoot: empty, into: work, folderName: "empty")
            try assertEqual(placedEmpty.lastPathComponent, "empty")
        }

        runTest("ExtractedOutput 以 ._ 开头的普通文件计入顶层项，不随暂存目录丢失") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let root = try makeExtractedRoot(in: work, ["foo/", "._notes.txt"])
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "pack")
            try assertEqual(placed.lastPathComponent, "pack", "两项应整体放入文件夹")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("._notes.txt").path))
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("foo/inner.txt").path))
        }

        runTest("ExtractedOutput 顶层 AppleDouble 与 __MACOSX 一样忽略") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let root = try makeExtractedRoot(in: work, ["foo/"])
            try Data([0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00]).write(to: root.appendingPathComponent("._foo"))
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "foo")
            try assertEqual(placed.lastPathComponent, "foo")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("inner.txt").path), "不应出现 foo/foo 嵌套")
        }

        runTest("ExtractedOutput 真实 ditto 往返：foo.zip 解出 foo 而非 foo/foo") {
            let work = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let folder = work.appendingPathComponent("foo", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("x".utf8).write(to: folder.appendingPathComponent("a.txt"))
            let zip = try ZipCompressor.compress(items: [folder], into: work, baseName: "foo",
                                                 registry: ScratchDirectoryRegistry(registryDirectory: work))
            try FileManager.default.removeItem(at: folder)

            let root = work.appendingPathComponent(".scratch/out", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                                               arguments: ["-x", "-k", zip.path, root.path])
            try assertEqual(result.status, 0, result.stderr)
            let placed = try ExtractedOutput.place(extractedRoot: root, into: work, folderName: "foo")
            try assertEqual(placed.lastPathComponent, "foo")
            try assertTrue(FileManager.default.fileExists(atPath: placed.appendingPathComponent("a.txt").path))
        }

        runTest("ExtractedOutput 候选名编号规则") {
            try assertEqual(ExtractedOutput.candidateName("foo", keepExtension: false, attempt: 0), "foo")
            try assertEqual(ExtractedOutput.candidateName("foo", keepExtension: false, attempt: 1), "foo-2")
            try assertEqual(ExtractedOutput.candidateName("v1.2", keepExtension: false, attempt: 2), "v1.2-3", "普通文件夹不拆扩展名")
            try assertEqual(ExtractedOutput.candidateName("Foo.app", keepExtension: true, attempt: 1), "Foo-2.app")
            try assertEqual(ExtractedOutput.candidateName("README", keepExtension: true, attempt: 1), "README-2")
        }

        // MARK: - RecentOperations（最近操作记录）

        runTest("RecentOperations 新记录在前、超出容量丢弃最旧与清空") {
            let ops = RecentOperations(capacity: 3)
            ops.record(OperationRecord(kind: .compress, subject: "a"))
            ops.record(OperationRecord(kind: .decompress, subject: "b", failure: "坏包"))
            ops.record(OperationRecord(kind: .paste, subject: "c"))
            ops.record(OperationRecord(kind: .compress, subject: "d", failure: "磁盘满"))
            try assertEqual(ops.records.map(\.subject), ["d", "c", "b"])
            try assertEqual(ops.records.count, 3)
            ops.clear()
            try assertTrue(ops.records.isEmpty)
        }

        runTest("RecentOperations 已取消不算成功但正常记录") {
            let ops = RecentOperations(capacity: 3)
            let cancelled = OperationRecord(kind: .decompress, subject: "secret.zip", cancelled: true)
            try assertTrue(!cancelled.succeeded, "已取消不算成功")
            ops.record(cancelled)
            try assertEqual(ops.records.first?.cancelled, true)
            try assertEqual(ops.records.first?.subject, "secret.zip")
        }

        runTest("RecentOperations 容量为0时不保留历史记录") {
            let ops = RecentOperations(capacity: 0)
            try assertEqual(ops.capacity, 0)
            ops.record(OperationRecord(kind: .compress, subject: "a", failure: "坏包"))
            try assertTrue(ops.records.isEmpty, "容量为0不记录到内存")
        }

        runTest("RecentOperations 排序裁剪与恢复时按日期排序") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history-sort.json")
            let ops = RecentOperations(capacity: 3, storageURL: fileURL)

            let now = Date()
            let r1 = OperationRecord(kind: .copy, subject: "1", date: now.addingTimeInterval(-30))
            let r2 = OperationRecord(kind: .move, subject: "2", date: now.addingTimeInterval(-20))
            let r3 = OperationRecord(kind: .createFile, subject: "3", date: now.addingTimeInterval(-10))
            let r4 = OperationRecord(kind: .cut, subject: "4", date: now)

            ops.record(r1)
            ops.record(r2)
            ops.record(r3)
            ops.record(r4)
            ops.record(OperationRecord(kind: .copy, subject: "older", date: now.addingTimeInterval(-100)))

            try assertEqual(ops.records.map(\.subject), ["4", "3", "2"], "迟到的旧记录不能挤掉较新的记录")

            let restored = RecentOperations(capacity: 2, storageURL: fileURL)
            try assertEqual(restored.records.map(\.subject), ["4", "3"])
        }

        runTest("RecentOperations 重启恢复字段及UUID与权限保护") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history-fields.json")
            let ops = RecentOperations(capacity: 10, storageURL: fileURL)

            let customID = UUID()
            let locationURL = URL(fileURLWithPath: "/tmp/project")
            let results = [URL(fileURLWithPath: "/tmp/project/a.txt"), URL(fileURLWithPath: "/tmp/project/b.txt")]
            let date = Date()

            let record = OperationRecord(
                id: customID,
                kind: .createFile,
                subject: "new-file.swift",
                failure: "权限不足",
                results: results,
                cancelled: false,
                date: date,
                location: locationURL
            )
            ops.record(record)

            let restored = RecentOperations(capacity: 10, storageURL: fileURL)
            try assertEqual(restored.records.count, 1)
            guard let item = restored.records.first else {
                throw TestFailure(message: "恢复记录为空")
            }
            try assertEqual(item.id, customID, "UUID 保持一致")
            try assertEqual(item.kind, .createFile)
            try assertEqual(item.subject, "new-file.swift")
            try assertEqual(item.failure, "权限不足")
            try assertEqual(item.results, results)
            try assertEqual(item.cancelled, false)
            try assertEqual(item.location, locationURL)
            try assertEqual(item.succeeded, false)

            let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            if let permissions = attrs[.posixPermissions] as? NSNumber {
                try assertEqual(permissions.intValue, 0o600, "持久化文件权限必须为仅用户可读写 0o600")
            }
        }

        runTest("RecentOperations 容量缩减与设置为0立即清空磁盘与内存") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history-capacity.json")
            let ops = RecentOperations(capacity: 5, storageURL: fileURL)

            for i in 1...5 {
                ops.record(OperationRecord(kind: .compress, subject: "item-\(i)"))
            }
            try assertEqual(ops.records.count, 5)
            try assertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            ops.setCapacity(2)
            try assertEqual(ops.capacity, 2)
            try assertEqual(ops.records.map(\.subject), ["item-5", "item-4"])

            let reloaded = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertEqual(reloaded.records.map(\.subject), ["item-5", "item-4"])

            ops.setCapacity(0)
            try assertEqual(ops.capacity, 0)
            try assertTrue(ops.records.isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: fileURL.path), "容量为0时磁盘文件必须被清空删除")
        }

        runTest("RecentOperations 清空后重载") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history-clear.json")
            let ops = RecentOperations(capacity: 5, storageURL: fileURL)
            ops.record(OperationRecord(kind: .paste, subject: "paste-item"))
            try assertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            ops.clear()
            try assertTrue(ops.records.isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: fileURL.path))

            let reloaded = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertTrue(reloaded.records.isEmpty)
            try assertNil(reloaded.persistenceError)
        }

        runTest("RecentOperations 损坏与不可写路径容错") {
            let dir = makeTempDirectory()
            let corruptURL = dir.appendingPathComponent("corrupt.json")
            try "invalid json content".write(to: corruptURL, atomically: true, encoding: .utf8)

            let corruptOps = RecentOperations(capacity: 5, storageURL: corruptURL)
            try assertTrue(corruptOps.records.isEmpty, "损坏文件加载后内存保持为空")
            try assertTrue(corruptOps.persistenceError != nil, "损坏文件需记录 persistenceError")
            corruptOps.setCapacity(5)
            try assertTrue(corruptOps.persistenceError != nil, "启动时同步相同容量不能抹掉加载失败信息")
            try assertEqual(try String(contentsOf: corruptURL), "invalid json content")

            let roDir = dir.appendingPathComponent("read-only-folder", isDirectory: true)
            try FileManager.default.createDirectory(at: roDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: roDir.path)

            let roOps = RecentOperations(capacity: 5, storageURL: roDir.appendingPathComponent("history.json"))
            roOps.record(OperationRecord(kind: .copy, subject: "fallback-item"))
            try assertEqual(roOps.records.map(\.subject), ["fallback-item"], "不可写时内存仍应保留")
            try assertTrue(roOps.persistenceError != nil, "写入失败需记录 persistenceError")

            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: roDir.path)
        }

        runTest("RecentOperations 无法识别的记录逐条跳过并正常继续保存") {
            let dir = makeTempDirectory()
            let fileURL = dir.appendingPathComponent("history.json")
            let known = OperationRecord(kind: .copy, subject: "known", date: Date())
            // 模拟降级：新版本写入了旧版本不认识的操作类型
            var entries = try JSONSerialization.jsonObject(with: JSONEncoder().encode([known])) as! [[String: Any]]
            var future = entries[0]
            future["id"] = UUID().uuidString
            future["kind"] = "futureKind"
            future["subject"] = "from-newer-version"
            entries.insert(future, at: 0)
            let original = try JSONSerialization.data(withJSONObject: entries)
            try original.write(to: fileURL)

            let ops = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertEqual(ops.records.map(\.subject), ["known"], "可识别的记录照常加载")
            try assertNil(ops.persistenceError)

            ops.record(OperationRecord(kind: .paste, subject: "new"))
            let reloaded = RecentOperations(capacity: 5, storageURL: fileURL)
            try assertEqual(reloaded.records.map(\.subject), ["new", "known"])
        }

        runTest("RecentOperations 容量0仍发完成事件") {
            var receivedRecord: OperationRecord?
            var onMainThread = false
            let observer = NotificationCenter.default.addObserver(
                forName: RecentOperations.didFinishNotification,
                object: nil,
                queue: nil
            ) { notif in
                onMainThread = Thread.isMainThread
                receivedRecord = notif.object as? OperationRecord
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let ops = RecentOperations(capacity: 0, storageURL: nil)
            let rec = OperationRecord(kind: .cut, subject: "zero-capacity-event.txt")
            ops.record(rec)

            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))

            try assertTrue(onMainThread, "完成事件必须在主线程发出")
            try assertEqual(receivedRecord?.subject, "zero-capacity-event.txt")
            try assertEqual(receivedRecord?.kind, .cut)
            try assertTrue(ops.records.isEmpty, "容量为0时不保留在内存历史中")
        }

        runTest("RecentOperations 清空历史不影响独立UndoCenter实例") {
            let dir = makeTempDirectory()
            let center = UndoCenter(stateDirectory: dir)
            let fp = FileFingerprint(fileNumber: 1, device: 1, isDirectory: false, modificationDate: nil, size: 0)
            let move = UndoRecord(kind: .move, name: "Projects", items: [
                .init(current: URL(fileURLWithPath: "/tmp/Projects/a"), original: URL(fileURLWithPath: "/tmp/a"), fingerprint: fp)
            ], cutQueueBefore: nil, finderSnapshot: nil)
            center.register(move)
            try assertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(UndoMenuState.fileName).path))

            let historyURL = dir.appendingPathComponent("operation-history.json")
            let ops = RecentOperations(capacity: 5, storageURL: historyURL)
            ops.record(OperationRecord(kind: .move, subject: "Projects"))
            try assertTrue(FileManager.default.fileExists(atPath: historyURL.path))

            ops.clear()
            try assertTrue(ops.records.isEmpty)
            try assertTrue(!FileManager.default.fileExists(atPath: historyURL.path), "历史记录文件被删除")

            try assertEqual(center.current, move, "UndoCenter 内存记录保持完整")
            try assertEqual(UndoMenuState.read(from: dir), UndoMenuState(kind: .move, count: 1, name: "Projects"), "Undo 状态文件保持完整")
        }

        runTest("RecentOperations capacityKey与范围限制") {
            try assertEqual(RecentOperations.capacityKey, "operationHistoryLimit")
            let opsClampMax = RecentOperations(capacity: 999)
            try assertEqual(opsClampMax.capacity, 500, "容量最多500")
            let opsClampMin = RecentOperations(capacity: -10)
            try assertEqual(opsClampMin.capacity, 0, "容量最小为0")
        }

        runTest("OperationRecord.summary 压缩长错误输出") {
            try assertTrue(OperationRecord.summary(of: "  \n \n") == nil, "全空返回 nil")
            try assertEqual(OperationRecord.summary(of: "\n  tar: bad header  \n"), "tar: bad header")
            try assertEqual(OperationRecord.summary(of: "1\n2\n3\n4\n5"), "1\n2\n3\n…", "超过行数时标出省略")
            let long = String(repeating: "x", count: 400)
            try assertEqual(OperationRecord.summary(of: long)?.count, 301, "截断到上限并加省略号")
        }

        runTest("OperationRecord.truncatedSubject 按显示宽度从中间截断") {
            try assertEqual(OperationRecord.truncatedSubject("report.pdf"), "report.pdf", "未超宽原样返回")
            try assertEqual(OperationRecord.truncatedSubject("3 个项目"), "3 个项目")
            let latin = OperationRecord.truncatedSubject("quarterly-business-review-final-version-3.pptx", maxWidth: 20)
            try assertEqual(latin, "quarterly-bu…-3.pptx", "开头多、结尾少，保留扩展名")
            let cjk = OperationRecord.truncatedSubject("2026年第三季度项目汇报材料-最终版-v3.pptx", maxWidth: 32)
            try assertTrue(cjk.hasPrefix("2026年第三季度") && cjk.hasSuffix("-v3.pptx"), "全角字符按 2 计宽：\(cjk)")
            try assertTrue(cjk.contains("…"))
            let widthOf: (String) -> Int = { $0.reduce(0) { $0 + (($1.unicodeScalars.first!.value >= 0x2E80) ? 2 : 1) } }
            try assertTrue(widthOf(cjk) <= 32, "截断后不超过上限：\(widthOf(cjk))")
        }

        runTest("OfficeTemplate 只接受白名单内的模板 id") {
            try assertEqual(OfficeTemplate.allCases.map(\.fileExtension), ["docx", "xlsx", "pptx"])
            try assertTrue(OfficeTemplate.allCases.allSatisfy { $0.titleKey.hasSuffix("(.\($0.fileExtension))") }, "显示名须与扩展名一致")
            try assertEqual(OfficeTemplate(rawValue: "docx"), .docx)
            try assertTrue(OfficeTemplate(rawValue: "doc") == nil, "旧二进制格式不在白名单")
            try assertTrue(OfficeTemplate(rawValue: "DOCX") == nil, "大小写必须精确匹配")
            try assertTrue(OfficeTemplate(rawValue: "../docx") == nil, "路径片段不会被当作模板 id")
        }
    }
}
