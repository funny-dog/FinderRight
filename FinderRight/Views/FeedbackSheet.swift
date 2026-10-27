import SwiftUI
import AppKit

/// 「关于」页的「反馈与建议」：先选反馈类型，提交时才跳转 GitHub。
///
/// 诊断信息在弹窗出现时取一次，预览、复制与预填链接都用这一份，用户看到的就是会发出去的。
struct FeedbackSheet: View {
    @Binding var isPresented: Bool

    private enum Kind {
        case bug
        case feature
    }

    @FRState private var kind: Kind = .bug
    @FRState private var sections: DiagnosticsReport.Sections?
    @FRState private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                FRIconChip(systemName: "exclamationmark.bubble", size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("反馈与建议")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(FRTheme.text)
                    Text("提交会在浏览器中打开 GitHub，需要登录 GitHub 账号")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.mute)
                }
            }

            HStack(spacing: 10) {
                option(.bug, symbol: "ladybug", title: "问题反馈", detail: "功能出错、崩溃或与预期不符")
                option(.feature, symbol: "lightbulb", title: "功能建议", detail: "希望新增或改进的功能")
            }

            if kind == .bug {
                diagnosticsPreview
            }

            HStack(spacing: 8) {
                // 不走 GitHub（邮件、群里）或补充到已有 issue 时手动复制
                Button {
                    guard let sections else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DiagnosticsReport.text(sections), forType: .string)
                    didCopy = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        didCopy = false
                    }
                } label: {
                    if didCopy {
                        Label("已复制诊断信息", systemImage: "checkmark")
                    } else {
                        Label("复制诊断信息", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.frLink)
                .help("复制版本、系统、权限与扩展状态，用于邮件、群聊或补充到已有 issue")

                Spacer()

                Button("取消") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.frSecondary)

                Button("前往 GitHub 提交") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.frPrimary)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(FRTheme.window)
        .onAppear {
            sections = DiagnosticsReport.sections()
        }
    }

    /// 只读预览：等宽、可选中，跳转后仍可在网页里删改
    private var diagnosticsPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("将自动填入以下诊断信息")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(FRTheme.text)

            ScrollView {
                Text(verbatim: sections.map(DiagnosticsReport.text) ?? "")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(FRTheme.mute)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(FRTheme.field))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(FRTheme.fieldBorder, lineWidth: 1)
            )

            Text("用户名已从路径中隐去；提交前可在网页中修改或删除")
                .font(.system(size: 11.5))
                .foregroundColor(FRTheme.mute)
        }
    }

    private func option(_ value: Kind, symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        let selected = kind == value
        return Button {
            kind = value
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(selected ? FRTheme.accentText : FRTheme.mute)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(FRTheme.text)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(FRTheme.mute)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? FRTheme.selection : FRTheme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(selected ? FRTheme.accent : FRTheme.border, lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func submit() {
        let url: URL
        switch kind {
        case .bug:
            url = DiagnosticsReport.bugReportURL(sections ?? DiagnosticsReport.sections())
        case .feature:
            url = DiagnosticsReport.featureRequestURL()
        }
        NSWorkspace.shared.open(url)
        isPresented = false
    }
}
