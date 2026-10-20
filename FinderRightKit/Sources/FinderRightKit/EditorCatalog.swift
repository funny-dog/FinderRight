import Foundation

/// 一个编辑器应用（预置清单项或用户手动添加项）。
public struct KnownEditor: Identifiable, Equatable, Codable {
    /// bundle identifier，同时作为 Identifiable 的 id
    public let id: String
    /// 显示名（品牌名，不本地化）
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// 已知编辑器清单 —— 右键「打开编辑器」子菜单的数据源（单一事实来源）。
///
/// `all` 的顺序为默认展示顺序；扩展会用 NSWorkspace 过滤出实际已安装的项再展示。
/// macOS 没有「这是代码编辑器」的可靠元数据（实测 Antigravity 不声明任何文档类型，
/// Typora 与 Zed 的声明几乎一致），所以自动识别只靠这份清单，清单外的由用户在设置里手动添加。
public enum EditorCatalog {
    public static let all: [KnownEditor] = [
        // 通用代码编辑器
        KnownEditor(id: "dev.zed.Zed",                   name: "Zed"),
        KnownEditor(id: "dev.zed.Zed-Preview",           name: "Zed Preview"),
        KnownEditor(id: "com.microsoft.VSCode",          name: "Visual Studio Code"),
        KnownEditor(id: "com.microsoft.VSCodeInsiders",  name: "Visual Studio Code - Insiders"),
        KnownEditor(id: "com.vscodium",                  name: "VSCodium"),
        KnownEditor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        KnownEditor(id: "com.exafunction.windsurf",      name: "Windsurf"),
        KnownEditor(id: "com.google.antigravity",        name: "Antigravity"),
        KnownEditor(id: "com.trae.app",                  name: "Trae"),
        KnownEditor(id: "cn.trae.app",                   name: "Trae CN"),
        KnownEditor(id: "com.sublimetext.4",             name: "Sublime Text"),
        KnownEditor(id: "com.sublimetext.3",             name: "Sublime Text 3"),
        KnownEditor(id: "com.panic.Nova",                name: "Nova"),
        KnownEditor(id: "com.barebones.bbedit",          name: "BBEdit"),
        KnownEditor(id: "com.macromates.TextMate",       name: "TextMate"),
        KnownEditor(id: "com.coteditor.CotEditor",       name: "CotEditor"),
        KnownEditor(id: "org.vim.MacVim",                name: "MacVim"),
        KnownEditor(id: "org.gnu.Emacs",                 name: "Emacs"),
        // IDE
        KnownEditor(id: "com.apple.dt.Xcode",            name: "Xcode"),
        KnownEditor(id: "com.jetbrains.intellij",        name: "IntelliJ IDEA"),
        KnownEditor(id: "com.jetbrains.intellij.ce",     name: "IntelliJ IDEA CE"),
        KnownEditor(id: "com.jetbrains.pycharm",         name: "PyCharm"),
        KnownEditor(id: "com.jetbrains.pycharm.ce",      name: "PyCharm CE"),
        KnownEditor(id: "com.jetbrains.WebStorm",        name: "WebStorm"),
        KnownEditor(id: "com.jetbrains.goland",          name: "GoLand"),
        KnownEditor(id: "com.jetbrains.CLion",           name: "CLion"),
        KnownEditor(id: "com.jetbrains.rustrover",       name: "RustRover"),
        KnownEditor(id: "com.jetbrains.PhpStorm",        name: "PhpStorm"),
        KnownEditor(id: "com.jetbrains.rubymine",        name: "RubyMine"),
        KnownEditor(id: "com.jetbrains.rider",           name: "Rider"),
        KnownEditor(id: "com.google.android.studio",     name: "Android Studio"),
        // 系统自带，兜底
        KnownEditor(id: textEditBundleId,                name: "TextEdit"),
    ]

    /// 系统「文本编辑」：所有编辑器都未安装时的最终兜底
    public static let textEditBundleId = "com.apple.TextEdit"

    public static func ordered(_ editors: [KnownEditor], by savedOrder: [String]) -> [KnownEditor] {
        var remaining = editors
        var result: [KnownEditor] = []
        for id in savedOrder {
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { continue }
            result.append(remaining.remove(at: index))
        }
        return result + remaining
    }

    /// 所有可用编辑器按已保存顺序展示；未配置顺序的项按清单和手动添加顺序补到末尾。
    /// 手动添加项与清单重复时以清单为准，避免同一应用出现两次。
    public static func installed(custom: [KnownEditor], order: [String] = [], isInstalled: (String) -> Bool) -> [KnownEditor] {
        var result = all.filter { isInstalled($0.id) }
        var seen = Set(all.map(\.id))
        for editor in custom where !seen.contains(editor.id) && isInstalled(editor.id) {
            result.append(editor)
            seen.insert(editor.id)
        }
        return ordered(result, by: order)
    }

    /// 右键子菜单展示的编辑器：可用编辑器中去掉用户隐藏的项
    public static func menuEditors(custom: [KnownEditor], hidden: Set<String>, order: [String] = [],
                                   isInstalled: (String) -> Bool) -> [KnownEditor] {
        installed(custom: custom, order: order, isInstalled: isInstalled).filter { !hidden.contains($0.id) }
    }

    /// 解析默认编辑器（服务菜单 / 快捷键「打开编辑器」使用）：
    /// 用户选定且仍已安装 → 右键菜单中的第一个 → 任一已安装（即使被隐藏）→ 文本编辑。
    public static func resolvedDefault(preferred: String?, custom: [KnownEditor], hidden: Set<String>, order: [String] = [],
                                       isInstalled: (String) -> Bool) -> String {
        let available = installed(custom: custom, order: order, isInstalled: isInstalled)
        if let preferred, available.contains(where: { $0.id == preferred }) {
            return preferred
        }
        if let first = available.first(where: { !hidden.contains($0.id) }) ?? available.first {
            return first.id
        }
        return textEditBundleId
    }
}

/// 「添加编辑器」时的候选识别：判断一个应用是否像代码编辑器。
///
/// 规则：应用在自己的 Info.plist 里以 Editor 角色**显式**声明了至少一种具体代码文件
/// （扩展名或对应 UTI）。只声明 public.plain-text 等通用类型的（文本编辑、备忘录、Typora、
/// 浏览器）都会被排除；但终端也会声明 .sh，需要调用方另行排除。
public enum EditorDiscovery {
    /// 有代表性的代码文件扩展名：既用来向 LaunchServices 查询候选，也用来判断显式声明
    public static let codeExtensions: [String] = [
        "swift", "py", "js", "ts", "json", "c", "cpp", "h", "go", "rs",
        "java", "kt", "rb", "php", "lua", "vue", "yaml", "toml", "sh",
    ]

    /// - Parameters:
    ///   - infoDictionary: 应用的 Info.plist 内容
    ///   - codeTypeIdentifiers: 代码扩展名对应的 UTI（由调用方经 UTType 解析后传入，保持本函数纯逻辑）
    public static func declaresCodeEditing(infoDictionary: [String: Any],
                                           codeTypeIdentifiers: Set<String>) -> Bool {
        guard let docTypes = infoDictionary["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        let exts = Set(codeExtensions)
        for doc in docTypes where (doc["CFBundleTypeRole"] as? String ?? "Editor") == "Editor" {
            let declaredExts = (doc["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() }
            if declaredExts.contains(where: exts.contains) { return true }
            let declaredTypes = doc["LSItemContentTypes"] as? [String] ?? []
            if declaredTypes.contains(where: codeTypeIdentifiers.contains) { return true }
        }
        return false
    }

    /// 只推荐常规安装位置的应用：浏览器测试副本、挂载中的 DMG、App 内嵌 Helper 等不算
    public static func isStandardInstallLocation(_ appPath: String, home: String) -> Bool {
        let roots = ["/Applications/", "/System/Applications/", home + "/Applications/"]
        guard roots.contains(where: appPath.hasPrefix) else { return false }
        // 排除 App 包内嵌的子应用（如 Doubao.app/Contents/Helpers/Doubao Browser.app）
        return !appPath.dropLast(4).contains(".app/")
    }
}
