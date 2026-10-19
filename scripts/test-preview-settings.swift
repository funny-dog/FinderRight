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
        print("✓ 预览开关状态检查通过（启用、禁用、默认、异常与未注册状态）")

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
