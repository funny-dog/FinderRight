import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinderRightKit

// MARK: - 主视图

struct CutQueueView: View {
    @FRState private var paths: [String] = []
    @FRState private var errorMessage: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentArea
            Divider()
            footerBar
        }
        .frame(minWidth: 440, minHeight: 280)
        .background(FRTheme.window)
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name(CutQueueChangeNotifier.name))) { _ in
            refresh()
        }
    }

    // MARK: - 顶栏

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "scissors")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("已剪切项目", comment: ""))
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(FRTheme.text)
                Text(String(format: NSLocalizedString("共 %d 项待移动", comment: ""), paths.count))
                    .font(.system(size: 11))
                    .foregroundColor(FRTheme.mute)
            }

            Spacer(minLength: 12)

            Button(NSLocalizedString("全部清空", comment: "")) {
                clearAll()
            }
            .buttonStyle(.frSecondary)
            .disabled(paths.isEmpty)
        }
        .padding(14)
    }

    // MARK: - 主体列表

    private var contentArea: some View {
        Group {
            if paths.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "scissors")
                        .font(.system(size: 32))
                        .foregroundColor(FRTheme.mute)
                    Text(NSLocalizedString("剪切队列为空", comment: ""))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(FRTheme.text)
                    Text(NSLocalizedString("在访达中剪切文件（⌘X）后会显示在这里", comment: ""))
                        .font(.system(size: 11))
                        .foregroundColor(FRTheme.mute)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    if let errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                            Text(verbatim: errorMessage)
                                .font(.system(size: 11))
                            Spacer(minLength: 0)
                        }
                        .foregroundColor(FRTheme.danger)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(FRTheme.danger.opacity(0.08))
                        Divider()
                    }

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(paths, id: \.self) { path in
                                CutQueueRow(path: path, onRemove: { remove(path) })
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 底栏

    private var footerBar: some View {
        HStack(spacing: 8) {
            Text(NSLocalizedString("在目标目录右键「粘贴」或按 ⌘V 即可移动", comment: ""))
                .font(.system(size: 11))
                .foregroundColor(FRTheme.mute)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(NSLocalizedString("关闭", comment: "")) {
                CutQueueController.shared.close()
            }
            .buttonStyle(.frSecondary)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func refresh() {
        paths = FinderRightService.pendingCutPaths()
    }

    private func remove(_ path: String) {
        do {
            try FinderRightService.removePendingCutPath(path)
            errorMessage = nil
        } catch CutQueueStore.RemovalError.pasteInProgress {
            errorMessage = NSLocalizedString("正在粘贴，请完成后再移除剪切项", comment: "")
        } catch {
            errorMessage = String(format: NSLocalizedString("移除剪切项失败：%@", comment: ""), error.localizedDescription)
        }
        refresh()
    }

    private func clearAll() {
        do {
            try FinderRightService.clearPendingCutQueue()
            errorMessage = nil
        } catch CutQueueStore.RemovalError.pasteInProgress {
            errorMessage = NSLocalizedString("正在粘贴，请完成后再清空剪切队列", comment: "")
        } catch {
            errorMessage = String(format: NSLocalizedString("清空剪切队列失败：%@", comment: ""), error.localizedDescription)
        }
        refresh()
    }
}

// MARK: - 子项行

private struct CutQueueRow: View {
    let path: String
    let onRemove: () -> Void
    @FRState private var isHovered = false

    private var fileIcon: NSImage {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        if let utType = UTType(filenameExtension: (path as NSString).pathExtension) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .item)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: fileIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: (path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(FRTheme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: path)
                    .font(.system(size: 10))
                    .foregroundColor(FRTheme.mute)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button(NSLocalizedString("移除", comment: "")) {
                onRemove()
            }
            .buttonStyle(.frSecondary)
            .accessibilityLabel(Text(String(format: NSLocalizedString("移除：%@", comment: ""), path)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 控制器

final class CutQueueController: NSObject, NSWindowDelegate {
    static let shared = CutQueueController()
    private var window: NSWindow?

    private static let defaultSize = CGSize(width: 520, height: 380)
    private static let minimumSize = CGSize(width: 440, height: 280)

    func show() {
        if window == nil {
            let window = FRTransientPanel(
                contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                minSize: Self.minimumSize,
                autosaveKey: "cutQueue")
            window.title = NSLocalizedString("已剪切项目", comment: "")
            window.delegate = self
            window.contentView = NSHostingView(rootView: CutQueueView())
            self.window = window
        }

        if let window { TransientWindowManager.shared.present(window) }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
