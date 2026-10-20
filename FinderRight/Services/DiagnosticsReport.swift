import AppKit
import Darwin

/// 「关于」页的「复制诊断信息」：把反馈问题时需要的环境与开关状态拼成一段纯文本。
///
/// 只写状态，不写文件路径：失败原因里的 `/Users/<名字>` 会被压成 `~`，
/// 剪切队列也只给出数量。用户贴到 issue 前仍然可以自己再删。
enum DiagnosticsReport {

    static func make() -> String {
        var lines: [String] = []

        let version = UpdateChecker.shared.currentAppVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("FinderRight \(version) (build \(build))")
        lines.append(String(format: L("系统：%@"), ProcessInfo.processInfo.operatingSystemVersionString))

        let chip = sysctlString("machdep.cpu.brand_string") ?? "?"
        let model = sysctlString("hw.model") ?? "?"
        lines.append(String(format: L("芯片：%@（%@）"), chip, model))

        lines.append(String(format: L("辅助功能：%@"), granted(AccessibilityChecker.check())))
        lines.append(String(format: L("完全磁盘访问：%@"), granted(FullDiskAccessChecker.check())))
        lines.append(String(format: L("Finder 扩展：%@"), enabled(FinderExtensionChecker.check())))

        let preview: String
        do {
            preview = try PreviewExtensionManager.isEnabled() ? L("已启用") : L("未启用")
        } catch {
            preview = L("未知")
        }
        lines.append(String(format: L("快速查看扩展：%@"), preview))

        lines.append(String(format: L("剪切队列：%d 项"), CutQueueStore().read().count))

        let recent = RecentOperations.shared
        if recent.isEnabled {
            lines.append(String(format: L("最近操作记录：%@"), L("已开启")))
            for record in recent.records where record.failure != nil {
                guard let failure = record.failure else { continue }
                lines.append(String(format: L("最近失败：%@"), "\(record.kind.rawValue) · \(shorten(failure))"))
            }
        } else {
            lines.append(String(format: L("最近操作记录：%@"), L("已关闭")))
        }

        return lines.joined(separator: "\n")
    }

    private static func L(_ key: String) -> String {
        NSLocalizedString(key, comment: "diagnostics")
    }

    private static func granted(_ value: Bool) -> String {
        value ? L("已授权") : L("未授权")
    }

    private static func enabled(_ value: Bool) -> String {
        value ? L("已启用") : L("未启用")
    }

    /// 失败原因可能带子进程 stderr 的多行输出，截断后再放进剪贴板
    private static func shorten(_ text: String, limit: Int = 240) -> String {
        let pattern = try? NSRegularExpression(pattern: "/Users/[^/\\s]+", options: [])
        let range = NSRange(text.startIndex..., in: text)
        let stripped = pattern?.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "~")
            ?? text
        let flattened = stripped
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " / ")
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
