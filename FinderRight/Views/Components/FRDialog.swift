import SwiftUI
import AppKit

/// 统一样式的弹窗：小号彩色图标 + 标题、说明文字、可选输入区、靠右的按钮行（主按钮在最右）。
///
/// 用非激活面板（`.nonactivatingPanel`）而不是 NSAlert：NSAlert 需要先 `NSApp.activate`，激活 App 会把
/// 已打开的设置窗口一并带到访达前面；非激活面板自己就能成为 key window，`runModal` 期间其他窗口层级不变。
///
/// `buttons[0]` 是主按钮（回车），`cancelIndex` 对应 Esc；`runModal` 返回按下的按钮下标，Esc 返回 `cancelIndex`。
/// 只在主线程使用。
final class FRDialog: NSObject, NSWindowDelegate {

    enum Tone {
        case normal
        /// 有风险或失败：橙色警告图标
        case warning
    }

    /// 输入框下方的实时提示，如「文件 · 位于 ~/Downloads」
    struct Hint: Equatable {
        let symbol: String
        let text: String
        let ok: Bool
    }

    enum Input {
        case none
        case text(initial: String, placeholder: String, accessibilityLabel: String, hint: ((String) -> Hint?)? = nil)
        case secure(placeholder: String)
        case choice([String], accessibilityLabel: String)
    }

    /// 点按钮时的校验：返回错误文字则弹窗不关闭、以红字显示错误；返回 nil 正常关闭。
    /// 只做检查、不执行操作（操作放在 runModal 返回之后）
    var validate: ((Int) -> String?)?

    /// Esc 对应的按钮下标；默认是最后一个按钮（多于一个时）
    var cancelIndex: Int? {
        get { model.cancelIndex }
        set { model.cancelIndex = newValue }
    }

    var message: String {
        get { model.message }
        set { model.message = newValue; model.isError = false }
    }

    /// 以红字显示说明（如「密码错误」）
    func showError(_ text: String) {
        model.message = text
        model.isError = true
    }

    var text: String { model.text }
    var selectedIndex: Int { model.selected }

    private let model: FRDialogModel
    private let panel: FRDialogPanel
    private var completion: ((Int?) -> Void)?
    private weak var sheetParent: NSWindow?
    private var isModal = false
    /// 非模态显示期间持有自己，结束时释放
    private static var presented: Set<FRDialog> = []

    init(title: String, message: String = "", symbol: String, tone: Tone = .normal,
         buttons: [String], input: Input = .none) {
        model = FRDialogModel(title: title, message: message, symbol: symbol, tone: tone, buttons: buttons, input: input)
        panel = FRDialogPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        // 浮在访达窗口之上；App 常不处于激活状态，不能随「失去激活」隐藏；全屏访达所在空间也要能显示
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        let hosting = NSHostingView(rootView: FRDialogView(model: model))
        panel.contentView = hosting
        model.onPress = { [weak self] index in self?.press(index) }
        // 单按钮的提示框没有取消按钮，Esc 等同按下它
        panel.onCancel = { [weak self] in
            guard let self else { return }
            self.finish(self.model.cancelIndex ?? (self.model.buttons.count == 1 ? 0 : nil))
        }
        // 错误提示、实时识别会改变高度：保持顶边不动，向下伸缩
        model.onLayoutChange = { [weak self, weak hosting] in
            DispatchQueue.main.async {
                guard let self, let hosting else { return }
                self.fitContent(hosting)
            }
        }
        fitContent(hosting)
    }

    /// 已在显示时再次触发：只把它提到前面
    func bringToFront() {
        panel.makeKeyAndOrderFront(nil)
    }

    /// 模态显示，返回按下的按钮下标（Esc 为 `cancelIndex`）
    @discardableResult
    func runModal() -> Int? {
        var result: Int?
        completion = { result = $0 }
        isModal = true
        present()
        NSApp.runModal(for: panel)
        return result
    }

    /// 作为窗口的 sheet 显示（设置窗口内的确认框）
    func beginSheet(for window: NSWindow, completion: @escaping (Int?) -> Void) {
        self.completion = completion
        sheetParent = window
        Self.presented.insert(self)
        panel.level = .normal
        window.beginSheet(panel)
    }

    /// 非模态显示：调用方在后台线程等待结果时使用（如解压密码），不占用主线程的模态循环
    func show(completion: @escaping (Int?) -> Void) {
        self.completion = completion
        Self.presented.insert(self)
        present()
    }

    /// 非激活面板通常直接成为 key；系统的防抢焦点机制拦下时（面板显示了但键盘输入不进来），
    /// 退回激活 App 再取焦点：可能把设置窗口一并带到前面，但总好过弹窗对按键没有反应
    private func present() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        let retry = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            guard let self, self.completion != nil, !self.panel.isKeyWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        }
        RunLoop.main.add(retry, forMode: .common)
    }

    private func press(_ index: Int) {
        // 回车可能同时触发主按钮快捷键与输入框提交，已结束的弹窗不再响应
        guard completion != nil else { return }
        if let error = validate?(index) {
            model.message = error
            model.isError = true
            return
        }
        finish(index)
    }

    private func finish(_ index: Int?) {
        guard let completion else { return }
        self.completion = nil
        if let sheetParent {
            sheetParent.endSheet(panel)
        } else {
            panel.orderOut(nil)
        }
        if isModal { NSApp.stopModal() }
        completion(index)
        Self.presented.remove(self)
    }

    private func fitContent(_ hosting: NSView) {
        let size = hosting.fittingSize
        var frame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: panel.frame.minX, y: panel.frame.maxY - frame.height)
        panel.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        finish(model.cancelIndex)
    }
}

/// Esc 在窗口里走 cancelOperation；输入框获得焦点时 Esc 由取消按钮的快捷键先处理
private final class FRDialogPanel: NSPanel {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

// MARK: - 视图

final class FRDialogModel: ObservableObject {
    let title: String
    let symbol: String
    let tone: FRDialog.Tone
    let buttons: [String]
    let input: FRDialog.Input
    var cancelIndex: Int?

    @Published var message: String { didSet { onLayoutChange?() } }
    @Published var isError = false
    @Published var text: String { didSet { updateHint() } }
    @Published var selected = 0
    @Published private(set) var hint: FRDialog.Hint? { didSet { if hint != oldValue { onLayoutChange?() } } }

    var onPress: ((Int) -> Void)?
    var onLayoutChange: (() -> Void)?

    init(title: String, message: String, symbol: String, tone: FRDialog.Tone, buttons: [String], input: FRDialog.Input) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.tone = tone
        self.buttons = buttons
        self.input = input
        cancelIndex = buttons.count > 1 ? buttons.count - 1 : nil
        if case .text(let initial, _, _, _) = input {
            text = initial
        } else {
            text = ""
        }
        updateHint()
    }

    private func updateHint() {
        guard case .text(_, _, _, let provider?) = input else { return }
        hint = provider(text)
    }
}

private struct FRDialogView: View {
    @ObservedObject var model: FRDialogModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(model.tone == .warning ? FRTheme.warnText : FRTheme.accentText)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(model.tone == .warning ? FRTheme.warnBackground : FRTheme.selection))
                    .accessibilityHidden(true)
                Text(model.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // 标明弹窗来源：从访达触发时用户看不到 FinderRight 的其他界面
                HStack(spacing: 4) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 14, height: 14)
                    Text("FinderRight")
                        .font(.system(size: 11))
                        .foregroundStyle(FRTheme.mute)
                }
                .accessibilityElement(children: .combine)
            }

            if !model.message.isEmpty {
                Text(model.message)
                    .font(.system(size: 12))
                    .foregroundStyle(model.isError ? FRTheme.danger : FRTheme.mute)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }

            inputView

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                // 主按钮在最右：按 buttons 倒序排列
                ForEach(Array(model.buttons.indices.reversed()), id: \.self) { index in
                    button(index)
                }
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .frame(width: 440, alignment: .leading)
        .onAppear {
            // 等面板成为 key 后再聚焦输入框
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    @ViewBuilder
    private func button(_ index: Int) -> some View {
        let base = Button(model.buttons[index]) { model.onPress?(index) }
            .controlSize(.regular)
        if index == 0 {
            // 非激活面板里系统默认按钮不一定显示蓝色，主按钮显式高亮
            base.buttonStyle(.borderedProminent)
                .tint(FRTheme.accent)
                .keyboardShortcut(.defaultAction)
        } else if index == model.cancelIndex {
            base.keyboardShortcut(.cancelAction)
        } else {
            base
        }
    }

    @ViewBuilder
    private var inputView: some View {
        switch model.input {
        case .none:
            EmptyView()
        case .text(_, let placeholder, let label, _):
            VStack(alignment: .leading, spacing: 6) {
                field(symbol: "folder") {
                    TextField("", text: $model.text, prompt: Text(placeholder))
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { model.onPress?(0) }
                        .accessibilityLabel(label)
                }
                if let hint = model.hint {
                    HStack(spacing: 5) {
                        Image(systemName: hint.symbol).accessibilityHidden(true)
                        Text(hint.text).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(hint.ok ? FRTheme.okText : FRTheme.mute)
                    .padding(.horizontal, 2)
                }
            }
            .padding(.top, 12)
        case .secure(let placeholder):
            field(symbol: "key") {
                SecureField("", text: $model.text, prompt: Text(placeholder))
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit { model.onPress?(0) }
            }
            .padding(.top, 12)
        case .choice(let choices, let label):
            Picker("", selection: $model.selected) {
                ForEach(choices.indices, id: \.self) { index in
                    Text(choices[index]).tag(index)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(label)
            .padding(.top, 12)
        }
    }

    private func field<Content: View>(symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(FRTheme.mute)
                .accessibilityHidden(true)
            content()
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(FRTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(fieldFocused ? FRTheme.accent : FRTheme.fieldBorder, lineWidth: fieldFocused ? 1.5 : 1))
    }
}
