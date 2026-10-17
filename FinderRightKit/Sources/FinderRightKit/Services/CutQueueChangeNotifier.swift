import Foundation

/// 剪切队列变化的跨进程通知（Darwin notify，沙箱扩展也能接收）。
///
/// 剪切 / 粘贴既可能从扩展的右键菜单发起（扩展自己会立即更新角标），也可能经系统「服务」
/// 快捷键直接由主 App 处理——后者扩展毫不知情，角标就会缺失或残留。主 App 每次改写
/// cut-queue.json 后发一次通知，扩展收到后按落盘队列重新对齐角标。通知不携带数据，只是「去读盘」的信号。
public enum CutQueueChangeNotifier {

    public static let name = "com.finderright.cutQueueChanged"

    /// Darwin 回调是 C 函数指针，不能捕获上下文，回调闭包存在这里（只在扩展里注册一次）
    private static var handler: (() -> Void)?

    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    /// 注册监听；handler 在主线程执行。重复调用以最后一次为准。
    public static func observe(_ block: @escaping () -> Void) {
        let alreadyRegistered = handler != nil
        handler = block
        guard !alreadyRegistered else { return }
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { CutQueueChangeNotifier.handler?() }
            },
            name as CFString, nil, .deliverImmediately)
    }
}
