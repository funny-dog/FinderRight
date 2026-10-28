import Foundation

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

/// 单个图片的探测结果（纯数据模型，用于 MenuModel 纯决策输入）
public struct InspectedImageItem: Equatable {
    public let format: ImageSourceFormat
    public let width: Int
    public let height: Int

    public init(format: ImageSourceFormat, width: Int, height: Int) {
        self.format = format
        self.width = width
        self.height = height
    }
}

/// 图片源格式分类
public enum ImageSourceFormat: String, Equatable, Hashable {
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

    /// 纯决策：由图片检测结果列表决定是否全为有效图片及各格式分布（MenuModel 纯逻辑）
    public static func evaluate(inspected items: [InspectedImageItem]) -> ImageMenuState {
        guard !items.isEmpty else {
            return ImageMenuState(isAllImages: false, formats: [])
        }
        for item in items {
            guard item.width > 0, item.height > 0 else {
                return ImageMenuState(isAllImages: false, formats: [])
            }
        }
        return ImageMenuState(isAllImages: true, formats: items.map(\.format))
    }

    /// 检验普通可读文件及 ImageIO 实际图像类型/有效尺寸（不完整解码大图）
    public static func evaluate(urls: [URL]) -> ImageMenuState {
        guard !urls.isEmpty else {
            return ImageMenuState(isAllImages: false, formats: [])
        }
        var inspected: [InspectedImageItem] = []
        inspected.reserveCapacity(urls.count)

        for url in urls {
            let path = url.path
            var isDir: ObjCBool = false
            // 必须是已存在的文件、不可为目录、必须可读
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
                  !isDir.boolValue,
                  FileManager.default.isReadableFile(atPath: path) else {
                return ImageMenuState(isAllImages: false, formats: [])
            }
            // 排除目录伪装为 .png 等非常规文件
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else {
                return ImageMenuState(isAllImages: false, formats: [])
            }
            // 通过 ImageIO 读取头部实际类型与有效尺寸（不完整解码大图）
            guard let item = ImageTransformer.inspectImageHeader(at: url) else {
                return ImageMenuState(isAllImages: false, formats: [])
            }
            inspected.append(item)
        }

        return evaluate(inspected: inspected)
    }
}

/// 纯数据菜单树输入上下文
public struct MenuBuildInput: Equatable {
    public var location: MenuTargetLocation
    public var selection: SelectionKind
    public var enabledFeatureIds: Set<String>
    public var menuOrder: [String]
    public var cutState: CutState
    public var undoTitle: String?
    public var newFileTemplates: [MenuTemplateData]
    public var terminals: [MenuTerminalData]
    public var editors: [MenuEditorData]
    public var favoriteDirectories: [MenuFavoriteData]
    public var hashAlgorithms: [String]
    public var imageMenuState: ImageMenuState?

    public init(
        location: MenuTargetLocation,
        selection: SelectionKind,
        enabledFeatureIds: Set<String>,
        menuOrder: [String] = MenuFeatureCatalog.all.map(\.id),
        cutState: CutState = CutState(count: 0, isSelectionSubsetOfCut: false),
        undoTitle: String? = nil,
        newFileTemplates: [MenuTemplateData] = [],
        terminals: [MenuTerminalData] = [],
        editors: [MenuEditorData] = [],
        favoriteDirectories: [MenuFavoriteData] = [],
        hashAlgorithms: [String] = FileHasher.Algorithm.allCases.map(\.title),
        imageMenuState: ImageMenuState? = nil
    ) {
        self.location = location
        self.selection = selection
        self.enabledFeatureIds = enabledFeatureIds
        self.menuOrder = menuOrder
        self.cutState = cutState
        self.undoTitle = undoTitle
        self.newFileTemplates = newFileTemplates
        self.terminals = terminals
        self.editors = editors
        self.favoriteDirectories = favoriteDirectories
        self.hashAlgorithms = hashAlgorithms
        self.imageMenuState = imageMenuState
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

        public var rawString: String {
            switch self {
            case .key(let s): return s
            case .dynamic(let s): return s
            case .formatted(let key, let count): return "\(key) (\(count))"
            case .unavailableDirectory(let name): return name
            }
        }
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

/// 纯数据菜单树构建器 —— 集中处理所有菜单项的过滤与排序逻辑
public enum MenuTreeBuilder {

    /// 根据输入上下文构建纯数据菜单树
    public static func buildMenuTree(input: MenuBuildInput) -> [MenuDataNode] {
        var items: [MenuDataNode] = []

        let isContainerLike: Bool
        let hasSelection: Bool
        let hasExplicitSelection: Bool
        let isSingleTextFile: Bool
        let hasRegularFiles: Bool
        let hasArchiveFiles: Bool

        switch input.selection {
        case .empty:
            isContainerLike = true
            hasSelection = false
            hasExplicitSelection = false
            isSingleTextFile = false
            hasRegularFiles = false
            hasArchiveFiles = false
        case .singleFolder:
            isContainerLike = input.location == .container || input.location == .sidebar
            hasSelection = true
            hasExplicitSelection = input.location != .container
            isSingleTextFile = false
            hasRegularFiles = false
            hasArchiveFiles = false
        case .singleFile(let isText, let isArchive, let regular):
            isContainerLike = input.location == .container || input.location == .sidebar
            hasSelection = true
            hasExplicitSelection = input.location != .container
            isSingleTextFile = isText
            hasRegularFiles = regular
            hasArchiveFiles = isArchive
        case .multiple(let count, let regular, let archives):
            isContainerLike = input.location == .container || input.location == .sidebar || count == 0
            hasSelection = count > 0
            hasExplicitSelection = count > 0 && input.location != .container
            isSingleTextFile = false
            hasRegularFiles = regular
            hasArchiveFiles = archives
        }

        let hasCut = input.cutState.count > 0

        func makeCancelCutItem() -> MenuDataNode {
            .action(
                id: "action.cancelCut",
                titleKey: "取消剪切",
                systemImage: "xmark.circle",
                tint: .red,
                actionId: "cancelCut"
            )
        }

        func featureOn(_ id: String) -> Bool {
            input.enabledFeatureIds.contains(id)
        }

        let orderedFeatures = MenuFeatureCatalog.ordered(by: input.menuOrder)

        for feature in orderedFeatures where featureOn(feature.id) {
            switch feature.id {
            case MenuFeatureCatalog.undo:
                if let undoTitle = input.undoTitle {
                    items.append(.dynamicAction(
                        id: MenuFeatureCatalog.undo,
                        title: undoTitle,
                        systemImage: "arrow.uturn.backward",
                        tint: .gray,
                        actionId: "undoLast",
                        shortcutId: "shortcut.undo"
                    ))
                }
            case MenuFeatureCatalog.newFile:
                if isContainerLike {
                    let children = input.newFileTemplates.map { t in
                        MenuDataNode(
                            id: "newFile.\(t.id)",
                            title: t.isCustom ? .dynamic(t.displayName) : .key(t.displayName),
                            systemImage: t.systemImage,
                            tint: t.tint,
                            kind: .action(actionId: "newFile", tag: t.tag)
                        )
                    }
                    items.append(.submenu(
                        id: MenuFeatureCatalog.newFile,
                        titleKey: "新建文件",
                        systemImage: "doc.badge.plus",
                        tint: .blue,
                        shortcutId: "shortcut.newFile",
                        children: children
                    ))
                }
            case MenuFeatureCatalog.copyPath:
                if hasSelection {
                    items.append(.action(
                        id: MenuFeatureCatalog.copyPath,
                        titleKey: "复制路径",
                        systemImage: "link",
                        tint: .indigo,
                        actionId: "copyPath",
                        shortcutId: "shortcut.copyPath"
                    ))
                }
            case MenuFeatureCatalog.copyFileName:
                if hasSelection {
                    items.append(.action(
                        id: MenuFeatureCatalog.copyFileName,
                        titleKey: "复制文件名",
                        systemImage: "character.cursor.ibeam",
                        tint: .indigo,
                        actionId: "copyFileName",
                        shortcutId: "shortcut.copyFileName"
                    ))
                }
            case MenuFeatureCatalog.copyFileContent:
                if isSingleTextFile {
                    items.append(.action(
                        id: MenuFeatureCatalog.copyFileContent,
                        titleKey: "复制文件内容",
                        systemImage: "doc.plaintext",
                        tint: .teal,
                        actionId: "copyFileContent",
                        shortcutId: "shortcut.copyFileContent"
                    ))
                }
            case MenuFeatureCatalog.copyFileHash:
                if hasSelection && hasRegularFiles {
                    let children = input.hashAlgorithms.enumerated().map { index, title in
                        MenuDataNode.dynamicAction(
                            id: "copyFileHash.\(index)",
                            title: title,
                            tint: .teal,
                            actionId: "copyFileHash",
                            tag: index
                        )
                    }
                    items.append(.submenu(
                        id: MenuFeatureCatalog.copyFileHash,
                        titleKey: "复制哈希",
                        systemImage: "number",
                        tint: .teal,
                        children: children
                    ))
                }
            case MenuFeatureCatalog.goToDirectory:
                items.append(.action(
                    id: MenuFeatureCatalog.goToDirectory,
                    titleKey: "打开路径…",
                    systemImage: "arrow.right.circle",
                    tint: .cyan,
                    actionId: "goToDirectory",
                    shortcutId: "shortcut.goToDirectory"
                ))
            case MenuFeatureCatalog.openTerminal:
                if !input.terminals.isEmpty {
                    let children = input.terminals.map { t in
                        MenuDataNode.dynamicAction(
                            id: "openTerminal.\(t.bundleIdentifier)",
                            title: t.name,
                            systemImage: t.icon,
                            tint: .graphite,
                            actionId: "openTerminal",
                            tag: t.tag
                        )
                    }
                    items.append(.submenu(
                        id: MenuFeatureCatalog.openTerminal,
                        titleKey: "打开终端",
                        systemImage: "terminal",
                        tint: .graphite,
                        shortcutId: "shortcut.openTerminal",
                        children: children
                    ))
                }
            case MenuFeatureCatalog.openEditor:
                if hasSelection && !input.editors.isEmpty {
                    let children = input.editors.map { e in
                        MenuDataNode.dynamicAction(
                            id: "openEditor.\(e.bundleIdentifier)",
                            title: e.name,
                            systemImage: e.icon,
                            tint: .purple,
                            actionId: "openEditor",
                            tag: e.tag
                        )
                    }
                    items.append(.submenu(
                        id: MenuFeatureCatalog.openEditor,
                        titleKey: "打开编辑器",
                        systemImage: "curlybraces",
                        tint: .purple,
                        shortcutId: "shortcut.openEditor",
                        children: children
                    ))
                }
            case MenuFeatureCatalog.cut:
                if hasExplicitSelection {
                    let cutTitleKey = input.cutState.isSelectionSubsetOfCut ? "剪切 (已在剪切队列)" : "剪切"
                    items.append(.action(
                        id: MenuFeatureCatalog.cut,
                        titleKey: cutTitleKey,
                        systemImage: "scissors",
                        tint: .orange,
                        actionId: "cutFiles",
                        shortcutId: "shortcut.cut"
                    ))
                }
                if hasCut {
                    items.append(makeCancelCutItem())
                }
            case MenuFeatureCatalog.paste:
                if hasCut || isContainerLike {
                    if hasCut {
                        items.append(.formattedAction(
                            id: MenuFeatureCatalog.paste,
                            titleKey: "粘贴 (已剪切 %d 项)",
                            count: input.cutState.count,
                            systemImage: "doc.on.clipboard",
                            tint: .orange,
                            actionId: "pasteFiles",
                            shortcutId: "shortcut.paste",
                            isEnabled: true
                        ))
                    } else {
                        items.append(.action(
                            id: MenuFeatureCatalog.paste,
                            titleKey: "粘贴",
                            systemImage: "doc.on.clipboard",
                            tint: .orange,
                            actionId: "pasteFiles",
                            shortcutId: "shortcut.paste",
                            isEnabled: false
                        ))
                    }
                }
            case MenuFeatureCatalog.moveTo:
                if hasExplicitSelection {
                    items.append(buildFavoritesSubmenu(
                        featureId: MenuFeatureCatalog.moveTo,
                        titleKey: "移动到",
                        systemImage: "arrowshape.turn.up.right",
                        actionId: "moveToFavorite",
                        favorites: input.favoriteDirectories
                    ))
                }
            case MenuFeatureCatalog.copyTo:
                if hasExplicitSelection {
                    items.append(buildFavoritesSubmenu(
                        featureId: MenuFeatureCatalog.copyTo,
                        titleKey: "复制到",
                        systemImage: "plus.square.on.square",
                        actionId: "copyToFavorite",
                        favorites: input.favoriteDirectories
                    ))
                }
            case MenuFeatureCatalog.createSymlink:
                if hasExplicitSelection {
                    items.append(.action(
                        id: MenuFeatureCatalog.createSymlink,
                        titleKey: "创建符号链接",
                        systemImage: "link.badge.plus",
                        tint: .green,
                        actionId: "createSymlink"
                    ))
                }
            case MenuFeatureCatalog.imageTools:
                if hasExplicitSelection, let state = input.imageMenuState, state.isAllImages {
                    var children: [MenuDataNode] = []
                    if !state.allArePNG {
                        children.append(.action(
                            id: "image.convertToPNG",
                            titleKey: "转换为 PNG",
                            tint: .teal,
                            actionId: "convertImage",
                            tag: 0
                        ))
                    }
                    if !state.allAreJPEG {
                        children.append(.action(
                            id: "image.convertToJPEG",
                            titleKey: "转换为 JPEG",
                            tint: .teal,
                            actionId: "convertImage",
                            tag: 1
                        ))
                    }
                    if !state.allAreHEIC {
                        children.append(.action(
                            id: "image.convertToHEIC",
                            titleKey: "转换为 HEIC",
                            tint: .teal,
                            actionId: "convertImage",
                            tag: 2
                        ))
                    }
                    if !children.isEmpty {
                        children.append(.separator(id: "image.separator"))
                    }
                    children.append(.action(
                        id: "image.scale2560",
                        titleKey: "缩放到 2560 像素",
                        tint: .teal,
                        actionId: "scaleImage",
                        tag: 2560
                    ))
                    children.append(.action(
                        id: "image.scale1920",
                        titleKey: "缩放到 1920 像素",
                        tint: .teal,
                        actionId: "scaleImage",
                        tag: 1920
                    ))
                    children.append(.action(
                        id: "image.scale1280",
                        titleKey: "缩放到 1280 像素",
                        tint: .teal,
                        actionId: "scaleImage",
                        tag: 1280
                    ))
                    children.append(.action(
                        id: "image.scale800",
                        titleKey: "缩放到 800 像素",
                        tint: .teal,
                        actionId: "scaleImage",
                        tag: 800
                    ))
                    items.append(.submenu(
                        id: MenuFeatureCatalog.imageTools,
                        titleKey: "图片",
                        systemImage: "photo.on.rectangle.angled",
                        tint: .teal,
                        children: children
                    ))
                }
            case MenuFeatureCatalog.compress:
                if hasExplicitSelection {
                    items.append(.action(
                        id: MenuFeatureCatalog.compress,
                        titleKey: "压缩为 ZIP",
                        systemImage: "doc.zipper",
                        tint: .brown,
                        actionId: "archiveOperation",
                        tag: 0,
                        shortcutId: "shortcut.compress"
                    ))
                }
            case MenuFeatureCatalog.decompress:
                if hasSelection && hasArchiveFiles {
                    items.append(.action(
                        id: MenuFeatureCatalog.decompress,
                        titleKey: "解压到当前目录",
                        systemImage: "shippingbox.and.arrow.backward",
                        tint: .brown,
                        actionId: "archiveOperation",
                        tag: 2,
                        shortcutId: "shortcut.decompress"
                    ))
                }
            case MenuFeatureCatalog.toggleHidden:
                items.append(.action(
                    id: MenuFeatureCatalog.toggleHidden,
                    titleKey: "切换隐藏文件",
                    systemImage: "eye",
                    tint: .pink,
                    actionId: "toggleHiddenFiles",
                    shortcutId: "shortcut.toggleHidden"
                ))
            default:
                break
            }
        }

        // 当「剪切」功能被用户关闭但剪切队列不为空时，补齐「取消剪切」
        if hasCut && !featureOn(MenuFeatureCatalog.cut) {
            let cancelCut = makeCancelCutItem()
            if let pasteIndex = items.firstIndex(where: { $0.id == MenuFeatureCatalog.paste }) {
                items.insert(cancelCut, at: pasteIndex + 1)
            } else {
                items.append(cancelCut)
            }
        }

        return items
    }

    private static func buildFavoritesSubmenu(
        featureId: String,
        titleKey: String,
        systemImage: String,
        actionId: String,
        favorites: [MenuFavoriteData]
    ) -> MenuDataNode {
        var children: [MenuDataNode] = []
        if favorites.isEmpty {
            children.append(.action(
                id: "\(featureId).empty",
                titleKey: "尚未添加常用目录",
                tint: .gray,
                actionId: "",
                isEnabled: false
            ))
        } else {
            for fav in favorites {
                let title: MenuDataNode.Title = fav.isUnavailable ? .unavailableDirectory(fav.displayName) : .dynamic(fav.displayName)
                children.append(MenuDataNode(
                    id: "\(featureId).\(fav.tag)",
                    title: title,
                    systemImage: "folder",
                    tint: .cyan,
                    isEnabled: !fav.isUnavailable && (featureId == MenuFeatureCatalog.copyTo ? fav.canCopy : fav.canTransfer),
                    toolTip: fav.path,
                    kind: .action(actionId: actionId, tag: fav.tag)
                ))
            }
        }
        children.append(.separator(id: "\(featureId).separator"))
        children.append(.action(
            id: "\(featureId).manage",
            titleKey: "管理常用目录…",
            systemImage: "gearshape",
            tint: .gray,
            actionId: "manageFavorites"
        ))

        return .submenu(
            id: featureId,
            titleKey: titleKey,
            systemImage: systemImage,
            tint: .green,
            children: children
        )
    }
}
