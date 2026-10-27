import Foundation
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

// MARK: - 新建文件 / 符号链接

extension FinderRightService {

    func createFile(_ req: IPCRequest) -> IPCResponse {
        if let templateId = req.payload["template"]?.stringValue {
            return createFileFromTemplate(req, templateId: templateId)
        }
        guard let directory = req.payload["directory"]?.stringValue,
              let baseName = req.payload["baseName"]?.stringValue,
              let ext = req.payload["ext"]?.stringValue,
              let content = req.payload["content"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "createFile 参数缺失")
        }
        // 白名单只校验了 directory；baseName / ext 会直接拼进路径，含 `/` 或 `..` 时
        // 可穿越到白名单之外（如 ~/Desktop/../../../../tmp/x.txt），必须单独拦截
        guard SafeFileName.isValid(baseName: baseName, ext: ext) else {
            serviceLog("非法文件名被拦截: baseName=\(baseName) ext=\(ext)")
            return IPCResponse(id: req.id, success: false, message: L("非法的文件名"))
        }
        let dirURL = URL(fileURLWithPath: directory)
        let data = Data(content.utf8)
        // 查重与写入之间若恰好出现同名文件，withoutOverwriting 让写入失败而不是覆盖，换下一个序号重试
        for _ in 0..<5 {
            let fileURL = UniqueName.fileURL(baseName: baseName, ext: ext, in: dirURL)
            do {
                try data.write(to: fileURL, options: .withoutOverwriting)
                registerUndo(.createFile, name: fileURL.lastPathComponent, items: [(fileURL, nil)])
                RecentOperations.shared.record(OperationRecord(kind: .createFile, subject: fileURL.lastPathComponent,
                                                                results: [fileURL], location: dirURL))
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return IPCResponse(id: req.id, success: true, message: fileURL.path)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
            }
        }
        return IPCResponse(id: req.id, success: false, message: L("目标目录同名文件冲突，请重试"))
    }

    /// 从主 App 内置的空白模板新建 Office 文档。
    /// 模板 id 必须在 OfficeTemplate 白名单内，扩展名由模板决定，请求里的 ext 不参与拼路径
    private func createFileFromTemplate(_ req: IPCRequest, templateId: String) -> IPCResponse {
        guard let template = OfficeTemplate(rawValue: templateId) else {
            serviceLog("非法模板 id 被拦截: \(templateId)")
            return IPCResponse(id: req.id, success: false, message: L("非法的模板"))
        }
        guard let directory = req.payload["directory"]?.stringValue,
              let baseName = req.payload["baseName"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "createFile 参数缺失")
        }
        guard SafeFileName.isValid(baseName: baseName, ext: template.fileExtension) else {
            serviceLog("非法文件名被拦截: baseName=\(baseName)")
            return IPCResponse(id: req.id, success: false, message: L("非法的文件名"))
        }
        // build.sh 保留 Templates 子目录；xcodegen 生成的工程会把资源平铺到 Resources 根目录，两处都找
        guard let source = Bundle.main.url(forResource: OfficeTemplate.resourceName,
                                           withExtension: template.fileExtension,
                                           subdirectory: OfficeTemplate.resourceDirectory)
                ?? Bundle.main.url(forResource: OfficeTemplate.resourceName,
                                   withExtension: template.fileExtension) else {
            serviceLog("缺少内置模板: \(template.fileExtension)")
            return IPCResponse(id: req.id, success: false, message: L("缺少内置模板"))
        }
        // 读出内容再写新文件，而不是 copyItem：后者会沿用模板的修改日期与扩展属性
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
        let dirURL = URL(fileURLWithPath: directory)
        // 查重与写入之间若恰好出现同名文件，withoutOverwriting 让写入失败而不是覆盖，换下一个序号重试
        for _ in 0..<5 {
            let fileURL = UniqueName.fileURL(baseName: baseName, ext: template.fileExtension, in: dirURL)
            do {
                try data.write(to: fileURL, options: .withoutOverwriting)
                registerUndo(.createFile, name: fileURL.lastPathComponent, items: [(fileURL, nil)])
                RecentOperations.shared.record(OperationRecord(kind: .createFile, subject: fileURL.lastPathComponent,
                                                                results: [fileURL], location: dirURL))
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return IPCResponse(id: req.id, success: true, message: fileURL.path)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            } catch {
                return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
            }
        }
        return IPCResponse(id: req.id, success: false, message: L("目标目录同名文件冲突，请重试"))
    }

    // MARK: - 创建符号链接

    /// 在每个选中项旁边创建指向它的符号链接（内容为绝对路径），命名见 SymlinkNaming。
    /// items 已由 handle() 按源路径校验；链接写在源所在目录，这里再按写入目标校验该目录
    func createSymlink(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, !items.isEmpty else {
            return IPCResponse(id: req.id, success: false, message: "createSymlink 参数缺失")
        }
        let fileManager = FileManager.default
        var created: [URL] = []
        var firstError: String?
        var failed = 0
        for item in items {
            let source = URL(fileURLWithPath: (item as NSString).expandingTildeInPath).standardizedFileURL
            let directory = source.deletingLastPathComponent()
            guard isPathAllowed(directory.path, role: .destination) else {
                serviceLog("createSymlink 目录越界被拦截: \(directory.path)")
                failed += 1
                if firstError == nil { firstError = String(format: L("路径越界：安全策略拒绝访问 %@"), directory.path) }
                continue
            }
            let link = SymlinkNaming.linkURL(for: source, suffix: L("链接"))
            do {
                try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
                created.append(link)
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }

        if !created.isEmpty {
            registerUndo(.symlink, name: created.count == 1 ? created[0].lastPathComponent : "",
                         items: created.map { ($0, nil) })
            NSWorkspace.shared.activateFileViewerSelecting(created)
        }
        let subject = Self.subject(forPaths: items)
        let location = URL(fileURLWithPath: items[0]).deletingLastPathComponent()
        if let firstError {
            serviceLog("createSymlink completed with \(failed) failure(s): \(firstError)")
            RecentOperations.shared.record(OperationRecord(
                kind: .symlink, subject: subject,
                failure: String(format: L("%d 项未能创建符号链接：%@"), failed, firstError),
                results: created, location: location))
            return IPCResponse(id: req.id, success: false, message: firstError)
        }
        RecentOperations.shared.record(OperationRecord(kind: .symlink, subject: subject, results: created, location: location))
        return IPCResponse(id: req.id, success: true, message: "ok")
    }
}
