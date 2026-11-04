import AppKit

enum ApplicationTermination {
    static func request() {
        // 先离开当前主队列回调，避免 terminateLater 的嵌套循环阻止主队列收尾。
        RunLoop.main.perform(inModes: [.common]) {
            NSApp.terminate(nil)
        }
    }
}
