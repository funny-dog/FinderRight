import Foundation

/// 「关于」页反馈入口：拼出带预填字段的 GitHub issue 链接。
///
/// 仓库的 issue 模板是 Issue Form（.yml），GitHub 不认 `body=`，
/// 只能用表单字段的 `id` 作为查询参数预填，所以字段名必须与 `.github/ISSUE_TEMPLATE` 里的 id 一致。
public enum IssueLink {

    public enum Template: String {
        case bug = "bug_report.yml"
        case feature = "01-feature_request.yml"
    }

    /// 单个字段的上限：诊断信息本身很短，截断只为兜底，避免整条 URL 超过 GitHub 约 8KB 的限制
    public static let fieldLimit = 1500

    /// 查询参数只保留 RFC 3986 的非保留字符，`&`、`=`、`+`、换行等一律百分号编码
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 空值字段直接省略，保持表单原有的占位提示
    public static func url(
        repository: String = "funny-dog/FinderRight",
        template: Template,
        fields: [(id: String, value: String)] = []
    ) -> URL {
        var query = "template=" + encode(template.rawValue)
        for field in fields {
            let value = field.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let clipped = value.count > fieldLimit ? String(value.prefix(fieldLimit)) + "…" : value
            query += "&" + encode(field.id) + "=" + encode(clipped)
        }
        return URL(string: "https://github.com/\(repository)/issues/new?\(query)")!
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
