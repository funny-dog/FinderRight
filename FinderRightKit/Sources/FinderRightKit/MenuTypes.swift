import Foundation
import UniformTypeIdentifiers

/// 菜单右键触发的位置
public enum MenuTargetLocation: Equatable {
    case container // 窗口空白处（contextualMenuForContainer）
    case sidebar   // 侧边栏（contextualMenuForSidebar）
    case items     // 选中项上（contextualMenuForItems）
}

/// 选中项的纯数据类型判定
public enum SelectionKind: Equatable {
    case empty                                                          // 空白处（无选中项）
    case singleFolder                                                   // 单个文件夹
    case singleFile(isTextEligible: Bool, isArchive: Bool, isRegularFile: Bool = true)              // 单个普通文件
    case multiple(count: Int, hasRegularFiles: Bool, hasArchives: Bool) // 多个文件/文件夹
}

/// 模板纯数据
public struct MenuTemplateData: Equatable {
    public let id: String
    public let displayName: String
    public let isCustom: Bool
    public let systemImage: String?
    public let tint: MenuTint
    public let tag: Int

    public init(id: String, displayName: String, systemImage: String?, tint: MenuTint, tag: Int, isCustom: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isCustom = isCustom
        self.systemImage = systemImage
        self.tint = tint
        self.tag = tag
    }
}

/// 终端纯数据
public struct MenuTerminalData: Equatable {
    public let bundleIdentifier: String
    public let name: String
    public let icon: String?
    public let tag: Int

    public init(bundleIdentifier: String, name: String, icon: String?, tag: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.icon = icon
        self.tag = tag
    }
}

/// 编辑器纯数据
public struct MenuEditorData: Equatable {
    public let bundleIdentifier: String
    public let name: String
    public let icon: String?
    public let tag: Int

    public init(bundleIdentifier: String, name: String, icon: String?, tag: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.icon = icon
        self.tag = tag
    }
}

/// 常用目录纯数据
public struct MenuFavoriteData: Equatable {
    public let path: String
    public let displayName: String
    public let isUnavailable: Bool
    public let canTransfer: Bool
    public let canCopy: Bool
    public let tag: Int

    public init(path: String, displayName: String, isUnavailable: Bool, canTransfer: Bool, tag: Int, canCopy: Bool = true) {
        self.path = path
        self.displayName = displayName
        self.isUnavailable = isUnavailable
        self.canTransfer = canTransfer
        self.canCopy = canCopy
        self.tag = tag
    }
}

/// 剪切队列状态纯数据
public struct CutState: Equatable {
    public let count: Int
    public let isSelectionSubsetOfCut: Bool

    public init(count: Int, isSelectionSubsetOfCut: Bool) {
        self.count = count
        self.isSelectionSubsetOfCut = isSelectionSubsetOfCut
    }
}

/// 图片源格式分类
public enum ImageSourceFormat: String, Codable, Equatable, Hashable {
    case png
    case jpeg
    case heic
    case other

    public static func from(uti: CFString) -> ImageSourceFormat {
        let utiStr = uti as String
        switch utiStr {
        case "public.png":
            return .png
        case "public.jpeg":
            return .jpeg
        case "public.heic", "public.heif":
            return .heic
        default:
            return .other
        }
    }
}

/// 纯数据图片选中状态与菜单可用性判定
public struct ImageMenuState: Equatable {
    public let isAllImages: Bool
    public let formats: [ImageSourceFormat]

    public var allArePNG: Bool { !formats.isEmpty && formats.allSatisfy { $0 == .png } }
    public var allAreJPEG: Bool { !formats.isEmpty && formats.allSatisfy { $0 == .jpeg } }
    public var allAreHEIC: Bool { !formats.isEmpty && formats.allSatisfy { $0 == .heic } }

    public init(isAllImages: Bool, formats: [ImageSourceFormat] = []) {
        self.isAllImages = isAllImages
        self.formats = formats
    }

    /// 只按扩展名判断，不读文件内容：右键菜单在访达主线程上同步构建，既不能等 IPC 也不能读盘，
    /// 且沙箱扩展未必有权读取所选文件。损坏或改名伪装的文件由主 App 执行时逐个校验并说明原因。
    public static func evaluate(selection urls: [URL]) -> ImageMenuState {
        var formats: [ImageSourceFormat] = []
        for url in urls {
            guard !url.hasDirectoryPath,
                  let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else {
                return ImageMenuState(isAllImages: false)
            }
            formats.append(.from(uti: type.identifier as CFString))
        }
        return ImageMenuState(isAllImages: !formats.isEmpty, formats: formats)
    }
}

/// 纯数据菜单树输入上下文
public struct MenuBuildInput: Equatable {
    public var location: MenuTargetLocation
    public var selection: SelectionKind
    public var enabledFeatureIds: Set<String>
    public var menuOrder: [String]
    public var developerMenuOrder: [String]
    public var developerCommands: [DeveloperCommand]
    public var cutState: CutState
    public var undoTitle: String?
    public var newFileTemplates: [MenuTemplateData]
    public var newFileFromClipboard: Bool
    public var terminals: [MenuTerminalData]
    public var editors: [MenuEditorData]
    public var favoriteDirectories: [MenuFavoriteData]
    public var hashAlgorithms: [String]
    public var imageMenuState: ImageMenuState?
    /// 选中项的磁盘占用文案（如「25.1 GB」）；nil 表示当前无法显示（多选、计算中、失败）
    public var diskUsageTitle: String?
    /// 磁盘占用行悬浮提示（全路径或「正在计算」引导）
    public var diskUsageToolTip: String?
    /// 磁盘占用行是否可交互（单选目录且拿到数字时允许点击查看详情）
    public var isDiskUsageInteractive: Bool
    /// 选中项的文件权限文案（如「权限：-rwxr-xr-x (755)」）；nil 表示当前无法显示（多选、失败）
    public var filePermissionsTitle: String?
    /// 文件权限行悬浮提示（所有者信息 + 点击复制引导）
    public var filePermissionsToolTip: String?

    public init(
        location: MenuTargetLocation,
        selection: SelectionKind,
        enabledFeatureIds: Set<String>,
        menuOrder: [String] = MenuFeatureCatalog.all.map(\.id),
        developerMenuOrder: [String] = [],
        developerCommands: [DeveloperCommand] = [],
        cutState: CutState = CutState(count: 0, isSelectionSubsetOfCut: false),
        undoTitle: String? = nil,
        newFileTemplates: [MenuTemplateData] = [],
        newFileFromClipboard: Bool = true,
        terminals: [MenuTerminalData] = [],
        editors: [MenuEditorData] = [],
        favoriteDirectories: [MenuFavoriteData] = [],
        hashAlgorithms: [String] = FileHasher.Algorithm.allCases.map(\.title),
        imageMenuState: ImageMenuState? = nil,
        diskUsageTitle: String? = nil,
        diskUsageToolTip: String? = nil,
        isDiskUsageInteractive: Bool = false,
        filePermissionsTitle: String? = nil,
        filePermissionsToolTip: String? = nil
    ) {
        self.location = location
        self.selection = selection
        self.enabledFeatureIds = enabledFeatureIds
        self.menuOrder = menuOrder
        self.developerMenuOrder = developerMenuOrder
        self.developerCommands = developerCommands
        self.cutState = cutState
        self.undoTitle = undoTitle
        self.newFileTemplates = newFileTemplates
        self.newFileFromClipboard = newFileFromClipboard
        self.terminals = terminals
        self.editors = editors
        self.favoriteDirectories = favoriteDirectories
        self.hashAlgorithms = hashAlgorithms
        self.imageMenuState = imageMenuState
        self.diskUsageTitle = diskUsageTitle
        self.diskUsageToolTip = diskUsageToolTip
        self.isDiskUsageInteractive = isDiskUsageInteractive
        self.filePermissionsTitle = filePermissionsTitle
        self.filePermissionsToolTip = filePermissionsToolTip
    }
}

/// 纯数据菜单节点 —— 不依赖 AppKit/NSMenu 的单一数据源节点表示
public struct MenuDataNode: Equatable {
    public enum Kind: Equatable {
        case action(actionId: String, tag: Int = 0)
        case submenu(children: [MenuDataNode])
        case separator
    }

    public enum Title: Equatable {
        case key(String)
        case dynamic(String)
        case formatted(key: String, count: Int)
        case unavailableDirectory(String)
    }

    public let id: String
    public let title: Title
    public let systemImage: String?
    public let tint: MenuTint
    public let shortcutId: String?
    public let isEnabled: Bool
    public let toolTip: String?
    public let kind: Kind

    public var titleKey: String {
        switch title {
        case .key(let k): return k
        case .dynamic(let d): return d
        case .formatted(let key, _): return key
        case .unavailableDirectory(let name): return name
        }
    }

    public init(
        id: String,
        title: Title,
        systemImage: String? = nil,
        tint: MenuTint = .blue,
        shortcutId: String? = nil,
        isEnabled: Bool = true,
        toolTip: String? = nil,
        kind: Kind
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.shortcutId = shortcutId
        self.isEnabled = isEnabled
        self.toolTip = toolTip
        self.kind = kind
    }
}

extension MenuDataNode {
    public static func action(
        id: String,
        titleKey: String,
        systemImage: String? = nil,
        tint: MenuTint = .blue,
        actionId: String,
        tag: Int = 0,
        shortcutId: String? = nil,
        isEnabled: Bool = true,
        toolTip: String? = nil
    ) -> MenuDataNode {
        MenuDataNode(
            id: id,
            title: .key(titleKey),
            systemImage: systemImage,
            tint: tint,
            shortcutId: shortcutId,
            isEnabled: isEnabled,
            toolTip: toolTip,
            kind: .action(actionId: actionId, tag: tag)
        )
    }

    public static func dynamicAction(
        id: String,
        title: String,
        systemImage: String? = nil,
        tint: MenuTint = .blue,
        actionId: String,
        tag: Int = 0,
        shortcutId: String? = nil,
        isEnabled: Bool = true,
        toolTip: String? = nil
    ) -> MenuDataNode {
        MenuDataNode(
            id: id,
            title: .dynamic(title),
            systemImage: systemImage,
            tint: tint,
            shortcutId: shortcutId,
            isEnabled: isEnabled,
            toolTip: toolTip,
            kind: .action(actionId: actionId, tag: tag)
        )
    }

    public static func formattedAction(
        id: String,
        titleKey: String,
        count: Int,
        systemImage: String? = nil,
        tint: MenuTint = .blue,
        actionId: String,
        tag: Int = 0,
        shortcutId: String? = nil,
        isEnabled: Bool = true,
        toolTip: String? = nil
    ) -> MenuDataNode {
        MenuDataNode(
            id: id,
            title: .formatted(key: titleKey, count: count),
            systemImage: systemImage,
            tint: tint,
            shortcutId: shortcutId,
            isEnabled: isEnabled,
            toolTip: toolTip,
            kind: .action(actionId: actionId, tag: tag)
        )
    }

    public static func submenu(
        id: String,
        titleKey: String,
        systemImage: String? = nil,
        tint: MenuTint = .blue,
        shortcutId: String? = nil,
        isEnabled: Bool = true,
        children: [MenuDataNode]
    ) -> MenuDataNode {
        MenuDataNode(
            id: id,
            title: .key(titleKey),
            systemImage: systemImage,
            tint: tint,
            shortcutId: shortcutId,
            isEnabled: isEnabled,
            kind: .submenu(children: children)
        )
    }

    public static func separator(id: String = "separator") -> MenuDataNode {
        MenuDataNode(
            id: id,
            title: .key(""),
            systemImage: nil,
            tint: .gray,
            kind: .separator
        )
    }
}
