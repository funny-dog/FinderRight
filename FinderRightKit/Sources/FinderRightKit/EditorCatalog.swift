import Foundation

/// 一个已知的编辑器应用。
public struct KnownEditor: Identifiable, Equatable {
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
/// `all` 的顺序即子菜单展示顺序：Zed 置顶为首选默认。
/// 扩展会用 NSWorkspace 过滤出实际已安装的项再展示。
public enum EditorCatalog {
    public static let all: [KnownEditor] = [
        KnownEditor(id: "dev.zed.Zed",                   name: "Zed"),
        KnownEditor(id: "com.microsoft.VSCode",          name: "Visual Studio Code"),
        KnownEditor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        KnownEditor(id: "com.sublimetext.4",             name: "Sublime Text"),
        KnownEditor(id: "com.apple.dt.Xcode",            name: "Xcode"),
        KnownEditor(id: "com.panic.Nova",                name: "Nova"),
        KnownEditor(id: "com.barebones.bbedit",          name: "BBEdit"),
        KnownEditor(id: "com.apple.TextEdit",            name: "TextEdit"),
    ]
}
