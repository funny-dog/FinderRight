import AppKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "archive password") }

/// 加密压缩包的密码输入框。
///
/// 用非激活面板（`.nonactivatingPanel`）而不是 NSAlert：NSAlert 需要先 `NSApp.activate`，而激活 App 会把它
/// 已打开的主窗口（如开着的设置窗口）一并带到访达前面；非激活面板自己就能成为 key window 接收键盘输入，
/// App 不被激活、访达始终在前台，关闭后焦点自然回到访达。
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
            PasswordPanel.show(archiveName: archiveName, retrying: retrying) { result in
                password = result
                done.signal()
            }
        }
        done.wait()
        return password
    }
}

/// 面板本身。只在主线程使用；显示期间由 `current` 持有，结束时释放
private final class PasswordPanel: NSObject {

    private static var current: PasswordPanel?

    private let panel: NSPanel
    private let field = NSSecureTextField()
    private let completion: (String?) -> Void

    static func show(archiveName: String, retrying: Bool, completion: @escaping (String?) -> Void) {
        let controller = PasswordPanel(archiveName: archiveName, retrying: retrying, completion: completion)
        current = controller
        controller.panel.center()
        controller.panel.makeKeyAndOrderFront(nil)
        controller.panel.makeFirstResponder(controller.field)
    }

    private init(archiveName: String, retrying: Bool, completion: @escaping (String?) -> Void) {
        self.completion = completion
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 150),
                        styleMask: [.titled, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.title = "FinderRight"
        // 浮在访达窗口之上；App 从不处于激活状态，不能随「失去激活」隐藏；全屏访达所在空间也要能显示
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let title = NSTextField(labelWithString: String(format: L("「%@」已加密"), archiveName))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        let message = NSTextField(labelWithString: retrying ? L("密码错误，请重新输入。") : L("请输入解压密码。"))
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.textColor = retrying ? .systemRed : .secondaryLabelColor

        let cancel = NSButton(title: L("取消"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let extract = NSButton(title: L("解压"), target: self, action: #selector(extractClicked))
        extract.keyEquivalent = "\r"
        // 按钮放进右侧 gravity 区，按钮行与输入框同宽时即靠右
        let buttons = NSStackView()
        buttons.spacing = 12
        buttons.addView(cancel, in: .trailing)
        buttons.addView(extract, in: .trailing)

        let column = NSStackView(views: [title, message, field, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.setCustomSpacing(14, after: field)
        // 整列固定宽度：长文件名在标题里从中间截断，而不是把面板撑宽
        let columnWidth: CGFloat = 320
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [title, message, field, buttons] {
            view.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
        }

        // 不用横向 NSStackView 包图标与内容列：顶部对齐时它与底边只有「不小于」约束，按最小尺寸收缩时
        // 底部边距会被压没（按钮贴底）。这里把四周边距都钉死
        let content = NSView()
        let margin: CGFloat = 20
        for view in [icon, column] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: margin),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            icon.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -margin),
            column.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -margin),
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: margin),
            column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -margin),
        ])
        panel.contentView = content
        panel.setContentSize(content.fittingSize)
        panel.initialFirstResponder = field
    }

    @objc private func extractClicked() {
        finish(field.stringValue)
    }

    @objc private func cancelClicked() {
        finish(nil)
    }

    private func finish(_ result: String?) {
        panel.orderOut(nil)
        Self.current = nil
        completion(result)
    }
}
