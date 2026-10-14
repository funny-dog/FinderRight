import AppKit

// 在有桌面会话的 Mac 上，将此文件与 ClipboardToast.swift 一起用 swiftc 编译运行。
@main
struct ClipboardToastCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard !NSScreen.screens.isEmpty else {
            print("SKIP: 当前进程无法访问屏幕，提示生命周期检查需要 macOS 桌面会话")
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let changeCount = NSPasteboard.general.changeCount

        func wait(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        ClipboardToast.showCopied()
        wait(0.1)
        guard let panel = app.windows.first(where: { $0 is NSPanel }) else {
            fatalError("未创建提示窗口，需要 macOS 桌面会话")
        }
        assert(panel.isVisible && !panel.isKeyWindow)
        assert(panel.ignoresMouseEvents)
        assert(panel.styleMask.contains(.nonactivatingPanel))
        assert(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost)
        assert(NSPasteboard.general.changeCount == changeCount)

        wait(0.7)
        ClipboardToast.showCopied()
        wait(0.7)
        assert(panel.isVisible, "第二次复制必须重置消失时间")
        assert(app.windows.filter { $0 is NSPanel }.count == 1, "连续复制不应叠加窗口")
        wait(0.7)
        assert(!panel.isVisible, "提示应自动消失")
        print("PASS: 提示显示、无焦点干扰、剪贴板未改变、连续复制重新计时、自动消失")
    }
}
