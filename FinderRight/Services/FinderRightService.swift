import Foundation
import AppKit
import CoreGraphics
import FinderRightKit

/// 主 App 端的 IPC 请求处理器。
///
/// 这个对象由 IPCWatcher 创建，收到 IPCRequest 后路由到对应方法。
/// 所有方法都在主 App 进程（非沙箱）里执行，借用主 App 的 TCC 权限（包括 Full Disk Access）。
final class FinderRightService {

    /// 路由 IPCRequest 到具体的 handler
    func handle(_ req: IPCRequest) -> IPCResponse {
        switch req.action {
        case "ping":
            return ping(req)
        case "createFile":
            return createFile(req)
        case "duplicate":
            return duplicate(req)
        case "makeSymlink":
            return makeSymlink(req)
        case "moveToTrash":
            return moveToTrash(req)
        case "revealInFinder":
            return revealInFinder(req)
        case "showInfo":
            return showInfo(req)
        case "compressZip":
            return compressZip(req)
        case "compressTarGz":
            return compressTarGz(req)
        case "decompress":
            return decompress(req)
        case "openTerminal":
            return openTerminal(req)
        case "openWithApp":
            return openWithApp(req)
        case "toggleHiddenFiles":
            return toggleHiddenFiles(req)
        case "cutFiles":
            return cutFiles(req)
        case "pasteFiles":
            return pasteFiles(req)
        default:
            return IPCResponse(id: req.id, success: false, message: "未知 action: \(req.action)")
        }
    }

    // MARK: - 各 handler

    private func ping(_ req: IPCRequest) -> IPCResponse {
        let testPath = req.payload["testPath"]?.stringValue ?? "~/Pictures"
        let expanded = (testPath as NSString).expandingTildeInPath
        let canRead = (try? FileManager.default.contentsOfDirectory(atPath: expanded)) != nil
        return IPCResponse(id: req.id, success: true, message: canRead ? "fda=yes" : "fda=no")
    }

    private func createFile(_ req: IPCRequest) -> IPCResponse {
        guard let directory = req.payload["directory"]?.stringValue,
              let baseName = req.payload["baseName"]?.stringValue,
              let ext = req.payload["ext"]?.stringValue,
              let content = req.payload["content"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "createFile 参数缺失")
        }
        let dirURL = URL(fileURLWithPath: directory)
        let fileURL = uniqueFileURL(baseName: baseName, ext: ext, in: dirURL)
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            return IPCResponse(id: req.id, success: true, message: fileURL.path)
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    private func duplicate(_ req: IPCRequest) -> IPCResponse {
        guard let path = req.payload["path"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "duplicate 参数缺失")
        }
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let dest = uniqueFileURL(baseName: "\(base) copy", ext: ext, in: dir)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return IPCResponse(id: req.id, success: true, message: dest.path)
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    private func makeSymlink(_ req: IPCRequest) -> IPCResponse {
        guard let path = req.payload["path"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "makeSymlink 参数缺失")
        }
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let linkName = ext.isEmpty ? "\(base) symlink" : "\(base) symlink.\(ext)"
        let linkURL = dir.appendingPathComponent(linkName)
        do {
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: url)
            return IPCResponse(id: req.id, success: true, message: linkURL.path)
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    private func moveToTrash(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue else {
            return IPCResponse(id: req.id, success: false, message: "moveToTrash 参数缺失")
        }
        var firstError: String?
        for p in paths {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: p), resultingItemURL: nil)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return IPCResponse(id: req.id, success: firstError == nil, message: firstError)
    }

    private func revealInFinder(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue else {
            return IPCResponse(id: req.id, success: false, message: "revealInFinder 参数缺失")
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
        return IPCResponse(id: req.id, success: true, message: nil)
    }

    private func showInfo(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue else {
            return IPCResponse(id: req.id, success: false, message: "showInfo 参数缺失")
        }
        for p in paths {
            let script = """
                tell application "Finder"
                    activate
                    open information window of (POSIX file "\(p)" as alias)
                end tell
                """
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let e = err {
                let msg = e["NSAppleScriptErrorMessage"] as? String ?? "AppleScript failed"
                return IPCResponse(id: req.id, success: false, message: msg)
            }
        }
        return IPCResponse(id: req.id, success: true, message: nil)
    }

    private func compressZip(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, let first = items.first else {
            return IPCResponse(id: req.id, success: false, message: "compressZip 参数缺失")
        }
        let dir = URL(fileURLWithPath: first).deletingLastPathComponent()
        let name = items.count == 1
            ? URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent
            : "Archive"
        let dest = uniqueFileURL(baseName: name, ext: "zip", in: dir)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = dir
        proc.arguments = ["-r", dest.path] + items.map { URL(fileURLWithPath: $0).lastPathComponent }
        do {
            try proc.run()
            proc.waitUntilExit()
            if FileManager.default.fileExists(atPath: dest.path) {
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                return IPCResponse(id: req.id, success: true, message: dest.path)
            }
            return IPCResponse(id: req.id, success: false, message: "zip exit=\(proc.terminationStatus)")
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    private func compressTarGz(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, let first = items.first else {
            return IPCResponse(id: req.id, success: false, message: "compressTarGz 参数缺失")
        }
        let dir = URL(fileURLWithPath: first).deletingLastPathComponent()
        let name = items.count == 1
            ? URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent
            : "Archive"
        let dest = uniqueFileURL(baseName: name, ext: "tar.gz", in: dir)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.currentDirectoryURL = dir
        proc.arguments = ["-czf", dest.path] + items.map { URL(fileURLWithPath: $0).lastPathComponent }
        do {
            try proc.run()
            proc.waitUntilExit()
            if FileManager.default.fileExists(atPath: dest.path) {
                NSWorkspace.shared.activateFileViewerSelecting([dest])
                return IPCResponse(id: req.id, success: true, message: dest.path)
            }
            return IPCResponse(id: req.id, success: false, message: "tar exit=\(proc.terminationStatus)")
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    private func decompress(_ req: IPCRequest) -> IPCResponse {
        guard let archive = req.payload["archive"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "decompress 参数缺失")
        }
        let url = URL(fileURLWithPath: archive)
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension.lowercased()
        let proc = Process()
        proc.currentDirectoryURL = dir
        switch ext {
        case "zip":
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-o", archive, "-d", dir.path]
        default:
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            proc.arguments = ["-xf", archive, "-C", dir.path]
        }
        do {
            try proc.run()
            proc.waitUntilExit()
            return IPCResponse(id: req.id,
                               success: proc.terminationStatus == 0,
                               message: "exit=\(proc.terminationStatus)")
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    private func openTerminal(_ req: IPCRequest) -> IPCResponse {
        guard let directory = req.payload["directory"]?.stringValue,
              let bundleId = req.payload["bundleId"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "openTerminal 参数缺失")
        }
        let url = URL(fileURLWithPath: directory)
        let success = NSWorkspace.shared.open(
            [url],
            withAppBundleIdentifier: bundleId,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifiers: nil
        )
        return IPCResponse(id: req.id, success: success,
                           message: success ? nil : "NSWorkspace.open 返回 false")
    }

    private func openWithApp(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue,
              let bundleId = req.payload["bundleId"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "openWithApp 参数缺失")
        }
        let cliPaths = req.payload["cliFallbackPaths"]?.stringArrayValue ?? []
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let ok = NSWorkspace.shared.open(
            urls,
            withAppBundleIdentifier: bundleId,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifiers: nil
        )
        if ok { return IPCResponse(id: req.id, success: true, message: nil) }

        if let cmd = cliPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cmd)
            proc.arguments = paths
            do {
                try proc.run()
                return IPCResponse(id: req.id, success: true, message: nil)
            } catch {
                return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
            }
        }
        return IPCResponse(id: req.id, success: false, message: "无法打开 \(bundleId)，且无 CLI fallback")
    }

    private func toggleHiddenFiles(_ req: IPCRequest) -> IPCResponse {
        // 用 CGEventPostToPid 直接向 Finder 进程发送 Cmd+Shift+.
        // 只需辅助功能权限，无需 Automation（Apple Events）权限，也不依赖前台焦点。
        let opts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            serviceLog("no Accessibility permission, fallback to defaults")
            return toggleHiddenFilesViaDefaults(req)
        }

        guard let finder = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.finder").first else {
            serviceLog("Finder not running, fallback to defaults")
            return toggleHiddenFilesViaDefaults(req)
        }

        let pid = finder.processIdentifier
        let src = CGEventSource(stateID: .hidSystemState)
        // kVK_ANSI_Period = 0x2F
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x2F, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x2F, keyDown: false)
        down?.flags = [.maskCommand, .maskShift]
        up?.flags   = [.maskCommand, .maskShift]
        down?.postToPid(pid)
        up?.postToPid(pid)

        serviceLog("sent Cmd+Shift+. to Finder pid=\(pid)")
        return IPCResponse(id: req.id, success: true, message: "toggled via CGEvent pid=\(pid)")
    }

    private func serviceLog(_ message: String) {
        NSLog("[FinderRightService] \(message)")
    }

    private func toggleHiddenFilesViaDefaults(_ req: IPCRequest) -> IPCResponse {
        do {
            let readProc = Process()
            readProc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            readProc.arguments = ["read", "com.apple.finder", "AppleShowAllFiles"]
            let pipe = Pipe()
            readProc.standardOutput = pipe
            readProc.standardError = Pipe()
            try readProc.run()
            readProc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let newValue = (output.uppercased() == "YES" || output == "1") ? "NO" : "YES"

            let writeProc = Process()
            writeProc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            writeProc.arguments = ["write", "com.apple.finder", "AppleShowAllFiles", newValue]
            try writeProc.run()
            writeProc.waitUntilExit()

            let killProc = Process()
            killProc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killProc.arguments = ["Finder"]
            try killProc.run()
            killProc.waitUntilExit()

            return IPCResponse(id: req.id, success: true, message: "set to \(newValue), restarted Finder")
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    // MARK: - 剪切 / 粘贴（先移到暂存区，再粘贴到目标）

    /// 剪切队列文件路径（存储暂存区内的文件路径）
    private var cutQueueFileURL: URL {
        IPCBridge.rootDirectory.appendingPathComponent("cut-queue.json")
    }

    /// 暂存目录：文件剪切后先放到这里，粘贴时再移走
    private var stagingDirectory: URL {
        IPCBridge.rootDirectory.appendingPathComponent("staging", isDirectory: true)
    }

    /// 剪切：立即将源文件移到暂存区，源文件从原位置消失。
    /// 暂存路径写入 cut-queue.json，供后续粘贴使用。
    private func cutFiles(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue, !paths.isEmpty else {
            return IPCResponse(id: req.id, success: false, message: "cutFiles 参数缺失：paths")
        }

        let fileManager = FileManager.default
        let staging = stagingDirectory

        // 每次剪切都清空旧的暂存区，避免残留文件干扰
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            return IPCResponse(id: req.id, success: false, message: "无法创建暂存目录: \(error.localizedDescription)")
        }

        var stagedPaths: [String] = []
        var firstError: String?

        for sourcePath in paths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            var destURL = staging.appendingPathComponent(sourceURL.lastPathComponent)

            // 避免暂存区内命名冲突
            if fileManager.fileExists(atPath: destURL.path) {
                let base = destURL.deletingPathExtension().lastPathComponent
                let ext  = destURL.pathExtension
                var counter = 1
                repeat {
                    let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                    destURL = staging.appendingPathComponent(numbered)
                    counter += 1
                } while fileManager.fileExists(atPath: destURL.path)
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destURL)
                stagedPaths.append(destURL.path)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        // 将暂存路径写入队列文件，供粘贴时读取
        if let data = try? JSONSerialization.data(withJSONObject: stagedPaths) {
            try? data.write(to: cutQueueFileURL, options: .atomic)
        }

        if let err = firstError {
            return IPCResponse(id: req.id, success: false, message: err)
        }
        return IPCResponse(id: req.id, success: true, message: "已暂存 \(stagedPaths.count) 个文件")
    }

    private func pasteFiles(_ req: IPCRequest) -> IPCResponse {
        guard let destPath = req.payload["destination"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "pasteFiles 参数缺失：destination")
        }
        let destDir = URL(fileURLWithPath: destPath)

        // 从 IPC 共享文件读取剪切队列
        guard let data = try? Data(contentsOf: cutQueueFileURL),
              let sourcePaths = try? JSONSerialization.jsonObject(with: data) as? [String],
              !sourcePaths.isEmpty else {
            return IPCResponse(id: req.id, success: false, message: "剪切队列为空，请先剪切文件")
        }

        let fileManager = FileManager.default
        var firstError: String?
        var pastedPaths: [URL] = []
        var failedPaths: [String] = []

        for sourcePath in sourcePaths {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            var destURL = destDir.appendingPathComponent(sourceURL.lastPathComponent)

            // 目标已存在则自动重命名避免冲突
            if fileManager.fileExists(atPath: destURL.path) {
                let base = destURL.deletingPathExtension().lastPathComponent
                let ext  = destURL.pathExtension
                var counter = 1
                repeat {
                    let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                    destURL = destDir.appendingPathComponent(numbered)
                    counter += 1
                } while fileManager.fileExists(atPath: destURL.path)
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destURL)
                pastedPaths.append(destURL)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
                failedPaths.append(sourcePath)
            }
        }

        // 更新剪切队列：只保留未能移动成功的路径，防止队列指向已不存在的源文件
        if failedPaths.isEmpty {
            try? fileManager.removeItem(at: cutQueueFileURL)
        } else if let updatedData = try? JSONSerialization.data(withJSONObject: failedPaths) {
            try? updatedData.write(to: cutQueueFileURL, options: .atomic)
        }

        if let err = firstError {
            return IPCResponse(id: req.id, success: false, message: err)
        }

        if !pastedPaths.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(pastedPaths)
        }

        return IPCResponse(id: req.id, success: true, message: "已移动 \(pastedPaths.count) 个文件")
    }

    // MARK: - Helpers

    private func uniqueFileURL(baseName: String, ext: String, in directory: URL) -> URL {
        let name = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        var url = directory.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: url.path) {
            let numbered = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            url = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return url
    }
}
