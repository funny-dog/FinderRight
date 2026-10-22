import Foundation
import AppKit
import UniformTypeIdentifiers

/// 一个通过 Shell 文档角色识别的终端应用。
public struct KnownTerminal: Identifiable, Equatable {
    /// 唯一标识（bundle id）
    public let id: String
    /// 显示名
    public let name: String
    /// bundle identifier
    public let bundleIdentifier: String
    /// SF Symbol 图标名
    public let icon: String

    public init(id: String, name: String, bundleIdentifier: String, icon: String = "terminal.fill") {
        self.id = id
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.icon = icon
    }
}

/// 设置、菜单与执行入口共用的终端识别规则，不维护品牌白名单。
public enum TerminalCatalog {
    private static let shellContentTypes: Set<String> = [
        "com.apple.terminal.shell-script", "public.shell-script", "public.unix-executable",
    ]

    public static func declaresShell(infoDictionary: [String: Any]) -> Bool {
        guard let documents = infoDictionary["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        return documents.contains { document in
            guard document["CFBundleTypeRole"] as? String == "Shell" else { return false }
            let types = document["LSItemContentTypes"] as? [String] ?? []
            return !shellContentTypes.isDisjoint(with: types)
        }
    }

    public static func terminal(at url: URL) -> KnownTerminal? {
        guard url.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, !id.isEmpty,
              let info = bundle.infoDictionary,
              info["CFBundlePackageType"] as? String == "APPL",
              declaresShell(infoDictionary: info),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let name = bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? info["CFBundleDisplayName"] as? String
            ?? info["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return KnownTerminal(id: id, name: name, bundleIdentifier: id,
                             icon: id == "com.apple.Terminal" ? "terminal" : "terminal.fill")
    }

    public static func terminal(bundleIdentifier: String) -> KnownTerminal? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return terminal(at: url)
    }

    public static func installed(applicationURLs: [URL]) -> [KnownTerminal] {
        var seen = Set<String>()
        return applicationURLs.compactMap { url in
            guard let terminal = terminal(at: url), seen.insert(terminal.bundleIdentifier).inserted else { return nil }
            return terminal
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// LaunchServices 只用于发现候选；每个候选仍须显式声明 Shell 角色。
    public static func installed(additionalBundleIdentifiers: Set<String> = []) -> [KnownTerminal] {
        var urls = shellContentTypes.sorted().compactMap { UTType($0) }.flatMap {
            NSWorkspace.shared.urlsForApplications(toOpen: $0)
        }
        for id in additionalBundleIdentifiers.union([defaultTerminalBundleIdentifier(), "com.apple.Terminal"]).sorted() {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { urls.append(url) }
        }
        return installed(applicationURLs: urls)
    }

    public static func ordered(_ terminals: [KnownTerminal], by savedOrder: [String]) -> [KnownTerminal] {
        var remaining = terminals
        var result: [KnownTerminal] = []
        for id in savedOrder {
            guard let index = remaining.firstIndex(where: { $0.bundleIdentifier == id }) else { continue }
            result.append(remaining.remove(at: index))
        }
        return result + remaining
    }

    /// 只显示已选择且仍安装的终端；选择失效时回退到默认终端或系统终端。
    public static func menuTerminals(
        available: [KnownTerminal], selected: Set<String>, preferred: String, order: [String] = []
    ) -> [KnownTerminal] {
        guard !selected.isEmpty else { return [] }
        let visible = available.filter { selected.contains($0.bundleIdentifier) }
        if !visible.isEmpty { return ordered(visible, by: order) }
        if let fallback = available.first(where: { $0.bundleIdentifier == preferred })
            ?? available.first(where: { $0.bundleIdentifier == "com.apple.Terminal" })
            ?? available.first {
            return [fallback]
        }
        return []
    }

    /// 右键时只检查所选项与回退项，不枚举系统里的全部应用。
    public static func menuTerminals(selected: Set<String>, preferred: String, order: [String] = []) -> [KnownTerminal] {
        guard !selected.isEmpty else { return [] }
        let defaultId = defaultTerminalBundleIdentifier()
        let ids = selected.union([preferred, defaultId, "com.apple.Terminal"])
        let available = ids.sorted().compactMap { terminal(bundleIdentifier: $0) }
        let resolvedPreferred = available.contains { $0.bundleIdentifier == preferred } ? preferred : defaultId
        return menuTerminals(available: available, selected: selected, preferred: resolvedPreferred, order: order)
    }

    public static func resolvedDefault(preferred: String) -> String {
        terminal(bundleIdentifier: preferred)?.bundleIdentifier ?? defaultTerminalBundleIdentifier()
    }

    /// 检测系统当前默认的终端 Bundle Identifier
    public static func defaultTerminalBundleIdentifier() -> String {
        if let uti = UTType("com.apple.terminal.shell-script"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: uti),
           let terminal = terminal(at: appURL) {
            return terminal.bundleIdentifier
        }
        return "com.apple.Terminal"
    }
}
