import SwiftUI
import AppKit
import FinderSync
import FinderRightKit

/// 访达扩展启用状态检测与引导
///
/// 右键菜单全部由 FinderRightSync 扩展提供：扩展未启用时，FinderRight 在访达里完全不可见。
struct FinderExtensionView: View {

    @FRState private var enabled: Bool = FinderExtensionChecker.check()

    var body: some View {
        PermissionBlock(
            title: "访达扩展",
            granted: enabled,
            grantedDetail: "已启用",
            deniedDetail: "未启用 — 访达右键菜单中不会出现 FinderRight",
            explanation: "FinderRight 的右键菜单由访达扩展提供，需要在系统设置中启用后才会出现。",
            openTitle: "打开扩展设置…",
            tip: "提示：启用后若右键仍没有菜单，可在「设置 → 通用」中点「重启访达」。",
            steps: [
                "1. 点击上方按钮，会跳转到系统设置的扩展管理",
                "2. 在列表中找到 FinderRight",
                "3. 打开 FinderRight 的访达扩展开关",
                "4. 回到此处，状态会自动刷新",
            ],
            onOpen: FinderExtensionChecker.openSettings,
            onRecheck: { enabled = FinderExtensionChecker.check() }
        )
        .onAppear {
            enabled = FinderExtensionChecker.check()
        }
        // 从系统设置启用后切回本 App 时自动刷新
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            enabled = FinderExtensionChecker.check()
        }
    }
}

/// 查询 / 管理本 App 内嵌的访达扩展。系统专为宿主 App 提供了这两个接口，
/// 比解析 `pluginkit -m` 输出更轻，可以在每次打开菜单栏菜单时同步调用。
enum FinderExtensionChecker {    static func check() -> Bool {
        if FIFinderSyncController.isExtensionEnabled { return true }

        // 兜底：macOS 13 上 `isExtensionEnabled` 会在扩展**确实已启用**时也返回 false
        // （VM macOS 13.3.1 实测：访达右键菜单可用、扩展进程在跑，但此接口恒为 false），
        // 于是设置页永远显示「未启用」。退回 PluginKit 查询，行首 '+' 表示启用、'-' 表示被忽略。
        let enabledByPluginKit = pluginKitSaysEnabled()
        NSLog("[FinderExtensionChecker] isExtensionEnabled=false, pluginkit 判定=\(enabledByPluginKit)")
        return enabledByPluginKit
    }

    /// 打开系统设置中管理访达扩展的位置（各系统版本入口不同，由系统负责定位）
    static func openSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    /// `pluginkit -m -i <本扩展 id>`：只列出本扩展，解析首字符状态位
    private static func pluginKitSaysEnabled() -> Bool {
        let syncBundleId: String = {
            if let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FinderRightSync.appex"),
               let id = Bundle(url: url)?.bundleIdentifier {
                return id
            }
            return "com.finderright.app.sync"
        }()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", syncBundleId]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            NSLog("[FinderExtensionChecker] pluginkit 启动失败: \(error.localizedDescription)")
            return false
        }
        // 先读空管道再 waitUntilExit：输出量超过管道缓冲时反序会死锁
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return false }
        return FinderSyncElection.parse(text).contains { $0.bundleId == syncBundleId && $0.state == "+" }
    }
}

/// 当前运行时的安装方式
enum AppRuntime {
    /// 是否运行在 App Translocation 的临时只读副本里。
    ///
    /// 带隔离标记（quarantine）的 app 从下载目录直接打开时，macOS 不会原地运行，而是只读挂载到
    /// `/private/var/folders/…/AppTranslocation/<uuid>/d/` 下再执行。此时系统登记的扩展路径与实际
    /// 运行的副本对不上：扩展状态可能误判为未启用、定向唤醒主 App 会被 LaunchServices 拒绝。
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }
}
