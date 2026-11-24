import SwiftUI
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "batch rename") }

final class BatchRenameModel: ObservableObject {
    enum Mode: Int, CaseIterable {
        case replace, affix, sequence, date
        var title: String {
            switch self {
            case .replace: return L("查找替换")
            case .affix: return L("前后缀")
            case .sequence: return L("序号")
            case .date: return L("日期")
            }
        }
    }

    @Published var items: [URL] = []
    @Published var mode = Mode.replace
    @Published var find = ""
    @Published var replacement = ""
    @Published var isRegex = false
    @Published var prefix = ""
    @Published var suffix = ""
    @Published var sequenceText = ""
    @Published var start = 1
    @Published var digits = 2
    @Published var dateFormat = "yyyy-MM-dd"
    @Published var dateAtStart = true
    @Published var isApplying = false

    var rule: BatchRenameRule {
        switch mode {
        case .replace: return .replace(find: find, with: replacement, regex: isRegex)
        case .affix: return .affix(prefix: prefix, suffix: suffix)
        case .sequence: return .sequence(text: sequenceText, start: start, digits: digits)
        case .date: return .date(format: dateFormat, atStart: dateAtStart)
        }
    }

    var entries: [BatchRenameEntry] { BatchRename.plan(items: items, rule: rule) }
}

struct BatchRenameView: View {
    @ObservedObject var model: BatchRenameModel
    let onApply: ([BatchRenameEntry]) -> Void
    let onCancel: () -> Void

    var body: some View {
        let entries = model.entries
        let changed = entries.filter(\.isChanged)
        let blocked = changed.contains { $0.problem != nil }
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.mode) {
                ForEach(BatchRenameModel.Mode.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            ruleFields

            if model.rule.isInvalid {
                Text(L("正则表达式不合法")).font(.system(size: 12)).foregroundColor(FRTheme.danger)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(entries.indices, id: \.self) { row(entries[$0]) }
                }
                .padding(8)
            }
            .background(FRTheme.card)
            .cornerRadius(8)

            HStack {
                Text(verbatim: blocked ? L("有名称冲突或不合法，请调整规则")
                     : String(format: L("将重命名 %d 项"), changed.count))
                    .font(.system(size: 12))
                    .foregroundColor(blocked ? FRTheme.danger : FRTheme.mute)
                Spacer()
                Button(L("取消"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("重命名")) { onApply(entries) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocked || changed.isEmpty || model.isApplying)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .foregroundColor(FRTheme.text)
        .background(FRTheme.window)
    }

    @ViewBuilder private var ruleFields: some View {
        switch model.mode {
        case .replace:
            HStack {
                TextField(L("查找"), text: $model.find)
                TextField(L("替换为"), text: $model.replacement)
                Toggle(L("正则"), isOn: $model.isRegex).toggleStyle(.checkbox)
            }
        case .affix:
            HStack {
                TextField(L("前缀"), text: $model.prefix)
                TextField(L("后缀（扩展名之前）"), text: $model.suffix)
            }
        case .sequence:
            HStack {
                TextField(L("名称文本"), text: $model.sequenceText)
                Stepper(String(format: L("起始 %d"), model.start), value: $model.start, in: 0...999_999)
                Stepper(String(format: L("位数 %d"), model.digits), value: $model.digits, in: 1...8)
            }
        case .date:
            HStack {
                TextField(L("日期格式"), text: $model.dateFormat)
                Picker("", selection: $model.dateAtStart) {
                    Text(L("加在开头")).tag(true)
                    Text(L("加在结尾")).tag(false)
                }
                .labelsHidden().frame(width: 110)
            }
        }
    }

    private func row(_ entry: BatchRenameEntry) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: entry.source.lastPathComponent).foregroundColor(FRTheme.mute).lineLimit(1)
            if entry.isChanged {
                Image(systemName: "arrow.right").font(.system(size: 10)).foregroundColor(FRTheme.mute)
                Text(verbatim: entry.newName)
                    .foregroundColor(entry.problem == nil ? FRTheme.text : FRTheme.danger).lineLimit(1)
                if let problem = entry.problem {
                    Text(verbatim: Self.text(for: problem)).foregroundColor(FRTheme.danger)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
    }

    private static func text(for problem: BatchRenameEntry.Problem) -> String {
        switch problem {
        case .invalidName: return L("名称不合法")
        case .duplicate: return L("名称重复")
        case .exists: return L("已存在同名项目")
        }
    }
}

final class BatchRenameController: NSObject, NSWindowDelegate {
    static let shared = BatchRenameController()
    private var window: NSWindow?

    func show(files: [URL], service: FinderRightService) {
        window?.close()
        let model = BatchRenameModel()
        model.items = files
        let window = FRTransientPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
            minSize: CGSize(width: 560, height: 420), autosaveKey: "batchRename")
        window.title = L("批量重命名")
        window.delegate = self
        window.contentView = NSHostingView(rootView: BatchRenameView(
            model: model,
            onApply: { [weak self] entries in
                model.isApplying = true
                service.applyBatchRename(entries) { _ in self?.window?.close() }
            },
            onCancel: { [weak self] in self?.window?.close() }))
        self.window = window
        TransientWindowManager.shared.present(window, openedFromExternalApplication: true)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}
