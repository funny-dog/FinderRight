import Foundation
import ServiceManagement

/// 开机自动启动服务管理器（基于 macOS 13+ SMAppService.mainApp）
public final class LaunchAtLoginManager {
    public static let shared = LaunchAtLoginManager()

    private init() {}

    /// 当前系统登录项注册状态
    public var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// 开机自启是否已启用（已启用或等待用户在系统设置批准）
    public var isEnabled: Bool {
        let currentStatus = SMAppService.mainApp.status
        return currentStatus == .enabled || currentStatus == .requiresApproval
    }

    /// 切换开机自启状态
    /// - Parameter enabled: true 为开启，false 为关闭
    public func setEnabled(_ enabled: Bool) throws {
        let currentStatus = SMAppService.mainApp.status
        NSLog("[LaunchAtLoginManager] setEnabled(\(enabled)), 当前系统状态: \(statusDescription(currentStatus)) (rawValue: \(currentStatus.rawValue))")

        if enabled {
            if currentStatus == .enabled {
                NSLog("[LaunchAtLoginManager] 当前已处于 enabled 状态，无需重复注册")
                return
            }
            do {
                try SMAppService.mainApp.register()
                NSLog("[LaunchAtLoginManager] SMAppService.mainApp.register() 成功，当前状态: \(statusDescription(SMAppService.mainApp.status))")
            } catch {
                NSLog("[LaunchAtLoginManager] 注册开机自启失败: \(error)")
                throw error
            }
        } else {
            if currentStatus == .notRegistered {
                NSLog("[LaunchAtLoginManager] 当前已处于 notRegistered 状态，无需重复注销")
                return
            }
            do {
                try SMAppService.mainApp.unregister()
                NSLog("[LaunchAtLoginManager] SMAppService.mainApp.unregister() 成功，当前状态: \(statusDescription(SMAppService.mainApp.status))")
            } catch {
                NSLog("[LaunchAtLoginManager] 注销开机自启失败: \(error)")
                throw error
            }
        }
    }

    /// 状态描述字符串，方便日志记录与调试
    public func statusDescription(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered:
            return "notRegistered"
        case .enabled:
            return "enabled"
        case .requiresApproval:
            return "requiresApproval"
        case .notFound:
            return "notFound"
        @unknown default:
            return "unknown(\(status.rawValue))"
        }
    }

    /// 打开系统设置中的「登录项」面板
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
