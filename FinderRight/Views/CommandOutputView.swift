import SwiftUI
import AppKit
import FinderRightKit

final class CommandExecution: ObservableObject {
    @Published var output = ""
    @Published var isRunning = true
    @Published var isStopping = false
    @Published var truncated = false
    @Published var status: Int32?
    @Published var error: String?
    @Published var cancelled = false
    let runner = DeveloperCommandRunner()

    func stop() {
        guard isRunning else { return }
        isStopping = true
        runner.cancel()
    }
}

struct CommandOutputView: View {
    @ObservedObject var execution: CommandExecution
    let directory: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: directory.path)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(FRTheme.mute)
                .textSelection(.enabled)
            ScrollView([.horizontal, .vertical]) {
                Text(verbatim: execution.output.isEmpty ? " " : execution.output)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(FRTheme.field)
            .cornerRadius(8)
            if execution.truncated {
                Text("仅显示最后 128 KiB 输出")
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
            }
            HStack(spacing: 10) {
                if execution.isRunning {
                    ProgressView().controlSize(.small)
                    Text(execution.isStopping ? "正在停止…" : "正在运行…")
                } else if let error = execution.error {
                    Text(verbatim: error).foregroundColor(FRTheme.danger)
                } else if execution.cancelled {
                    Text("已停止")
                } else if let status = execution.status {
                    Text(String(format: NSLocalizedString("退出码：%d", comment: ""), status))
                        .foregroundColor(status == 0 ? FRTheme.okText : FRTheme.danger)
                }
                Spacer()
                Button("复制输出") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(execution.output, forType: .string) { ClipboardToast.showCopied() }
                }
                .buttonStyle(.frSecondary)
                .disabled(execution.output.isEmpty)
                if execution.isRunning {
                    Button("停止") { execution.stop() }
                        .buttonStyle(.frSecondary)
                        .disabled(execution.isStopping)
                }
            }
            .font(.system(size: 12))
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 300)
        .foregroundColor(FRTheme.text)
        .background(FRTheme.window)
    }
}

/// 结果窗口持有任务，关闭窗口时停止执行。
final class CustomCommandController: NSObject, NSWindowDelegate {
    static let shared = CustomCommandController()
    private var windows: [UUID: (window: NSWindow, execution: CommandExecution)] = [:]

    func run(_ command: DeveloperCommand, items: [URL], directory: URL) {
        SharedConfig.shared.reload()
        guard SharedConfig.shared.developerCommand(id: command.id) == command else {
            ClipboardToast.show(message: NSLocalizedString("命令不存在或已关闭", comment: ""), style: .failure)
            return
        }
        let execution = CommandExecution()
        guard FinderRightService.runGuarded(on: .global(qos: .userInitiated), work: {
            do {
                let result = try execution.runner.run(script: command.script, items: items, directory: directory) { output, truncated in
                    DispatchQueue.main.async {
                        execution.output = output
                        execution.truncated = truncated
                    }
                }
                DispatchQueue.main.async {
                    execution.output = result.output
                    execution.truncated = result.truncated
                    execution.status = result.status
                    execution.cancelled = result.cancelled
                    execution.isRunning = false
                }
            } catch {
                DispatchQueue.main.async {
                    execution.error = error.localizedDescription
                    execution.isRunning = false
                }
            }
        }) else { FinderRightService.reportExitInProgress(); return }

        let window = FRTransientPanel(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 450),
            minSize: CGSize(width: 540, height: 340))
        window.title = command.name
        window.delegate = self
        window.contentView = NSHostingView(rootView: CommandOutputView(execution: execution, directory: directory))
        windows[UUID()] = (window, execution)
        window.center()
        TransientWindowManager.shared.present(window)
    }

    func cancelAll() {
        for entry in windows.values { entry.execution.stop() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value.window === window })?.key else { return }
        windows[id]?.execution.stop()
        windows.removeValue(forKey: id)
    }
}
