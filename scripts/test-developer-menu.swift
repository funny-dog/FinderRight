import Foundation
import FinderRightKit

@main
struct DeveloperMenuChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = SharedConfig(fileURL: directory.appendingPathComponent("settings.plist"))
        let relative = MenuFeatureCatalog.copyProjectRelativePath
        let tree = MenuFeatureCatalog.copyDirectoryTree
        let compare = MenuFeatureCatalog.compareFiles
        let git = MenuFeatureCatalog.gitStatus
        assert(!config.developerToolsEnabled && !config.isActionEnabled(relative) && !config.isActionEnabled(tree) && !config.isActionEnabled(compare) && !config.isActionEnabled(git))
        config.developerToolsEnabled = true
        assert(config.isActionEnabled(relative) && config.isActionEnabled(tree))
        config.setActionEnabled(tree, enabled: false)
        config.developerToolsEnabled = false
        assert(!config.isActionEnabled(relative))
        let reloaded = SharedConfig(fileURL: directory.appendingPathComponent("settings.plist"))
        reloaded.developerToolsEnabled = true
        assert(reloaded.isActionEnabled(relative) && !reloaded.isActionEnabled(tree))

        let original = MenuFeatureCatalog.all.map(\.id).filter { !MenuFeatureCatalog.developerFeatureIds.contains($0) }.reversed()
        let upgraded = MenuFeatureCatalog.ordered(by: Array(original)).map(\.id)
        assert(Array(upgraded.suffix(4)) == [relative, tree, compare, git])
        assert(Array(upgraded.dropLast(4)) == Array(original))
        let reordered = MenuFeatureCatalog.ordered(by: [tree] + Array(original) + [relative]).map(\.id)
        assert(Array(reordered.suffix(4)) == [relative, tree, compare, git])
        let independent = MenuFeatureCatalog.ordered(by: Array(original), developerOrder: [tree, relative]).map(\.id)
        assert(Array(independent.dropLast(4)) == Array(original))
        assert(Array(independent.suffix(4)) == [tree, compare, git, relative])
        reloaded.developerMenuOrder = [tree, relative]
        assert(SharedConfig(fileURL: directory.appendingPathComponent("settings.plist")).developerMenuOrder == [tree, relative])

        let enabled = Set([relative, tree])
        let fileMenu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .items, selection: .singleFile(isTextEligible: true, isArchive: false), enabledFeatureIds: enabled))
        assert(fileMenu.map(\.id) == [relative])
        let folderMenu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .items, selection: .singleFolder, enabledFeatureIds: enabled))
        assert(folderMenu.map(\.id) == [relative, tree])
        for node in folderMenu {
            guard case .action = node.kind else { fatalError("开发者功能必须是同级操作，不能生成子菜单") }
        }
        let emptyMenu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .container, selection: .empty, enabledFeatureIds: enabled))
        assert(emptyMenu.map(\.id) == [tree])
        let multipleMenu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .items, selection: .multiple(count: 2, hasRegularFiles: true, hasArchives: false), enabledFeatureIds: enabled))
        assert(multipleMenu.map(\.id) == [relative])
        let disabledMenu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .items, selection: .singleFolder, enabledFeatureIds: []))
        assert(disabledMenu.isEmpty)
        for selection in [SelectionKind.empty, .singleFolder, .singleFile(isTextEligible: true, isArchive: false),
                          .multiple(count: 2, hasRegularFiles: true, hasArchives: false)] {
            let menu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
                location: .items, selection: selection, enabledFeatureIds: [compare]))
            assert(menu.map(\.id) == [compare])
            guard case .action(let action, _) = menu[0].kind else { fatalError("文件比较必须直接显示") }
            assert(action == "compareFiles")
        }

        for selection in [SelectionKind.empty, .singleFolder, .singleFile(isTextEligible: true, isArchive: false)] {
            let menu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
                location: .items, selection: selection, enabledFeatureIds: [git]))
            assert(menu.map(\.id) == [git])
            guard case .action(let action, _) = menu[0].kind else { fatalError("Git 状态必须直接显示") }
            assert(action == "gitStatus")
        }
        assert(MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .items, selection: .multiple(count: 2, hasRegularFiles: true, hasArchives: false), enabledFeatureIds: [git])).isEmpty)

        assert(MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .container, selection: .multiple(count: 2, hasRegularFiles: true, hasArchives: false), enabledFeatureIds: [git])).map(\.id) == [git])

        let command = DeveloperCommand(name: "检查项目", script: "pwd")
        reloaded.developerCommands = [command]
        assert(SharedConfig(fileURL: directory.appendingPathComponent("settings.plist")).developerCommands == [command])
        assert(reloaded.developerCommand(id: command.id) == command)
        assert(reloaded.developerCommand(id: UUID().uuidString) == nil)
        reloaded.developerToolsEnabled = false
        assert(reloaded.developerCommand(id: command.id) == nil)
        reloaded.developerToolsEnabled = true
        var hiddenCommand = command
        hiddenCommand.isEnabled = false
        reloaded.developerCommands = [hiddenCommand]
        assert(reloaded.developerCommand(id: command.id) == nil)
        reloaded.developerCommands = [command]
        let commandMenu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .items, selection: .singleFolder, enabledFeatureIds: [relative, tree, MenuFeatureCatalog.toggleHidden],
            menuOrder: [tree, MenuFeatureCatalog.toggleHidden, relative],
            developerMenuOrder: [command.menuId, tree, relative], developerCommands: [command]))
        assert(commandMenu.map(\.id) == [MenuFeatureCatalog.toggleHidden, command.menuId, tree, relative])
        guard case .action(let action, _) = commandMenu[1].kind else { fatalError("自定义命令必须直接显示") }
        assert(action == "runCustomCommand")
        let hiddenCommandMenu = MenuTreeBuilder.buildMenuTree(input: MenuBuildInput(
            location: .items, selection: .singleFolder, enabledFeatureIds: [], developerCommands: [hiddenCommand]))
        assert(hiddenCommandMenu.isEmpty)

        let service: [String: Any] = ["NSMenuItem": ["default": "FinderRight: Copy Directory Tree"], "NSMessage": "copyDirectoryTree"]
        let key = "test.bundle - FinderRight: Copy Directory Tree - copyDirectoryTree"
        let hidden = ServiceShortcuts.mergedStatus([:], bundleId: "test.bundle", shortcuts: [:],
                                                  services: [service], showsInServicesMenu: true,
                                                  serviceVisibility: ["copyDirectoryTree": false])
        assert((hidden[key] as? [String: Any])?["enabled_context_menu"] as? Bool == false)
        let shown = ServiceShortcuts.mergedStatus(hidden, bundleId: "test.bundle", shortcuts: [:],
                                                 services: [service], serviceVisibility: ["copyDirectoryTree": true])
        assert((shown[key] as? [String: Any])?["enabled_services_menu"] as? Bool == true)
        print("✓ 开发者菜单：默认关闭、配置保留、底部排序、同级入口、选择条件和服务显隐通过")
    }
}
