import Foundation


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

        if input.location == .sidebar {
            // 侧边栏右键目标始终是该侧边栏文件夹（容器），不混入主窗口的选中项操作
            isContainerLike = true
            hasSelection = false
            hasExplicitSelection = false
            isSingleTextFile = false
            hasRegularFiles = false
            hasArchiveFiles = false
        } else {
            switch input.selection {
            case .empty:
                isContainerLike = true
                hasSelection = false
                hasExplicitSelection = false
                isSingleTextFile = false
                hasRegularFiles = false
                hasArchiveFiles = false
            case .singleFolder:
                isContainerLike = input.location == .container
                hasSelection = true
                hasExplicitSelection = input.location == .items
                isSingleTextFile = false
                hasRegularFiles = false
                hasArchiveFiles = false
            case .singleFile(let isText, let isArchive, let regular, _, _):
                isContainerLike = input.location == .container
                hasSelection = true
                hasExplicitSelection = input.location == .items
                isSingleTextFile = isText
                hasRegularFiles = regular
                hasArchiveFiles = isArchive
            case .multiple(let count, let regular, let archives, _):
                isContainerLike = input.location == .container || count == 0
                hasSelection = count > 0
                hasExplicitSelection = count > 0 && input.location == .items
                isSingleTextFile = false
                hasRegularFiles = regular
                hasArchiveFiles = archives
            }
        }

        let hasCut = input.cutState.count > 0

        func makeCutQueueSubmenu() -> MenuDataNode {
            .formattedSubmenu(
                id: "submenu.cutQueue",
                titleKey: "剪切队列 (%d)",
                count: input.cutState.count,
                systemImage: "tray.full",
                tint: .orange,
                children: [
                    .action(
                        id: "action.showCutQueue",
                        titleKey: "查看详情…",
                        systemImage: "list.bullet",
                        tint: .orange,
                        actionId: "showCutQueueDetail"
                    ),
                    .action(
                        id: "action.cancelCut",
                        titleKey: "取消剪切",
                        systemImage: "xmark.circle",
                        tint: .red,
                        actionId: "cancelCut"
                    )
                ]
            )
        }

        func featureOn(_ id: String) -> Bool {
            input.enabledFeatureIds.contains(id)
        }

        let orderedFeatures = MenuFeatureCatalog.ordered(by: input.menuOrder, developerOrder: input.developerMenuOrder)

        for feature in orderedFeatures where featureOn(feature.id) {
            switch feature.id {
            case MenuFeatureCatalog.diskUsage:
                if let title = input.diskUsageTitle {
                    items.append(.dynamicAction(
                        id: MenuFeatureCatalog.diskUsage,
                        title: title,
                        systemImage: "internaldrive",
                        tint: .blue,
                        actionId: input.isDiskUsageInteractive ? "showDiskUsageDetail" : "",
                        isEnabled: input.isDiskUsageInteractive,
                        toolTip: input.diskUsageToolTip
                    ))
                }
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
                    var children = input.newFileTemplates.map { t in
                        MenuDataNode(
                            id: "newFile.\(t.id)",
                            title: t.isCustom ? .dynamic(t.displayName) : .key(t.displayName),
                            systemImage: t.systemImage,
                            tint: t.tint,
                            kind: .action(actionId: "newFile", tag: t.tag)
                        )
                    }
                    if input.newFileFromClipboard {
                        children.append(.action(id: "newFile.clipboard", titleKey: "从剪贴板新建…",
                                                systemImage: "doc.on.clipboard", actionId: "newFileFromClipboard"))
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
                if hasSelection || input.location == .sidebar {
                    items.append(.action(
                        id: MenuFeatureCatalog.copyPath,
                        titleKey: "复制路径",
                        systemImage: "link",
                        tint: .indigo,
                        actionId: "copyPath",
                        shortcutId: "shortcut.copyPath"
                    ))
                }
            case MenuFeatureCatalog.copyProjectRelativePath:
                if hasSelection {
                    items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                         systemImage: feature.systemImage, tint: feature.tint,
                                         actionId: "copyProjectRelativePath", shortcutId: "shortcut.copyProjectRelativePath"))
                }
            case MenuFeatureCatalog.copyDirectoryTree:
                if input.location == .sidebar
                    || (input.location == .container && input.selection == .empty)
                    || (input.location == .items && input.selection == .singleFolder) {
                    items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                         systemImage: feature.systemImage, tint: feature.tint,
                                         actionId: "copyDirectoryTree", shortcutId: "shortcut.copyDirectoryTree"))
                }
            case MenuFeatureCatalog.gitStatus:
                switch input.selection {
                case .multiple where !isContainerLike: break
                default:
                    items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                         systemImage: feature.systemImage, tint: feature.tint, actionId: "gitStatus"))
                }
            case MenuFeatureCatalog.compareFiles:
                guard input.location == .items else { break }
                switch input.selection {
                case .singleFile(_, _, _, _, let isComparable) where isComparable:
                    items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                         systemImage: feature.systemImage, tint: feature.tint, actionId: "compareFiles"))
                case .multiple(let count, _, _, let canCompare) where count == 2 && canCompare:
                    items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                         systemImage: feature.systemImage, tint: feature.tint, actionId: "compareFiles"))
                default:
                    break
                }
            case MenuFeatureCatalog.filePermissions:
                if let title = input.filePermissionsTitle {
                    items.append(.dynamicAction(
                        id: MenuFeatureCatalog.filePermissions,
                        title: title,
                        systemImage: feature.systemImage,
                        tint: feature.tint,
                        actionId: "copyFilePermissions",
                        isEnabled: true,
                        toolTip: input.filePermissionsToolTip
                    ))
                }
            case MenuFeatureCatalog.lineCount:
                if isContainerLike {
                    items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                         systemImage: feature.systemImage, tint: feature.tint, actionId: "lineCount"))
                } else {
                    switch input.selection {
                    case .empty, .singleFolder:
                        items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                             systemImage: feature.systemImage, tint: feature.tint, actionId: "lineCount"))
                    case .singleFile(_, _, _, let isLineCountable, _) where isLineCountable:
                        items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                             systemImage: feature.systemImage, tint: feature.tint, actionId: "lineCount"))
                    default:
                        break
                    }
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
                if isContainerLike {
                    items.append(.action(
                        id: MenuFeatureCatalog.goToDirectory,
                        titleKey: "打开路径…",
                        systemImage: "arrow.right.circle",
                        tint: .cyan,
                        actionId: "goToDirectory",
                        shortcutId: "shortcut.goToDirectory"
                    ))
                }
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
                if (hasSelection || input.location == .sidebar) && !input.editors.isEmpty {
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
                    if input.cutState.isSelectionSubsetOfCut {
                        items.append(.action(
                            id: MenuFeatureCatalog.cut,
                            titleKey: "移出剪切队列",
                            systemImage: "minus.circle",
                            tint: .orange,
                            actionId: "removeFromCutQueue"
                        ))
                    } else {
                        items.append(.action(
                            id: MenuFeatureCatalog.cut,
                            titleKey: "剪切",
                            systemImage: "scissors",
                            tint: .orange,
                            actionId: "cutFiles",
                            shortcutId: "shortcut.cut"
                        ))
                    }
                }
            case MenuFeatureCatalog.paste:
                let canPaste = hasCut && input.cutState.canPasteInCurrentDirectory
                if hasCut && (canPaste || isContainerLike) {
                    items.append(.formattedAction(
                        id: MenuFeatureCatalog.paste,
                        titleKey: "粘贴 (%d 项)",
                        count: input.cutState.count,
                        systemImage: "doc.on.clipboard",
                        tint: .orange,
                        actionId: "pasteFiles",
                        shortcutId: "shortcut.paste",
                        isEnabled: canPaste
                    ))
                }
            case MenuFeatureCatalog.moveTo:
                if hasExplicitSelection && !input.favoriteDirectories.isEmpty {
                    items.append(buildFavoritesSubmenu(
                        featureId: MenuFeatureCatalog.moveTo,
                        titleKey: "移动到",
                        systemImage: "arrowshape.turn.up.right",
                        actionId: "moveToFavorite",
                        favorites: input.favoriteDirectories
                    ))
                }
            case MenuFeatureCatalog.copyTo:
                if hasExplicitSelection && !input.favoriteDirectories.isEmpty {
                    items.append(buildFavoritesSubmenu(
                        featureId: MenuFeatureCatalog.copyTo,
                        titleKey: "复制到",
                        systemImage: "plus.square.on.square",
                        actionId: "copyToFavorite",
                        favorites: input.favoriteDirectories
                    ))
                }
            case MenuFeatureCatalog.batchRename:
                if hasExplicitSelection, case .multiple = input.selection {
                    items.append(.action(id: feature.id, titleKey: feature.nameKey,
                                         systemImage: feature.systemImage, tint: feature.tint, actionId: "batchRename"))
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
                if isContainerLike {
                    items.append(.action(
                        id: MenuFeatureCatalog.toggleHidden,
                        titleKey: "切换隐藏文件",
                        systemImage: "eye",
                        tint: .pink,
                        actionId: "toggleHiddenFiles",
                        shortcutId: "shortcut.toggleHidden"
                    ))
                }
            default:
                break
            }
        }

        // 剪切队列非空时统一收拢为一个子菜单（紧随粘贴之后，若无粘贴则紧随剪切，关闭开关时兜底追加）
        if hasCut {
            let cutQueueMenu = makeCutQueueSubmenu()
            if let pasteIndex = items.firstIndex(where: { $0.id == MenuFeatureCatalog.paste }) {
                items.insert(cutQueueMenu, at: pasteIndex + 1)
            } else if let cutIndex = items.firstIndex(where: { $0.id == MenuFeatureCatalog.cut }) {
                items.insert(cutQueueMenu, at: cutIndex + 1)
            } else {
                items.append(cutQueueMenu)
            }
        }

        let commands = input.developerCommands.filter { $0.isEnabled && $0.isValid }
        for (index, command) in input.developerCommands.enumerated() where command.isEnabled && command.isValid {
            items.append(.dynamicAction(id: command.menuId, title: command.name, systemImage: "terminal", tint: .purple,
                                        actionId: "runCustomCommand", tag: index))
        }
        let developerIds = MenuFeatureCatalog.developerFeatureIds + commands.map(\.menuId)
        let developerOrder = MenuFeatureCatalog.normalizedOrder(input.developerMenuOrder, defaults: developerIds)
        let developerNodes = Dictionary(items.filter { developerIds.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return items.filter { !developerIds.contains($0.id) } + developerOrder.compactMap { developerNodes[$0] }
    }

    private static func buildFavoritesSubmenu(
        featureId: String,
        titleKey: String,
        systemImage: String,
        actionId: String,
        favorites: [MenuFavoriteData]
    ) -> MenuDataNode {
        var children: [MenuDataNode] = []
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
