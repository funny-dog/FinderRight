import Foundation
import AppKit
import UniformTypeIdentifiers

/// 一个已知的终端应用。
public struct KnownTerminal: Identifiable, Equatable {
    /// 唯一标识（例如 "ghostty" 或 bundle id）
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

/// 已知终端清单 —— 设置与终端调用的单一事实来源。
public enum TerminalCatalog {
    public static let all: [KnownTerminal] = [
        KnownTerminal(id: "terminal",  name: "终端",      bundleIdentifier: "com.apple.Terminal", icon: "terminal"),
        KnownTerminal(id: "ghostty",   name: "Ghostty",   bundleIdentifier: "com.mitchellh.ghostty", icon: "terminal.fill"),
        KnownTerminal(id: "iterm",      name: "iTerm2",    bundleIdentifier: "com.googlecode.iterm2", icon: "terminal.fill"),
        KnownTerminal(id: "warp",       name: "Warp",      bundleIdentifier: "dev.warp.Warp-Stable", icon: "terminal.fill"),
        KnownTerminal(id: "wezterm",    name: "WezTerm",   bundleIdentifier: "com.github.wez.wezterm", icon: "terminal.fill"),
        KnownTerminal(id: "alacritty",  name: "Alacritty", bundleIdentifier: "org.alacritty", icon: "terminal.fill"),
        KnownTerminal(id: "kitty",      name: "Kitty",     bundleIdentifier: "net.kovidgoyal.kitty", icon: "terminal.fill"),
    ]

    /// 检测系统当前默认的终端 Bundle Identifier
    public static func defaultTerminalBundleIdentifier() -> String {
        // macOS 12+，通过 UTType("com.apple.terminal.shell-script") 获取默认关联应用
        if #available(macOS 12.0, *),
           let uti = UTType("com.apple.terminal.shell-script"),
           let appURL = NSWorkspace.shared.urlForApplication(toOpen: uti),
           let bundleId = Bundle(url: appURL)?.bundleIdentifier {
            return bundleId
        }
        return "com.apple.Terminal"
    }
}
