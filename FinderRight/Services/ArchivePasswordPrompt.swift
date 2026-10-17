import AppKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "archive password") }

/// 加密压缩包的密码输入框。
///
/// 用 FRDialog 的非激活面板：App 不被激活、访达始终在前台，关闭后焦点自然回到访达。
///
/// 只能在后台线程（归档队列）调用：面板在主线程显示，调用方阻塞等待用户输入，归档队列在此期间排队等候。
enum ArchivePasswordPrompt {

    /// - Parameter retrying: 上一次密码错误（或为空）时为 true，面板改为提示重新输入
    /// - Returns: 用户输入的密码；点「取消」或按 Esc 返回 nil
    static func ask(archiveName: String, retrying: Bool) -> String? {
        precondition(!Thread.isMainThread, "在主线程等待面板结果会死锁")
        var password: String?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let dialog = FRDialog(
                title: String(format: L("「%@」已加密"), archiveName),
                message: L("请输入解压密码。"),
                symbol: "lock",
                buttons: [L("解压"), L("取消")],
                input: .secure(placeholder: L("密码")))
            if retrying { dialog.showError(L("密码错误，请重新输入。")) }
            dialog.show { index in
                if index == 0 { password = dialog.text }
                done.signal()
            }
        }
        done.wait()
        return password
    }
}
