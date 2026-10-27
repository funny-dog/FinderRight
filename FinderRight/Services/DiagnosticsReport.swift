import AppKit
import Darwin
import FinderRightKit

/// 「反馈与建议」弹窗里的诊断信息：把反馈问题时需要的环境与开关状态拼成纯文本，或按 issue 模板字段预填。
///
/// 只写状态，不写文件路径：失败原因里的 `/Users/<名字>` 会被压成 `~`，
/// 剪切队列也只给出数量。用户贴到 issue 前仍然可以自己再删。
enum DiagnosticsReport {

    /// 按 issue 模板字段分好组的诊断信息，复制文本与反馈链接共用同一份内容
    struct Sections {
        /// 对应模板字段 `version`
        var version: String
        /// 对应模板字段 `macos`
        var system: [String]
        /// 对应模板字段 `permissions`
        var state: [String]
        /// 对应模板字段 `logs`：可能带文件名，单独放一栏方便用户提交前删改
        var failures: [String]
    }

    /// 复制与弹窗预览用的纯文本
    static func text(_ s: Sections) -> String {
        ([s.version] + s.system + s.state + s.failures).joined(separator: "\n")
    }

    /// 「问题反馈」：打开 Bug 模板并预填诊断信息
    static func bugReportURL(_ s: Sections) -> URL {
        IssueLink.url(template: .bug, fields: [
            (id: "version", value: s.version),
            (id: "macos", value: s.system.joined(separator: "\n")),
            (id: "permissions", value: s.state.joined(separator: "\n")),
            (id: "logs", value: s.failures.joined(separator: "\n")),
        ])
    }

    /// 「功能建议」：只需要打开模板，不带环境信息
    static func featureRequestURL() -> URL {
        IssueLink.url(template: .feature)
    }

    static func sections() -> Sections {
        let version = UpdateChecker.shared.currentAppVersion
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var system: [String] = []
        system.append(String(format: L("系统：%@"), ProcessInfo.processInfo.operatingSystemVersionString))
        let chip = sysctlString("machdep.cpu.brand_string") ?? "?"
        let model = sysctlString("hw.model") ?? "?"
        system.append(String(format: L("芯片：%@（%@）"), chip, model))

        var lines: [String] = []
        lines.append(String(format: L("辅助功能：%@"), granted(AccessibilityChecker.check())))
        lines.append(String(format: L("完全磁盘访问：%@"), granted(FullDiskAccessChecker.check())))
        lines.append(String(format: L("Finder 扩展：%@"), enabled(FinderExtensionChecker.check())))

        let preview: String
        do {
            preview = try PreviewExtensionManager.isEnabled() ? L("已启用") : L("未启用")
        } catch {
            preview = L("未知")
        }
        lines.append(String(format: L("快速查看 · 预览增强：%@"), preview))
        var markdown = (try? PreviewExtensionManager.isEnabled(PreviewExtensionManager.markdownIdentifier)).map { $0 ? L("已启用") : L("未启用") } ?? L("未知")
        // 设置页只提示有冲突，具体应用名留给诊断排查
        let conflicts = PreviewExtensionManager.markdownConflicts()
        if !conflicts.isEmpty { markdown += String(format: L("（另有 %@ 的 Markdown 预览）"), conflicts.joined(separator: ", ")) }
        lines.append(String(format: L("快速查看 · Markdown 渲染：%@"), markdown))

        lines.append(String(format: L("剪切队列：%d 项"), CutQueueStore().read().count))

        var failures: [String] = []
        let recent = RecentOperations.shared
        if recent.capacity > 0 {
            lines.append(String(format: L("操作历史：保留最近 %d 条"), recent.capacity))
            for record in recent.records.filter({ $0.failure != nil }).prefix(3) {
                guard let failure = record.failure else { continue }
                failures.append(String(format: L("最近失败：%@"), "\(record.kind.rawValue) · \(shorten(failure))"))
            }
        } else {
            lines.append(String(format: L("操作历史：%@"), L("已关闭")))
        }

        return Sections(version: "FinderRight \(version) (build \(build))", system: system, state: lines, failures: failures)
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
