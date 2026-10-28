import Foundation
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

// MARK: - 图片转换与缩放

extension FinderRightService {

    func inspectImages(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, !items.isEmpty else {
            return IPCResponse(id: req.id, success: false, message: "inspectImages 参数缺失")
        }
        let urls = items.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        guard urls.allSatisfy({ isPathAllowed($0.path, role: .source) }) else {
            return IPCResponse(id: req.id, success: false, message: "inspectImages 路径不允许")
        }
        let state = ImageMenuState.evaluate(urls: urls)
        guard let data = try? JSONEncoder().encode(state), let message = String(data: data, encoding: .utf8) else {
            return IPCResponse(id: req.id, success: false, message: "inspectImages 编码失败")
        }
        return IPCResponse(id: req.id, success: true, message: message)
    }

    func convertImage(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, !items.isEmpty,
              let formatStr = req.payload["format"]?.stringValue,
              let targetFormat = ImageTargetFormat(rawValue: formatStr.lowercased()) else {
            return IPCResponse(id: req.id, success: false, message: "convertImage 参数缺失")
        }

        Self.backgroundJobs.run(on: Self.archiveQueue) {
            self.executeImageTransform(items: items, operation: .convert(format: targetFormat))
        }

        return IPCResponse(id: req.id, success: true, message: "ok")
    }

    func scaleImage(_ req: IPCRequest) -> IPCResponse {
        guard let items = req.payload["items"]?.stringArrayValue, !items.isEmpty,
              let maxPixel = req.payload["maxPixel"]?.intValue, [2560, 1920, 1280, 800].contains(maxPixel) else {
            return IPCResponse(id: req.id, success: false, message: "scaleImage 参数缺失")
        }

        Self.backgroundJobs.run(on: Self.archiveQueue) {
            self.executeImageTransform(items: items, operation: .scale(maxPixelSize: maxPixel))
        }

        return IPCResponse(id: req.id, success: true, message: "ok")
    }

    private func executeImageTransform(items: [String], operation: ImageTransformOperation) {
        var created: [URL] = []
        var failures: [(name: String, reason: String)] = []
        var skipped: [(name: String, reason: String)] = []

        let isScale: Bool
        switch operation {
        case .scale: isScale = true
        case .convert: isScale = false
        }

        for item in items {
            autoreleasepool {
                let source = URL(fileURLWithPath: (item as NSString).expandingTildeInPath).standardizedFileURL
                let itemName = source.lastPathComponent

                // 1. 检查源文件是否存在且为普通可读文件
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDir),
                      !isDir.boolValue,
                      FileManager.default.isReadableFile(atPath: source.path) else {
                    serviceLog("图片源文件不存在或不可读: \(source.path)")
                    failures.append((itemName, String(format: L("文件不存在：%@"), itemName)))
                    return
                }

                // 2. 源路径白名单校验
                guard isPathAllowed(source.path, role: .source) else {
                    serviceLog("图片源路径越界被拦截: \(source.path)")
                    failures.append((itemName, String(format: L("路径越界：安全策略拒绝访问 %@"), source.path)))
                    return
                }

                // 3. 目标目录白名单校验
                let directory = source.deletingLastPathComponent()
                guard isPathAllowed(directory.path, role: .destination) else {
                    serviceLog("图片输出目录越界被拦截: \(directory.path)")
                    failures.append((itemName, String(format: L("路径越界：安全策略拒绝访问 %@"), directory.path)))
                    return
                }

                // 4. 执行 ImageIO 转换或缩放
                do {
                    let outputURL = try ImageTransformer.process(
                        sourceURL: source,
                        operation: operation,
                        outputDirectory: directory
                    )
                    created.append(outputURL)
                } catch let error as ImageTransformError {
                    if case .alreadySmallerThanTarget = error {
                        skipped.append((itemName, error.localizedDescription))
                    } else {
                        serviceLog("图片处理失败 [\(itemName)]: \(error.localizedDescription)")
                        failures.append((itemName, error.localizedDescription))
                    }
                } catch {
                    let reason = error.localizedDescription
                    serviceLog("图片处理失败 [\(itemName)]: \(reason)")
                    failures.append((itemName, reason))
                }
            }
        }

        // 5. 登记撤销与高亮文件
        if !created.isEmpty {
            let undoKind: UndoRecord.Kind = isScale ? .scaleImage : .convertImage
            registerUndo(
                undoKind,
                name: created.count == 1 ? created[0].lastPathComponent : "",
                items: created.map { ($0, nil) },
                displayCount: created.count
            )
            DispatchQueue.main.async {
                NSWorkspace.shared.activateFileViewerSelecting(created)
            }
        }

        // 6. 汇总结果进操作历史与反馈
        let subject = Self.subject(forPaths: items)
        let location = items.first.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).deletingLastPathComponent() }
        let recordKind: OperationRecord.Kind = isScale ? .scaleImage : .convertImage

        let failureDetails = failures.map { "\($0.name)：\($0.reason)" }.joined(separator: "\n")
        let skipDetails = skipped.map { "\($0.name)：\($0.reason)" }.joined(separator: "\n")
        RecentOperations.shared.record(OperationRecord(
            kind: recordKind, subject: subject,
            failure: failures.isEmpty ? nil : failureDetails,
            results: created, location: location,
            note: skipped.isEmpty ? nil : skipDetails
        ))

        // 真正的失败由 AppDelegate 统一反馈；不放大属于正常跳过，不能进入失败提示。
        guard failures.isEmpty else { return }
        let message: String
        if created.isEmpty, skipped.count == 1 {
            message = String(format: L("无需缩放：%@"), skipped[0].reason)
        } else if created.isEmpty {
            message = String(format: L("已跳过 %d 项，无需缩放"), skipped.count)
        } else if !skipped.isEmpty {
            message = String(format: L("已处理 %d 项，%d 项无需缩放"), created.count, skipped.count)
        } else {
            message = String(format: L("已完成图片处理（%d 项）"), created.count)
        }
        ClipboardToast.show(message: message, style: .success)
    }
}
