import Foundation

/// 日志脱敏：把文本里的 /Users/<名> 压成 ~，并隐藏外置卷的完整路径。
/// 与诊断报告（DiagnosticsReport）同一规则。
public enum LogRedaction {
    private static let userPattern = try? NSRegularExpression(pattern: "/Users/[^/\\s]+", options: [])
    private static let volumePattern = try? NSRegularExpression(pattern: #"(?m)/Volumes/[^\n\r]*"#, options: [])

    public static func redactPaths(_ text: String) -> String {
        guard let userPattern, let volumePattern else { return text }
        let range = NSRange(text.startIndex..., in: text)
        let usersRedacted = userPattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "~")
        let volumeRange = NSRange(usersRedacted.startIndex..., in: usersRedacted)
        return volumePattern.stringByReplacingMatches(
            in: usersRedacted, options: [], range: volumeRange, withTemplate: "<外部卷路径>")
    }
}