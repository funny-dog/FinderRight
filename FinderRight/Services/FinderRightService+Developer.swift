import Foundation
import AppKit
import FinderRightKit

extension FinderRightService {
    private static let developerQueue = DispatchQueue(label: "com.finderright.app.developer", qos: .userInitiated)

    func runCustomCommand(_ req: IPCRequest) -> IPCResponse {
        SharedConfig.shared.reload()
        // 扩展只传保存的命令 ID，不接受请求携带的脚本或可执行路径。
        guard let id = req.payload["commandId"]?.stringValue,
              let command = SharedConfig.shared.developerCommand(id: id) else {
            return IPCResponse(id: req.id, success: false, message: NSLocalizedString("命令不存在或已关闭", comment: ""))
        }
        do {
            let selection = (req.payload["items"]?.stringArrayValue ?? []).map { URL(fileURLWithPath: $0) }
            let directory = req.payload["directory"]?.stringValue.map { URL(fileURLWithPath: $0) }
            let context = try DeveloperCommand.context(selection: selection, directory: directory)
            guard isPathAllowed(context.directory.path, role: .source),
                  context.items.allSatisfy({ isPathAllowed($0.path, role: .source) }) else {
                return IPCResponse(id: req.id, success: false, message: NSLocalizedString("无法访问所选路径", comment: ""))
            }
            DispatchQueue.main.async {
                CustomCommandController.shared.run(command, items: context.items, directory: context.directory)
            }
            return IPCResponse(id: req.id, success: true, message: nil)
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }

    func copyDeveloperText(_ req: IPCRequest) -> IPCResponse {
        let isTree = req.action == "copyDirectoryTree"
        let feature = isTree ? MenuFeatureCatalog.copyDirectoryTree : MenuFeatureCatalog.copyProjectRelativePath
        SharedConfig.shared.reload()
        guard SharedConfig.shared.isActionEnabled(feature) else {
            return IPCResponse(id: req.id, success: false, message: NSLocalizedString("此功能已关闭，请在设置中启用", comment: ""))
        }
        let paths = isTree ? req.payload["directory"]?.stringValue.map { [$0] } : req.payload["items"]?.stringArrayValue
        guard let paths, !paths.isEmpty,
              paths.allSatisfy({ isPathAllowed($0, role: .source) }) else {
            return IPCResponse(id: req.id, success: false, message: NSLocalizedString("无法访问所选路径", comment: ""))
        }
        guard Self.runGuarded(on: Self.developerQueue, work: {
            do {
                let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                let text = try isTree ? DirectoryTree.render(at: urls[0]) : ProjectRelativePath.paths(for: urls).joined(separator: "\n")
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(text, forType: .string) {
                        ClipboardToast.showCopied()
                    } else {
                        ClipboardToast.show(message: NSLocalizedString("无法写入剪贴板", comment: ""), style: .failure)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    ClipboardToast.show(message: error.localizedDescription, style: .failure)
                }
            }
        }) else {
            return Self.exitInProgressResponse(req)
        }
        return IPCResponse(id: req.id, success: true, message: nil)
    }
}
