import Foundation
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

// MARK: - 复制文件内容 / 哈希

extension FinderRightService {

    // MARK: - 复制哈希

    /// 哈希专用串行队列：大文件计算可能要几秒，不占用移动 / 压缩队列
    private static let hashQueue = DispatchQueue(label: "com.finderright.app.hash", qos: .userInitiated)

    /// 选中文件合计超过这个大小时先提示「正在计算」，小文件直接出结果，不闪两次提示
    private static let hashProgressHintBytes: UInt64 = 64 << 20

    /// 计算选中文件的摘要并写入剪贴板。只读操作，与「复制文件内容」一样只校验路径存在；
    /// 文件夹与包跳过，全部跳过时提示没有可计算的文件
    func copyFileHash(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, !items.isEmpty,
              let raw = req.payload["algorithm"]?.stringValue,
              let algorithm = FileHasher.Algorithm(rawValue: raw) else {
            return IPCResponse(id: req.id, success: false, message: "copyFileHash 参数缺失")
        }
        let urls = items.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        // handle() 对只读 action 只校验存在性；与「复制文件内容」一样在这里补源路径白名单，
        // 不让摘要读到完全磁盘访问专属的数据。越界项按未计算跳过
        let allowed = urls.filter { isPathAllowed($0.path, role: .source) }
        if allowed.count < urls.count {
            serviceLog("copyFileHash 路径越界被跳过: \(urls.count - allowed.count) 项")
        }
        let files = allowed.filter(FileHasher.isRegularFile)
        guard !files.isEmpty else {
            ClipboardToast.showCopied(message: L("所选项目中没有可计算哈希的文件"), isWarning: true)
            return IPCResponse(id: req.id, success: false, message: L("所选项目中没有可计算哈希的文件"))
        }
        let totalBytes = files.reduce(UInt64(0)) { sum, url in
            sum + UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        if totalBytes > Self.hashProgressHintBytes {
            ClipboardToast.showCopied(message: String(format: L("正在计算 %@…"), algorithm.title))
        }
        let skipped = urls.count - files.count

        Self.backgroundJobs.run(on: Self.hashQueue) { [weak self] in
            var results: [(name: String, digest: String)] = []
            var failed = 0
            for url in files {
                if let digest = FileHasher.hexDigest(of: url, algorithm: algorithm) {
                    results.append((url.lastPathComponent, digest))
                } else {
                    failed += 1
                }
            }
            self?.serviceLog("copyFileHash(\(algorithm.rawValue)): ok=\(results.count) failed=\(failed) skipped=\(skipped)")
            guard !results.isEmpty else {
                ClipboardToast.showCopied(message: L("无法读取文件内容"), isWarning: true)
                return
            }
            let text = FileHasher.clipboardText(results)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    ClipboardToast.showCopied(message: L("无法写入剪贴板"), isWarning: true)
                    return
                }
                if failed + skipped > 0 {
                    ClipboardToast.showCopied(message: String(format: L("已复制 %d 个文件的 %@，%d 项未计算"),
                                                              results.count, algorithm.title, failed + skipped),
                                              isWarning: true)
                } else {
                    ClipboardToast.showCopied(message: String(format: L("已复制 %@"), algorithm.title))
                }
            }
        }
        return IPCResponse(id: req.id, success: true, message: "已受理，正在后台计算")
    }

    func copyFileContent(_ req: IPCRequest) -> IPCResponse {
        guard let path = req.payload["path"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "参数缺失: path")
        }
        let expanded = (path as NSString).expandingTildeInPath
        guard isPathAllowed(expanded, role: .source) else {
            serviceLog("copyFileContent 路径越界被拦截: \(expanded)")
            return IPCResponse(id: req.id, success: false, message: String(format: L("路径越界：安全策略拒绝访问 %@"), expanded))
        }
        let url = URL(fileURLWithPath: expanded)
        let maxBytes = SharedConfig.shared.copyFileContentMaxBytes
        let result = FileContentReader.readText(from: url, maxBytes: maxBytes)

        switch result {
        case .success(let text):
            let write = {
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    ClipboardToast.showCopied(message: L("无法写入剪贴板"), isWarning: true)
                    return IPCResponse(id: req.id, success: false, message: L("无法写入剪贴板"))
                }
                ClipboardToast.showCopied(message: L("已复制文件内容到剪贴板"))
                return IPCResponse(id: req.id, success: true, message: "ok")
            }
            return Thread.isMainThread ? write() : DispatchQueue.main.sync(execute: write)
        case .notRegularFile:
            return IPCResponse(id: req.id, success: false, message: L("无法读取：不是普通文件"))
        case .fileTooLarge:
            DispatchQueue.main.async {
                ClipboardToast.showCopied(message: L("文件大小超过限制"), isWarning: true)
            }
            return IPCResponse(id: req.id, success: false, message: L("文件大小超过限制"))
        case .readFailed:
            DispatchQueue.main.async {
                ClipboardToast.showCopied(message: L("无法读取文件内容"), isWarning: true)
            }
            return IPCResponse(id: req.id, success: false, message: L("无法读取文件内容"))
        case .binaryFile:
            DispatchQueue.main.async {
                ClipboardToast.showCopied(message: L("无法复制：非文本文件"), isWarning: true)
            }
            return IPCResponse(id: req.id, success: false, message: L("无法复制：非文本文件"))
        }
    }
}
