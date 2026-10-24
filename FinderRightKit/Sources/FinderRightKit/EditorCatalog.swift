import Foundation
import AppKit
import UniformTypeIdentifiers

/// 一个已声明文本编辑能力的应用。
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

/// 设置、菜单与执行入口共用的文本编辑能力识别，不维护品牌清单。
public enum EditorCatalog {
    public static let textEditBundleId = "com.apple.TextEdit"

    private static let discoveryExtensions = [
        "txt", "md", "swift", "py", "js", "ts", "json", "c", "cpp", "h", "go", "rs",
        "java", "kt", "rb", "php", "lua", "vue", "yaml", "toml", "sh",
    ]

    public static func declaresEditing(infoDictionary: [String: Any]) -> Bool {
        guard !TerminalCatalog.declaresShell(infoDictionary: infoDictionary),
              let documents = infoDictionary["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        return documents.contains { document in
            guard document["CFBundleTypeRole"] as? String == "Editor" else { return false }
            let types = document["LSItemContentTypes"] as? [String] ?? []
            if !types.isEmpty {
                return types.contains { UTType($0)?.conforms(to: .text) == true }
            }
            let extensions = document["CFBundleTypeExtensions"] as? [String] ?? []
            if extensions.contains(where: { $0 == "*" || UTType(filenameExtension: $0.lowercased())?.conforms(to: .text) == true }) {
                return true
            }
            let osTypes = document["CFBundleTypeOSTypes"] as? [String] ?? []
            return !Set(["TEXT", "utxt", "TUTX"]).isDisjoint(with: osTypes)
        }
    }

    /// 自动推荐须明确声明通用编辑能力；仅编辑某种文本格式不足以入选。
    public static func declaresGeneralEditing(infoDictionary: [String: Any]) -> Bool {
        guard declaresEditing(infoDictionary: infoDictionary),
              let documents = infoDictionary["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        let genericTypes: Set<String> = [
            "public.text", "public.plain-text", "public.source-code", "public.utf8-plain-text",
            "public.utf16-plain-text", "public.utf16-external-plain-text", "com.apple.traditional-mac-plain-text",
        ]
        return documents.contains { document in
            guard document["CFBundleTypeRole"] as? String == "Editor" else { return false }
            let types = document["LSItemContentTypes"] as? [String] ?? []
            if !types.isEmpty {
                // 使用明确声明，不能把 CSV、Markdown 等文本子类型当作通用文本编辑能力。
                return !genericTypes.isDisjoint(with: types)
            }
            let extensions = document["CFBundleTypeExtensions"] as? [String] ?? []
            if extensions.contains(where: { ["txt", "text", "*"].contains($0.lowercased()) }) { return true }
            let osTypes = document["CFBundleTypeOSTypes"] as? [String] ?? []
            return !Set(["TEXT", "utxt", "TUTX"]).isDisjoint(with: osTypes)
        }
    }

    public static func editor(at url: URL) -> KnownEditor? {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, !id.isEmpty,
              let info = bundle.infoDictionary,
              info["CFBundlePackageType"] as? String == "APPL",
              declaresEditing(infoDictionary: info),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return KnownEditor(id: id, name: name)
    }

    public static func editor(bundleIdentifier: String) -> KnownEditor? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return editor(at: url)
    }

    public static func installed(applicationURLs: [URL], including selectedIds: Set<String> = [], order: [String] = []) -> [KnownEditor] {
        var seen = Set<String>()
        let editors = applicationURLs.compactMap { url -> KnownEditor? in
            guard let editor = editor(at: url),
                  selectedIds.contains(editor.id) || declaresGeneralEditing(infoDictionary: Bundle(url: url)?.infoDictionary ?? [:]),
                  seen.insert(editor.id).inserted else { return nil }
            return editor
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ordered(editors, by: order)
    }

    public static func installed(custom: [KnownEditor], preferred: String? = nil, order: [String] = []) -> [KnownEditor] {
        let types = [.text, .plainText, .sourceCode] + discoveryExtensions.compactMap { UTType(filenameExtension: $0) }
        let home = IPCBridge.realUserHomeDirectory.path
        var urls = types.flatMap { NSWorkspace.shared.urlsForApplications(toOpen: $0) }.filter {
            EditorDiscovery.isStandardInstallLocation($0.path, home: home)
        }
        let ids = Set(custom.map(\.id)).union([defaultEditorBundleIdentifier(), textEditBundleId] + [preferred].compactMap { $0 })
        urls += ids.sorted().compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        return installed(applicationURLs: urls, including: ids, order: order)
    }

    public static func ordered(_ editors: [KnownEditor], by savedOrder: [String]) -> [KnownEditor] {
        var remaining = editors
        var result: [KnownEditor] = []
        for id in savedOrder {
            guard let index = remaining.firstIndex(where: { $0.id == id }) else { continue }
            result.append(remaining.remove(at: index))
        }
        return result + remaining
    }

    public static func menuEditors(available: [KnownEditor], hidden: Set<String>, order: [String] = []) -> [KnownEditor] {
        ordered(available.filter { !hidden.contains($0.id) }, by: order)
    }

    /// 默认跟随系统纯文本编辑器，明确选择与系统关联都须通过同一能力校验。
    public static func resolvedDefault(
        preferred: String?, systemDefault: @autoclosure () -> String = defaultEditorBundleIdentifier(),
        isInstalled: (String) -> Bool = { editor(bundleIdentifier: $0) != nil }
    ) -> String {
        if let preferred, !preferred.isEmpty, isInstalled(preferred) { return preferred }
        let system = systemDefault()
        return isInstalled(system) ? system : textEditBundleId
    }

    public static func defaultEditorBundleIdentifier() -> String {
        guard let url = NSWorkspace.shared.urlForApplication(toOpen: UTType.plainText),
              let editor = editor(at: url) else { return textEditBundleId }
        return editor.id
    }
}

/// 自动发现只列出常规安装位置的应用；手动选择仍须通过 EditorCatalog 的能力校验。
public enum EditorDiscovery {
    /// 只推荐常规安装位置的应用：浏览器测试副本、挂载中的 DMG、App 内嵌 Helper 等不算
    public static func isStandardInstallLocation(_ appPath: String, home: String) -> Bool {
        let roots = ["/Applications/", "/System/Applications/", home + "/Applications/"]
        guard roots.contains(where: appPath.hasPrefix) else { return false }
        // 排除 App 包内嵌的子应用（如 Doubao.app/Contents/Helpers/Doubao Browser.app）
        return !appPath.dropLast(4).contains(".app/")
    }

    /// 读取 bundle 资源（如图标）时的来源：LaunchServices 可能把 bundle id 解析到构建产物
    /// 等非常规路径，沙箱扩展读不到那里的 icns，只能拿到系统默认的空白应用图标。
    public static func preferredIconSourceURL(bundleIdentifier: String) -> URL? {
        preferredCopy(
            among: NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier),
            fallback: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
            home: IPCBridge.realUserHomeDirectory.path
        )
    }

    /// 从已注册副本中选常规安装位置的一个；没有常规副本时退回 LaunchServices 的解析结果。
    public static func preferredCopy(among candidates: [URL], fallback: URL?, home: String) -> URL? {
        candidates.first(where: { isStandardInstallLocation($0.path, home: home) }) ?? fallback
    }
}
