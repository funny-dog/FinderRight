import Foundation

@main
struct PreviewSettingsChecks {
    static func main() throws {
        let id = PreviewExtensionManager.identifier
        for (marker, expected) in [("+", true), ("-", false), (" ", true)] {
            let output = "\(marker)    \(id)(1.7.1)\n (1 plug-in)\n"
            let enabled = try PreviewExtensionManager.enabledState(in: output)
            precondition(enabled == expected)
        }
        for marker in ["!", "=", "?"] {
            do {
                _ = try PreviewExtensionManager.enabledState(in: "\(marker)    \(id)(1.7.1)")
                throw CocoaError(.validationMissingMandatoryProperty)
            } catch PreviewExtensionManager.Failure.unknownState {}
        }
        for output in [" (no matches)", "+    com.example.other(1.0)", "garbage", ""] {
            do {
                _ = try PreviewExtensionManager.enabledState(in: output)
                throw CocoaError(.validationMissingMandatoryProperty)
            } catch PreviewExtensionManager.Failure.unavailable {}
        }
        let markdownID = PreviewExtensionManager.markdownIdentifier
        let both = "+    \(id)(1.10.3)\n-    \(markdownID)(1.10.3)\n"
        let previewOn = try PreviewExtensionManager.enabledState(in: both, identifier: id)
        let markdownOn = try PreviewExtensionManager.enabledState(in: both, identifier: markdownID)
        precondition(previewOn && !markdownOn, "两个扩展的状态必须按标识分开读取")

        let listing = [
            "     app.cyan.markedit.quicklook-extension(1.37.0)\tUUID\t2026-10-22 05:02:18 +0000\t/Applications/MarkEdit.app/Contents/PlugIns/QuickLookExtension.appex",
            "-    com.example.disabled(1.0)\tUUID\tdate\t/Applications/Disabled.app/Contents/PlugIns/MD.appex",
            "+    com.example.other(2.0)\tUUID\tdate\t/Applications/Other Viewer.app/Contents/PlugIns/Viewer.appex",
            "+    \(markdownID)(1.10.3)\tUUID\tdate\t/Applications/FinderRight.app/Contents/PlugIns/FinderRightMarkdown.appex",
            "+    com.example.images(1.0)\tUUID\tdate\t/Applications/Images.app/Contents/PlugIns/Images.appex",
            "garbage"
        ].joined(separator: "\n")
        let conflicts = PreviewExtensionManager.markdownConflicts(verboseOutput: listing) { path in
            path.contains("Images") ? ["public.png"] : ["net.daringfireball.markdown"]
        }
        precondition(conflicts == ["MarkEdit", "Other Viewer"], "冲突检测应只列出其他已启用的 Markdown 预览扩展，实际：\(conflicts)")
        print("✓ 预览开关状态检查通过（启用、禁用、默认、异常、未注册状态，双扩展分开读取与 Markdown 冲突检测）")

        // 仅显式 --live 时切换本机扩展，CI 不改系统设置。
        if CommandLine.arguments.contains("--live") {
            let original = try PreviewExtensionManager.isEnabled()
            do {
                try PreviewExtensionManager.setEnabled(!original)
                try PreviewExtensionManager.setEnabled(original)
            } catch {
                try PreviewExtensionManager.setEnabled(original)
                throw error
            }
            print("✓ 本机预览扩展开关及状态回读通过，已恢复原状态")
        }
    }
}
