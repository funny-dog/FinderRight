import Foundation

/// 新建 Office 文档的内置空白模板 —— 扩展与主 App 共用的白名单。
///
/// Office 文档是二进制（zip）格式，不能像文本模板那样把内容经 IPC 传过去：
/// 扩展只发送模板 id，主 App 校验 id 在白名单内后，从自身 Resources/Templates 里复制同名文件。
/// 这样 IPC 不必承载任意二进制内容，createFile 能写出的东西仍然只有「白名单模板」与「文本」两类。
public enum OfficeTemplate: String, CaseIterable {
    case docx, xlsx, pptx

    /// 文件扩展名，同时也是 IPC 中的模板 id
    public var fileExtension: String { rawValue }

    /// 菜单 / 服务确认框里显示的名称（本地化键），与枚举成员绑定，避免各处按顺序手写对应
    public var titleKey: String {
        switch self {
        case .docx: return "Word 文档 (.docx)"
        case .xlsx: return "Excel 表格 (.xlsx)"
        case .pptx: return "PowerPoint 演示文稿 (.pptx)"
        }
    }

    /// 主 App 包内的资源路径：Resources/Templates/Blank.<ext>
    public static let resourceName = "Blank"
    public static let resourceDirectory = "Templates"
}
