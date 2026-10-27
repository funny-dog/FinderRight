import AppKit

// MARK: - 重启访达

enum FinderRelauncher {
    /// killall 后由系统自动拉起访达（会关闭所有访达窗口）
    static func relaunch() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        proc.arguments = ["Finder"]
        try? proc.run()
    }
}
