import Foundation

/// 更新日志条目类型
public enum ChangelogType: String, Equatable, Sendable {
    case feature = "feature"           // 新增
    case improvement = "improvement"   // 优化
    case fix = "fix"                   // 修复

    public var titleKey: String {
        switch self {
        case .feature: return "新增"
        case .improvement: return "优化"
        case .fix: return "修复"
        }
    }
}

/// 单条更新记录
public struct ChangelogEntry: Equatable, Sendable {
    public let type: ChangelogType
    public let textKey: String

    public init(type: ChangelogType, textKey: String) {
        self.type = type
        self.textKey = textKey
    }
}

/// 单个版本的更新说明
public struct ChangelogRelease: Equatable, Sendable {
    public let version: String
    public let date: String
    public let items: [ChangelogEntry]

    public init(version: String, date: String, items: [ChangelogEntry]) {
        self.version = version
        self.date = date
        self.items = items
    }
}

/// 内置的更新日志目录（支持离线浏览，按版本倒序排列）
public enum ChangelogCatalog {
    public static let releasesURL = URL(string: "https://github.com/funny-dog/FinderRight/releases")!

    public static let entries: [ChangelogRelease] = [
        ChangelogRelease(
            version: "1.13.0",
            date: "2026-11-12",
            items: [
                ChangelogEntry(type: .feature, textKey: "新增开发者工具：支持哈希校验、符号链接、相对路径、目录树、文件比较与本地 Git 状态等"),
                ChangelogEntry(type: .feature, textKey: "重构剪切队列管理与撤销功能，支持直接在右键菜单查看并管理剪切项"),
                ChangelogEntry(type: .improvement, textKey: "简洁模式支持配置深色模式与右键菜单图标，适配紧凑窗口"),
                ChangelogEntry(type: .fix, textKey: "优化磁盘占用分析中的符号链接过滤与超时预算机制"),
                ChangelogEntry(type: .fix, textKey: "修复关闭程序坞图标后从状态栏打开设置的焦点与时序问题")
            ]
        ),
        ChangelogRelease(
            version: "1.12.5",
            date: "2026-11-07",
            items: [
                ChangelogEntry(type: .feature, textKey: "支持在访达空白处与单选文件夹查看磁盘占用与直属子项排行"),
                ChangelogEntry(type: .improvement, textKey: "应用版本更新后自动重启一次访达，确保新功能扩展立即生效")
            ]
        ),
        ChangelogRelease(
            version: "1.12.4",
            date: "2026-11-04",
            items: [
                ChangelogEntry(type: .fix, textKey: "修复应用内自动更新安装完成后的重启退出死锁问题")
            ]
        ),
        ChangelogRelease(
            version: "1.12.3",
            date: "2026-11-04",
            items: [
                ChangelogEntry(type: .feature, textKey: "从剪贴板新建文件记住上次使用的模板格式"),
                ChangelogEntry(type: .improvement, textKey: "设置窗口新增简洁模式与平滑光轨切换动效"),
                ChangelogEntry(type: .fix, textKey: "在桌面新建文件不再激活打开多余的访达窗口")
            ]
        ),
        ChangelogRelease(
            version: "1.12.2",
            date: "2026-11-03",
            items: [
                ChangelogEntry(type: .feature, textKey: "支持直接从剪贴板中的纯文本或图片新建文件"),
                ChangelogEntry(type: .improvement, textKey: "增强自动更新下载校验和与代码签名验证"),
                ChangelogEntry(type: .fix, textKey: "避免只读安装盘侧边栏图标被意外替换")
            ]
        ),
        ChangelogRelease(
            version: "1.12.1",
            date: "2026-11-01",
            items: [
                ChangelogEntry(type: .feature, textKey: "支持配置全局快捷键快速打开指定路径"),
                ChangelogEntry(type: .improvement, textKey: "新增系统服务菜单显示开关，降低多扩展冲突"),
                ChangelogEntry(type: .improvement, textKey: "优化 ZIP 归档解析性能并及时取消过期预览")
            ]
        ),
        ChangelogRelease(
            version: "1.12.0",
            date: "2026-10-29",
            items: [
                ChangelogEntry(type: .feature, textKey: "支持计算并展示单选文件与目录的实际磁盘占用大小"),
                ChangelogEntry(type: .improvement, textKey: "显示大小并入功能列表，支持拖动排序与开关联动"),
                ChangelogEntry(type: .improvement, textKey: "进入受监控目录时在后台自动异步预热子项大小缓存")
            ]
        ),
        ChangelogRelease(
            version: "1.11.0",
            date: "2026-10-25",
            items: [
                ChangelogEntry(type: .feature, textKey: "新增 Markdown 只读快速预览扩展，支持独立启停"),
                ChangelogEntry(type: .improvement, textKey: "Quick Look 压缩包预览支持自包含解构与目录展开"),
                ChangelogEntry(type: .fix, textKey: "修复大型代码文件快速翻页时的内存占用")
            ]
        )
    ]
}
