import SwiftUI
import AppKit
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "batch rename") }

final class BatchRenameModel: ObservableObject {
    enum Mode: Int, CaseIterable {
        case replace, affix, sequence, date, letterCase
        var title: String {
            switch self {
            case .replace: return "查找替换"
            case .affix: return "前后缀"
            case .sequence: return "序号"
            case .date: return "日期"
            case .letterCase: return "大小写"
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
    @Published var start = "1"
    @Published var digits = "2"
    @Published var dateFormat = "yyyy-MM-dd"
    @Published var dateAtStart = true
    @Published var letterCase = BatchRenameCase.lower
    @Published var isApplying = false

    var rule: BatchRenameRule {
        switch mode {
        case .replace: return .replace(find: find, with: replacement, regex: isRegex)
        case .affix: return .affix(prefix: prefix, suffix: suffix)
        case .sequence: return .sequence(text: sequenceText, start: Int(start) ?? 1, digits: min(max(Int(digits) ?? 1, 1), 8))
        case .date: return .date(format: dateFormat, atStart: dateAtStart)
        case .letterCase: return .letterCase(letterCase)
        }
    }

    var entries: [BatchRenameEntry] { BatchRename.plan(items: items, rule: rule) }
}

struct BatchRenameView: View {
    @ObservedObject var model: BatchRenameModel
    let onApply: ([BatchRenameEntry]) -> Void
    let onCancel: () -> Void
    @AppStorage(FRThemeID.storageKey) private var themeRaw = FRThemeID.midnight.rawValue
    @FocusState private var focusedField: String?

    var body: some View {
        let entries = model.entries
        let changed = entries.filter(\.isChanged)
        let problems = changed.filter { $0.problem != nil }.count
        VStack(alignment: .leading, spacing: 0) {
            header

            FRSegmentedPicker(label: "改名规则", selection: $model.mode,
                              options: BatchRenameModel.Mode.allCases.map { ($0, $0.title) })
                .padding(.top, 14)

            ruleFields.padding(.top, 10)

            if model.rule.isInvalid {
                Label(L("正则表达式不合法"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundColor(FRTheme.warnText).padding(.top, 8)
            }

            HStack {
                FRCaption("预览")
                Spacer()
                FRChip(text: Text(verbatim: String(format: L("%d 项将改名"), changed.count)),
                       kind: changed.isEmpty ? .neutral : .accent)
            }
            .padding(.top, 16).padding(.bottom, 6)

            FRCard {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries.indices, id: \.self) { index in
                            if index > 0 { FRDivider() }
                            row(entries[index])
                        }
                    }
                }
            }
            .frame(minHeight: 150)

            HStack(spacing: 8) {
                if problems > 0 {
                    Label(String(format: L("%d 项有问题，请调整规则"), problems), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundColor(FRTheme.warnText)
                }
                Spacer(minLength: 0)
                Button(L("取消"), action: onCancel)
                    .buttonStyle(.frSecondary).keyboardShortcut(.cancelAction)
                Button(L("重命名"), action: { onApply(entries) })
                    .buttonStyle(.frPrimary).keyboardShortcut(.defaultAction)
                    .disabled(problems > 0 || changed.isEmpty || model.isApplying)
            }
            .padding(.top, 14)
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 440)
        .foregroundColor(FRTheme.text)
        .background(FRTheme.window)
        .id(themeRaw)
    }

    private var header: some View {
        HStack(spacing: 10) {
            FRIconChip(systemName: "pencil.line", size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("批量重命名")).font(.system(size: 14, weight: .semibold))
                Text(verbatim: String(format: L("已选 %d 项"), model.items.count))
                    .font(.system(size: 12)).foregroundColor(FRTheme.mute)
            }
            Spacer()
        }
    }

    @ViewBuilder private var ruleFields: some View {
        switch model.mode {
        case .replace:
            HStack(spacing: 8) {
                field("magnifyingglass", L("查找"), $model.find)
                field("arrow.right", L("替换为"), $model.replacement)
                BatchRenameTogglePill(isOn: $model.isRegex)
            }
        case .affix:
            HStack(spacing: 8) {
                field("text.insert", L("前缀"), $model.prefix)
                field("text.append", L("后缀（扩展名之前）"), $model.suffix)
            }
        case .sequence:
            HStack(spacing: 8) {
                field("textformat", L("名称文本，可留空"), $model.sequenceText)
                field("number", L("起始"), $model.start).frame(width: 90)
                field("squareshape.split.3x3", L("位数"), $model.digits).frame(width: 90)
            }
        case .date:
            HStack(spacing: 8) {
                field("calendar", L("日期格式"), $model.dateFormat)
                FRSegmentedPicker(label: "日期位置", selection: $model.dateAtStart,
                                  options: [(true, "加在开头"), (false, "加在结尾")])
                    .frame(width: 170)
            }
        case .letterCase:
            FRSegmentedPicker(label: "大小写", selection: $model.letterCase,
                              options: [(.lower, "小写"), (.upper, "大写"), (.capitalized, "首字母大写")])
        }
    }

    private func field(_ symbol: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        FRTextFieldContainer(symbol: symbol, isFocused: focusedField == placeholder, height: 32) {
            TextField("", text: text, prompt: Text(placeholder))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focusedField, equals: placeholder)
        }
    }

    private func row(_ entry: BatchRenameEntry) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: entry.source.lastPathComponent)
                .foregroundColor(entry.isChanged ? FRTheme.mute : FRTheme.text)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.isChanged {
                Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold))
                    .foregroundColor(FRTheme.mute).accessibilityHidden(true)
                Text(verbatim: entry.newName)
                    .fontWeight(.medium)
                    .foregroundColor(entry.problem == nil ? FRTheme.okText : FRTheme.warnText)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let problem = entry.problem {
                    FRChip(text: Text(verbatim: Self.text(for: problem)), kind: .warn)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 7)
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            minSize: CGSize(width: 520, height: 440), autosaveKey: "batchRename")
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

private struct BatchRenameTogglePill: View {
    @Binding var isOn: Bool
    @FRState private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(verbatim: ".*")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                Text(L("正则"))
                    .font(.system(size: 12, weight: isOn ? .semibold : .medium))
            }
            .foregroundColor(isOn ? FRTheme.accentText : (isHovering ? FRTheme.text : FRTheme.mute))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOn ? FRTheme.selection : (isHovering ? FRTheme.dropdownHoverFill : FRTheme.field))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isOn ? FRTheme.accent.opacity(0.5) : (isHovering ? FRTheme.accentText.opacity(0.35) : FRTheme.fieldBorder),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isOn)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
        .accessibilityLabel(Text(L("正则")))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
