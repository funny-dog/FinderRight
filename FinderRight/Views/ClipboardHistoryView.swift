import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinderRightKit

// MARK: - 主视图

final class ClipboardDropState: ObservableObject {
    @Published var isTargeted = false
}

struct ClipboardHistoryView: View {
    @ObservedObject private var service = ClipboardHistoryService.shared
    @ObservedObject var dropState: ClipboardDropState
    @FRState private var selectedId: UUID? = nil

    private var activeItem: ClipboardItem? {
        if let selectedId, let matched = service.items.first(where: { $0.id == selectedId }) {
            return matched
        }
        return service.items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            FRDivider()
            contentArea
        }
        .frame(minWidth: service.showDetails ? 560 : 240, minHeight: service.showDetails ? 340 : 240)
        .background(FRTheme.window)
        .overlay {
            if dropState.isTargeted {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(FRTheme.selection.opacity(0.85))
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(FRTheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(FRTheme.accentText)
                        Text("松开以加入剪贴板")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(FRTheme.text)
                    }
                }
                .padding(8)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            if selectedId == nil {
                selectedId = service.items.first?.id
            }
        }
        .onChange(of: service.items.map(\.id)) { ids in
            if let first = ids.first, selectedId == nil || !ids.contains(selectedId!) {
                selectedId = first
            } else if let first = ids.first, selectedId != first {
                // 新复制的记录出现在顶部时同步更新详情预览
                selectedId = first
            }
            if ids.isEmpty {
                selectedId = nil
            }
        }
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        HStack(spacing: 8) {
            Text("剪贴板")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FRTheme.text)
                .lineLimit(1)

            Spacer(minLength: 6)

            let limitPreset = ClipboardHistoryLimitPreset(rawValue: service.limit) ?? .five
            FRPicker(label: "记录条数", titleKey: limitPreset.titleKey, selection: Binding(
                get: { ClipboardHistoryLimitPreset(rawValue: service.limit) ?? .five },
                set: { service.setLimit($0.rawValue) }
            )) {
                ForEach(ClipboardHistoryLimitPreset.allCases) { preset in
                    Text(LocalizedStringKey(preset.titleKey)).tag(preset)
                }
            }
            .controlSize(.small)
            .help("记录条数")

            headerIconButton(
                systemName: "sidebar.right",
                isOn: service.showDetails,
                helpKey: service.showDetails ? "隐藏详情" : "显示详情",
                accessibilityLabelKey: "详情"
            ) {
                let next = !service.showDetails
                service.setShowDetails(next)
                ClipboardHistoryController.shared.updateLayout(showDetails: next, animated: true)
            }

            headerIconButton(
                systemName: service.isPinned ? "pin.fill" : "pin",
                isOn: service.isPinned,
                helpKey: service.isPinned ? "已固定：复制或拖动后保持打开" : "未固定：复制或拖动后自动关闭",
                accessibilityLabelKey: "固定剪贴板窗口"
            ) {
                let next = !service.isPinned
                service.setPinned(next)
                ClipboardHistoryController.shared.updateWindowLevel(pinned: next)
            }
        }
        .padding(.leading, 38)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .frame(height: 40)
    }

    private func headerIconButton(
        systemName: String,
        isOn: Bool,
        helpKey: String,
        accessibilityLabelKey: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(isOn ? FRTheme.accentText : FRTheme.text)
                .frame(width: 26, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? FRTheme.selection : FRTheme.field)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isOn ? FRTheme.accentText.opacity(0.5) : FRTheme.fieldBorder, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(helpKey)))
        .accessibilityLabel(Text(accessibilityLabelKey))
        .accessibilityValue(Text(LocalizedStringKey(isOn ? "已开启" : "已关闭")))
    }

    // MARK: - 主体区域

    private var contentArea: some View {
        Group {
            if service.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 26))
                        .foregroundColor(FRTheme.mute.opacity(0.8))
                    Text("剪贴板记录为空")
                        .font(.system(size: 12.5))
                        .foregroundColor(FRTheme.mute)
                    Text("也可将文件拖入此处")
                        .font(.system(size: 11.5))
                        .foregroundColor(FRTheme.mute.opacity(0.85))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.showDetails {
                HStack(spacing: 0) {
                    listColumn
                        .frame(width: 240)
                        .frame(maxHeight: .infinity)

                    Rectangle()
                        .fill(FRTheme.border)
                        .frame(width: 1)

                    ClipboardDetailPane(item: activeItem)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                listColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var listColumn: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(service.items) { item in
                    ClipboardHistoryRow(
                        item: item,
                        isSelected: service.showDetails && activeItem?.id == item.id,
                        onHoverSelect: {
                            if service.showDetails {
                                selectedId = item.id
                            }
                        },
                        onCopy: {
                            if service.copyItem(item), !service.isPinned {
                                ClipboardHistoryController.shared.close()
                            }
                        },
                        onDragEnded: {
                            if !service.isPinned {
                                ClipboardHistoryController.shared.close()
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}


enum ClipboardHistoryHelpers {
    static func fileIcon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if let utType = UTType(filenameExtension: url.pathExtension) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .item)
    }
}
