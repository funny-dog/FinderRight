import Foundation
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

// MARK: - 压缩 / 解压

extension FinderRightService {

    func compressZip(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, let first = items.first else {
            return IPCResponse(id: req.id, success: false, message: "compressZip 参数缺失")
        }
        let dir = URL(fileURLWithPath: first).deletingLastPathComponent()
        let name = items.count == 1
            ? URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent
            : "Archive"
        let itemURLs = items.map { URL(fileURLWithPath: $0) }

        // 异步派发到归档专用队列，IPC 立即返回「已受理」。最终文件名在任务完成时才原子确定
        // （见 ZipCompressor），排队中的同名压缩任务不会互相覆盖
        let subject = Self.subject(forPaths: items)
        Self.backgroundJobs.run(on: Self.archiveQueue) { [weak self] in
            do {
                let zip = try ZipCompressor.compress(items: itemURLs, into: dir, baseName: name)
                self?.registerUndo(.compress, name: zip.lastPathComponent, items: [(zip, nil)])
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([zip])
                }
                self?.serviceLog("compressZip succeeded: \(zip.path)")
                RecentOperations.shared.record(OperationRecord(kind: .compress, subject: subject, results: [zip], location: dir))
            } catch {
                self?.serviceLog("compressZip failed: \(error)")
                RecentOperations.shared.record(OperationRecord(
                    kind: .compress, subject: subject, failure: Self.describe(compressError: error), location: dir))
            }
        }

        return IPCResponse(id: req.id, success: true, message: "已受理压缩任务，正在后台处理")
    }
    func decompress(_ req: IPCRequest) -> IPCResponse {
        guard let archive = req.payload["archive"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "decompress 参数缺失")
        }
        let url = URL(fileURLWithPath: archive)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return IPCResponse(id: req.id, success: false, message: String(format: L("压缩文件不存在：%@"), archive))
        }

        // 异步派发到归档专用队列，XPC 立即返回“已受理”
        Self.backgroundJobs.run(on: Self.archiveQueue) { [weak self] in
            guard let self else { return }
            let subject = url.lastPathComponent
            switch self.performDecompress(url: url) {
            case .success(let output):
                self.registerUndo(.decompress, name: output.lastPathComponent, items: [(output, nil)])
                RecentOperations.shared.record(OperationRecord(kind: .decompress, subject: subject, results: [output], location: url.deletingLastPathComponent()))
            case .failure(let failure) where failure.cancelled:
                RecentOperations.shared.record(OperationRecord(kind: .decompress, subject: subject, cancelled: true, location: url.deletingLastPathComponent()))
            case .failure(let failure):
                RecentOperations.shared.record(OperationRecord(kind: .decompress, subject: subject, failure: failure.message, location: url.deletingLastPathComponent()))
            }
        }

        return IPCResponse(id: req.id, success: true, message: "已受理解压任务，正在后台处理")
    }

    /// 后台操作失败的用户可读原因（显示在操作历史中）
    private struct OperationFailure: Error {
        let message: String
        /// 用户主动取消（加密包的密码框点了「取消」），不算失败
        var cancelled = false

        static let cancelled = OperationFailure(message: "", cancelled: true)
    }

    /// 子进程失败的原因：优先用 stderr 摘要，stderr 为空时退回退出码
    private static func toolFailure(_ result: ProcessRunner.Result) -> OperationFailure {
        toolFailure(status: result.status, stderr: result.stderr)
    }

    private static func toolFailure(status: Int32, stderr: String) -> OperationFailure {
        OperationFailure(message: OperationRecord.summary(of: stderr)
            ?? String(format: L("解压工具退出码 %d"), status))
    }

    private func performDecompress(url: URL) -> Result<URL, OperationFailure> {
        let fileManager = FileManager.default
        let dir = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        let lower = filename.lowercased()
        let archive = url.path

        let isTarGz = lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz")
        let isTarBz2 = lower.hasSuffix(".tar.bz2") || lower.hasSuffix(".tbz")
        let isTarXz = lower.hasSuffix(".tar.xz") || lower.hasSuffix(".txz")
        let isBareGz = lower.hasSuffix(".gz") && !isTarGz
        let isBareBz2 = lower.hasSuffix(".bz2") && !isTarBz2
        let isBareXz = lower.hasSuffix(".xz") && !isTarXz

        // 裸 .gz / .bz2 / .xz 单文件（非 tar 归档）：bsdtar 无法识别此类单文件流，使用对应流式解压工具输出到文件
        if isBareGz || isBareBz2 || isBareXz {
            let rawTargetName = (filename as NSString).deletingPathExtension
            let rawURL = URL(fileURLWithPath: rawTargetName)
            let rawBase = rawURL.deletingPathExtension().lastPathComponent
            let rawExt = rawURL.pathExtension

            var targetFileURL = dir.appendingPathComponent(rawTargetName)
            var counter = 2
            while fileManager.fileExists(atPath: targetFileURL.path) {
                let candidateName = rawExt.isEmpty ? "\(rawBase)-\(counter)" : "\(rawBase)-\(counter).\(rawExt)"
                targetFileURL = dir.appendingPathComponent(candidateName)
                counter += 1
            }

            fileManager.createFile(atPath: targetFileURL.path, contents: nil)
            guard let outHandle = try? FileHandle(forWritingTo: targetFileURL) else {
                serviceLog("无法创建解压目标文件: \(targetFileURL.path)")
                return .failure(OperationFailure(message: L("无法在当前目录创建文件")))
            }

            if isBareXz {
                // .xz 用系统 Compression 框架进程内解压：macOS 不自带 xz，旧实现会以 FDA 身份执行用户可写的
                // /opt/homebrew/bin/xz，或调用 /usr/bin/python3 而在未装开发者工具的机器上弹出安装框
                do {
                    try XZDecompressor.decompress(from: url, to: outHandle)
                    try? outHandle.close()
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([targetFileURL])
                    }
                    serviceLog("decompress single file succeeded: \(targetFileURL.path)")
                    return .success(targetFileURL)
                } catch {
                    try? outHandle.close()
                    try? fileManager.removeItem(at: targetFileURL)
                    serviceLog("decompress .xz failed: \(error)")
                    return .failure(OperationFailure(message: L("文件已损坏或不是有效的 xz 格式")))
                }
            }

            let tool: (executable: String, arguments: [String]) = isBareGz
                ? ("/usr/bin/gunzip", ["-kc", archive])
                : ("/usr/bin/bunzip2", ["-kc", archive])

            do {
                // ProcessRunner 先读完 stderr 再等待退出：错误输出超过管道缓冲时不会死锁
                let result = try ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: tool.executable),
                    arguments: tool.arguments,
                    currentDirectoryURL: dir,
                    standardOutput: outHandle)
                try? outHandle.close()

                if result.status == 0 {
                    DispatchQueue.main.async {
                        NSWorkspace.shared.activateFileViewerSelecting([targetFileURL])
                    }
                    serviceLog("decompress single file succeeded: \(targetFileURL.path)")
                    return .success(targetFileURL)
                } else {
                    try? fileManager.removeItem(at: targetFileURL)
                    serviceLog("decompress single file failed (exit \(result.status)): \(result.stderr)")
                    return .failure(Self.toolFailure(result))
                }
            } catch {
                try? outHandle.close()
                try? fileManager.removeItem(at: targetFileURL)
                serviceLog("decompress single file error: \(error.localizedDescription)")
                return .failure(OperationFailure(message: error.localizedDescription))
            }
        }

        // 归档压缩包（zip、tar、tar.gz、tar.bz2、tar.xz 等）：解压到同名新文件夹
        var baseName = url.deletingPathExtension().lastPathComponent
        if isTarGz && baseName.lowercased().hasSuffix(".tar") {
            baseName = (baseName as NSString).deletingPathExtension
        } else if isTarBz2 && baseName.lowercased().hasSuffix(".tar") {
            baseName = (baseName as NSString).deletingPathExtension
        } else if isTarXz && baseName.lowercased().hasSuffix(".tar") {
            baseName = (baseName as NSString).deletingPathExtension
        }

        // 先解到压缩包旁边登记过的隐藏暂存目录（同卷才能原子改名），成功后再由 ExtractedOutput 落位：
        // 顶层只有一项时直接放出该项，避免 foo/foo 双层嵌套。失败时 defer 整体删除暂存目录，
        // 不留空目录或半截产物；App 中途崩溃则由下次启动的 sweep 清理
        let registry = ScratchDirectoryRegistry()
        let scratch: URL
        do {
            scratch = try registry.makeScratchDirectory(in: dir)
        } catch {
            serviceLog("创建解压暂存目录失败: \(error.localizedDescription)")
            return .failure(OperationFailure(message: L("无法在当前目录创建文件")))
        }
        defer { registry.remove(scratch) }

        let output = scratch.appendingPathComponent("out", isDirectory: true)
        do {
            try fileManager.createDirectory(at: output, withIntermediateDirectories: false)
        } catch {
            serviceLog("创建解压目录失败: \(error.localizedDescription)")
            return .failure(OperationFailure(message: L("无法在当前目录创建文件")))
        }

        let isZip = url.pathExtension.lowercased() == "zip"
        // 加密 zip 改用 bsdtar 带密码解；探测不出（zip64、结构异常）按普通包交给 ditto，行为与以前一致
        if isZip, let probe = ZipProbe.inspect(url), probe.hasEncryptedEntries {
            if case .failure(let failure) = extractEncryptedZip(url, into: output, legacyNames: probe.hasNonUTF8LegacyNames) {
                return .failure(failure)
            }
        } else {
            let tool: (executable: String, arguments: [String]) = isZip
                ? ("/usr/bin/ditto", ["-x", "-k", archive, output.path])
                : ("/usr/bin/tar", ["-xf", archive, "-C", output.path])

            let result: ProcessRunner.Result
            do {
                // 解压 Linux rootfs / Docker 层这类 tar 时每个设备节点都会报一行错，stderr 轻易超过
                // 64KB 管道缓冲；ProcessRunner 先读后等，避免死锁卡住整条 archiveQueue
                result = try ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: tool.executable),
                    arguments: tool.arguments,
                    currentDirectoryURL: output)
            } catch {
                serviceLog("decompress archive error: \(error.localizedDescription)")
                return .failure(OperationFailure(message: error.localizedDescription))
            }
            guard result.status == 0 else {
                serviceLog("decompress archive failed (exit \(result.status)): \(result.stderr)")
                return .failure(Self.toolFailure(result))
            }
        }

        do {
            let placed = try ExtractedOutput.place(extractedRoot: output, into: dir, folderName: baseName)
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting([placed])
            }
            serviceLog("decompress archive succeeded: \(placed.path)")
            return .success(placed)
        } catch {
            serviceLog("decompress archive finalize failed: \(error)")
            return .failure(OperationFailure(message: (error as? LocalizedError)?.errorDescription
                ?? String(describing: error)))
        }
    }

    /// 加密 zip：弹密码框 → bsdtar 带密码解到 output；密码错误（或为空）就带提示重问，直到解开或用户取消。
    /// 密码只在本函数的局部变量和 bsdtar 参数里，不写日志
    private func extractEncryptedZip(_ archive: URL, into output: URL, legacyNames: Bool) -> Result<Void, OperationFailure> {
        var retrying = false
        while true {
            guard let password = ArchivePasswordPrompt.ask(archiveName: archive.lastPathComponent, retrying: retrying) else {
                serviceLog("decompress encrypted zip cancelled: \(archive.path)")
                return .failure(.cancelled)
            }
            guard !password.isEmpty else {
                retrying = true
                continue
            }

            let outcome: EncryptedZipExtractor.Outcome
            do {
                outcome = try EncryptedZipExtractor.extract(archive, into: output, password: password, legacyNames: legacyNames)
            } catch {
                serviceLog("decompress encrypted zip error: \(error.localizedDescription)")
                return .failure(OperationFailure(message: error.localizedDescription))
            }
            switch outcome {
            case .extracted:
                return .success(())
            case .wrongPassword:
                serviceLog("decompress encrypted zip: wrong passphrase, asking again")
                retrying = true
            case .failed(let status, let stderr):
                serviceLog("decompress encrypted zip failed (exit \(status)): \(stderr)")
                return .failure(Self.toolFailure(status: status, stderr: stderr))
            }
        }
    }

    private static func describe(compressError error: Error) -> String {
        guard let failure = error as? ZipCompressor.Failure else { return error.localizedDescription }
        switch failure {
        case .nothingToCompress:
            return L("没有可压缩的项目")
        case .stagingFailed(let message), .finalizeFailed(let message):
            return message
        case .toolFailed(let status, let stderr):
            return OperationRecord.summary(of: stderr) ?? String(format: L("压缩工具退出码 %d"), status)
        }
    }
}
