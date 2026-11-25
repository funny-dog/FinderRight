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
            version: "1.14.0",
            date: "2026-11-26",
            items: [
                ChangelogEntry(type: .feature, textKey: "新增「暖陶」主题色并全面优化 7 套主题配色与对比度，升级输入框、图标块与按钮交互反馈"),
                ChangelogEntry(type: .improvement, textKey: "优化右键菜单剪切队列交互：非空时收拢为「剪切队列」子菜单，已剪切项支持右键「移出剪切队列」，同目录内「粘贴」自动置灰"),
                ChangelogEntry(type: .improvement, textKey: "收紧右键菜单上下文过滤（按场景按需显示文件比较、代码行数统计、打开路径、切换隐藏文件与常用目录），设置侧边栏按「基础 / 定制 / 系统」分组并重构关于页布局"),
                ChangelogEntry(type: .fix, textKey: "修复访达侧边栏右键菜单项与目标错位、完整设置窗口最小尺寸限制被重置，以及操作历史「清空历史」按钮文字竖排的问题")
            ]
        ),
        ChangelogRelease(
            version: "1.13.4",
            date: "2026-11-25",
            items: [
                ChangelogEntry(type: .feature, textKey: "新增批量重命名（默认关闭）：多选后支持查找替换、前后缀、序号、日期与大小写规则，可实时预览、提示冲突并撤销"),
                ChangelogEntry(type: .improvement, textKey: "优化应用内自动更新下载：放宽首字节超时并新增双源慢启动竞速下载，诊断信息同步补充更新失败原因"),
                ChangelogEntry(type: .improvement, textKey: "优化设置简洁模式切换动画与扩展状态异步检测，深色模式与语言改用分段选择器且仅在语言实际变化时重启"),
                ChangelogEntry(type: .fix, textKey: "修复剪贴板历史收起详情时未恢复展开前尺寸，以及深色模式下详情图标置灰的问题")
            ]
        ),
        ChangelogRelease(
            version: "1.13.3",
            date: "2026-11-23",
            items: [
                ChangelogEntry(type: .feature, textKey: "新增瞬时快照截图方式：支持全屏定格框选、颜色画笔标注与撤销，可直接复制或保存到常用目录"),
                ChangelogEntry(type: .feature, textKey: "剪贴板默认跳过系统「密码」应用（含菜单栏小组件）及带敏感、临时标记的内容，可在设置中按需开启记录"),
                ChangelogEntry(type: .improvement, textKey: "全局快捷键支持单独设置 F1–F12 功能键，并升级二选一胶囊选择器与全局下拉框样式"),
                ChangelogEntry(type: .improvement, textKey: "优化 Git 远端分支状态展示与拉取、推送反馈；右键「服务」菜单改为默认关闭")
            ]
        ),
        ChangelogRelease(
            version: "1.13.2",
            date: "2026-11-20",
            items: [
                ChangelogEntry(type: .feature, textKey: "新增轻量剪贴板历史（默认开启）：在本机保留最近 5–20 条文本、图片与文件，支持退出保留、详情预览、文件拖入与拖出"),
                ChangelogEntry(type: .feature, textKey: "新增可选快速截图入口（默认关闭）：支持通过状态栏菜单或全局快捷键快速唤起系统原生截图"),
                ChangelogEntry(type: .improvement, textKey: "状态栏菜单同步显示剪贴板与截图的自定义快捷键，并精简菜单项文案")
            ]
        ),
        ChangelogRelease(
            version: "1.13.1",
            date: "2026-11-16",
            items: [
                ChangelogEntry(type: .improvement, textKey: "减少 macOS「服务」菜单中只读复制与剪切操作的冗余确认弹窗，触发更流畅"),
                ChangelogEntry(type: .improvement, textKey: "简化粘贴队列与配置读写流程，提升多文件粘贴与日常操作响应速度"),
                ChangelogEntry(type: .fix, textKey: "清理多项冗余逻辑并收拢工具窗口位置记忆与弹窗交互，进一步降低内存与磁盘占用")
            ]
        ),
        ChangelogRelease(
            version: "1.13.0",
            date: "2026-11-13",
            items: [
                ChangelogEntry(type: .feature, textKey: "新增开发者工具：支持哈希校验、符号链接、相对路径、目录树、文件比较与本地 Git 状态等"),
                ChangelogEntry(type: .feature, textKey: "重构剪切队列管理与撤销功能，支持直接在右键菜单查看并管理剪切项"),
                ChangelogEntry(type: .feature, textKey: "关于页新增官方网站入口，弹窗内可一键跳转全球站与国内展示镜像并复制网址"),
                ChangelogEntry(type: .improvement, textKey: "简洁模式支持配置深色模式与右键菜单图标，适配紧凑窗口"),
                ChangelogEntry(type: .fix, textKey: "优化磁盘占用分析中的符号链接过滤与超时预算机制"),
                ChangelogEntry(type: .fix, textKey: "优化直属子项磁盘占用分析，避免大目录超时中断，并放行主目录只读统计"),
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
