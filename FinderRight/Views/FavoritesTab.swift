import SwiftUI
import AppKit
import FinderRightKit

// MARK: - 常用目录 Tab

/// 管理右键「移动到 / 复制到」使用的常用目录：添加、移除、拖动排序。
struct FavoritesTab: View {
    @FRState private var paths: [String] = SharedConfig.shared.favoriteDirectories
    @FRState private var message: String?
    @FRState private var dropTargetPath: String?
    @FRState private var pathInput = ""

    private var home: String { IPCBridge.realUserHomeDirectory.path }

    var body: some View {
        FRPage(title: "常用目录", subtitle: "右键「移动到 / 复制到」使用的目的地") {
            FRSection {
                HStack {
                    FRCaption("常用目录")
                    Spacer()
                    Button {
                        addDirectories()
                    } label: {
                        Label("添加目录…", systemImage: "plus")
                    }
                    .buttonStyle(.frPrimary)
                }
            } content: {
                pathInputRow

                FRCard {
                    if paths.isEmpty {
                        emptyState
                    } else {
                        let names = FavoriteDirectories.displayNames(for: paths, home: home)
                        ForEach(Array(zip(paths, names).enumerated()), id: \.element.0) { index, pair in
                            if index > 0 { FRDivider() }
                            row(path: pair.0, name: pair.1)
                        }
                    }
                }

                if let message {
                    Text(verbatim: message)
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.warnText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                FRFootnote(Text("添加后，选中文件右键即可「移动到」或「复制到」这些目录。拖动左侧的 ≡ 可调整顺序。只能添加用户主目录或外接磁盘中的目录。输入框可直接粘贴「复制路径」得到的内容，多个目录每行一个。"))
            }
        }
        .onAppear {
            paths = SharedConfig.shared.favoriteDirectories
        }
    }

    /// 手动输入 / 粘贴路径：回车或点「添加」提交，Option-回车换行
    private var pathInputRow: some View {
        HStack(alignment: .top, spacing: 8) {
            TextField("粘贴或输入目录路径，如 ~/Downloads", text: $pathInput, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
                .lineLimit(1...4)
                .onSubmit(addTypedPaths)
            Button("添加", action: addTypedPaths)
                .buttonStyle(.frSecondary)
                .disabled(pathInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            FRIconChip(systemName: "folder.badge.plus", size: 40)
            Text("还没有常用目录")
                .font(.system(size: 13))
                .foregroundColor(FRTheme.mute)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func row(path: String, name: String) -> some View {
        let exists = FileManager.default.fileExists(atPath: path)
        return HStack(spacing: 10) {
            FRGrip()
                .draggable(path)
                .help("拖动调整顺序")

            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                Text(verbatim: PathFormatter.string(for: [URL(fileURLWithPath: path)], format: .tilde, home: home))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(FRTheme.mute)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !exists {
                    Text("目录不存在，移动或复制到这里会失败")
                        .font(.system(size: 12))
                        .foregroundColor(FRTheme.warnText)
                }
            }

            Spacer(minLength: 8)

            Button {
                remove(path)
            } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 15))
                    .foregroundColor(FRTheme.mute)
            }
            .buttonStyle(.plain)
            .help("移除")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(dropTargetPath == path ? FRTheme.selection : Color.clear)
        .dropDestination(for: String.self) { dropped, _ in
            guard let moved = dropped.first else { return false }
            return move(moved, to: path)
        } isTargeted: { targeted in
            if targeted {
                dropTargetPath = path
            } else if dropTargetPath == path {
                dropTargetPath = nil
            }
        }
    }

    private func save(_ newPaths: [String]) {
        paths = newPaths
        SharedConfig.shared.favoriteDirectories = newPaths
    }

    private func remove(_ path: String) {
        message = nil
        save(paths.filter { $0 != path })
    }

    /// 下移时落在目标之后，上移时落在目标之前
    private func move(_ path: String, to target: String) -> Bool {
        dropTargetPath = nil
        guard path != target,
              let from = paths.firstIndex(of: path),
              let to = paths.firstIndex(of: target) else { return false }
        var updated = paths
        updated.insert(updated.remove(at: from), at: to)
        save(updated)
        return true
    }

    private func addDirectories() {
        message = nil
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = NSLocalizedString("添加", comment: "")
        guard panel.runModal() == .OK else { return }

        var updated = paths
        var rejected: [String] = []
        for url in panel.urls {
            switch Self.append(url, to: &updated) {
            case .added, .duplicate: break
            case .notAllowed: rejected.append(url.lastPathComponent)
            }
        }
        save(updated)
        if !rejected.isEmpty {
            message = String(format: NSLocalizedString("以下目录不在允许范围内，未添加：%@", comment: ""),
                             rejected.joined(separator: "、"))
        }
    }

    /// 解析输入框内容（兼容「复制路径」的各种格式），逐个校验后加入列表；失败的保留在输入框里方便修改
    private func addTypedPaths() {
        message = nil
        let candidates = FavoriteDirectories.candidatePaths(fromInput: pathInput)
        guard !candidates.isEmpty else { return }

        var updated = paths
        var failedInputs: [String] = []
        var failures: [String] = []
        for raw in candidates {
            let reason: String
            do {
                let url = try DirectoryPath.url(for: raw, home: home)
                switch Self.append(url, to: &updated) {
                case .added: continue
                case .duplicate: reason = "已在列表中"
                case .notAllowed: reason = "不在允许范围内"
                }
            } catch let error as DirectoryPath.ValidationError {
                reason = error.rawValue
            } catch {
                reason = error.localizedDescription
            }
            failedInputs.append(raw)
            failures.append(String(format: NSLocalizedString("%@（%@）", comment: ""),
                                   raw, NSLocalizedString(reason, comment: "")))
        }
        save(updated)
        pathInput = failedInputs.joined(separator: "\n")
        if !failures.isEmpty {
            message = String(format: NSLocalizedString("以下路径未添加：%@", comment: ""),
                             failures.joined(separator: "、"))
        }
    }

    private enum AppendResult { case added, duplicate, notAllowed }

    private static func append(_ url: URL, to list: inout [String]) -> AppendResult {
        let path = url.standardizedFileURL.path
        guard !list.contains(path) else { return .duplicate }
        // 与执行移动 / 复制时相同的白名单：只放行真实主目录与 /Volumes 下、且非完全磁盘访问专属数据的目录
        guard FinderRightService.isPathAllowed(path, role: .destination) else { return .notAllowed }
        list.append(path)
        return .added
    }
}
