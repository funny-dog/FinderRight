import Foundation

/// IPC action 的路径访问要求。只有必须打开系统位置的功能可以豁免白名单；
/// 返回文件内容、哈希或统计信息的 action 仍按源路径校验。
public enum IPCPathPolicy {
    private static let whitelistExemptActions: Set<String> = [
        "openTerminal", "openWithApp", "ping", "toggleHiddenFiles",
        BadgeReclaimIPC.action, "showCutQueueDetail"
    ]

    public static func requiresWhitelist(action: String) -> Bool {
        !whitelistExemptActions.contains(action)
    }

    public static func role(action: String, key: String) -> PathAccessPolicy.Role? {
        switch key {
        case "directory":
            if action == "prefetchDiskUsage" || action == "copyDirectoryTree" || action == "runCustomCommand" {
                return .source
            }
            return .destination
        case "destination": return .destination
        case "archive", "testPath", "path", "items", "paths": return .source
        default: return nil
        }
    }
}
