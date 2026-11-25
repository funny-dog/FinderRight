import SwiftUI
import AppKit
import FinderRightKit

final class GitStatusController: NSObject, NSWindowDelegate {
    static let shared = GitStatusController()
    private var window: NSWindow?
    private var model: GitStatusModel?
    var isPerforming: Bool { model?.isPerforming == true }

    func show(at url: URL? = nil, openedFromExternalApplication: Bool = true) {
        if window == nil {
            let model = GitStatusModel()
            let contentRect = NSRect(origin: .zero, size: GitStatusLayout.contentSize)
            let window = FRTransientPanel(
                contentRect: contentRect,
                minSize: GitStatusLayout.minimumContentSize,
                autosaveKey: "gitStatus")
            window.title = NSLocalizedString("Git 状态", comment: "")
            window.delegate = self
            window.contentView = NSHostingView(rootView: GitStatusView(model: model))
            self.model = model
            self.window = window
        }
        if let url {
            model?.open(at: url)
        } else if model?.sourceURL == nil {
            model?.scanRepositories()
        }
        if let window {
            TransientWindowManager.shared.present(
                window, openedFromExternalApplication: openedFromExternalApplication)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isPerforming { NSSound.beep(); return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        model?.cancel()
        model = nil
        window = nil
    }
}

struct GitActionFeedback: View {
    @ObservedObject var model: GitStatusModel

    var body: some View {
        if model.isPerforming {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在执行 Git…").font(.system(size: 12))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        } else if let error = model.actionError {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(verbatim: error).font(.system(size: 12)).foregroundColor(FRTheme.danger)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 72)
                if error.lowercased().contains("divergent branches")
                    || error.lowercased().contains("diverging branches")
                    || error.contains("变基拉取") {
                    Button("改用变基拉取") {
                        model.perform(.pull(rebase: true), success: NSLocalizedString("已拉取", comment: ""))
                    }
                    .buttonStyle(.frLink)
                    .font(.system(size: 12))
                    .disabled(model.isLoading || model.isPerforming)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        } else if let message = model.actionMessage {
            Text(verbatim: message).font(.system(size: 12)).foregroundColor(FRTheme.okText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}

struct GitCommitSheet: View {
    @ObservedObject var model: GitStatusModel
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提交暂存区").font(.system(size: 17, weight: .semibold))
            if let preview = model.commitPreview {
                Text(verbatim: String(format: NSLocalizedString("%d 个文件 · 整个仓库", comment: ""), preview.files.count))
                    .font(.system(size: 11.5)).foregroundColor(FRTheme.mute)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.files, id: \.self) { path in
                            Text(verbatim: path).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
                Text("提交说明").font(.system(size: 12, weight: .medium))
                FRTextFieldContainer(isFocused: messageFocused, height: nil) {
                    TextEditor(text: $model.commitMessage)
                        .font(.system(size: 12.5))
                        .scrollContentBackground(.hidden)
                        .focused($messageFocused)
                        .frame(height: 100)
                        .disabled(model.isPerforming)
                        .accessibilityLabel("提交说明")
                }
                GitActionFeedback(model: model)
                HStack {
                    Button("重新载入") { model.prepareCommit() }.buttonStyle(.frLink).disabled(model.isPerforming)
                    Spacer()
                    Button("取消") { model.dismissCommit() }.buttonStyle(.frSecondary)
                        .keyboardShortcut(.cancelAction).disabled(model.isPerforming)
                    Button("提交") {
                        model.perform(.commit(message: model.commitMessage, preview: preview), success: "提交完成")
                    }
                    .buttonStyle(.frPrimary).keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isPerforming || model.isLoading || model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(20).frame(width: 440)
        .foregroundColor(FRTheme.text).background(FRTheme.window)
        .interactiveDismissDisabled(model.isPerforming)
        .onAppear { DispatchQueue.main.async { messageFocused = true } }
    }
}
