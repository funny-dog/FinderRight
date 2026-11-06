import SwiftUI
import AppKit
import FinderRightKit

final class GitStatusModel: ObservableObject {
    @Published private(set) var sourceURL: URL?
    @Published private(set) var snapshot: GitStatusSnapshot?
    @Published private(set) var selectedPath: String?
    @Published private(set) var scope = GitDiffScope.unstaged
    @Published private(set) var comparison: GitFileComparison?
    @Published private(set) var error: String?
    @Published private(set) var diffError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isComparing = false
    @Published private(set) var directoryFilter: String?
    @Published private(set) var isPerforming = false
    @Published private(set) var actionError: String?
    @Published private(set) var actionMessage: String?
    @Published private(set) var commitPreview: GitCommitPreview?
    @Published var commitMessage = ""
    private let queue = DispatchQueue(label: "com.finderright.app.git-status", qos: .userInitiated)
    private var statusRevision = 0
    private var diffRevision = 0
    private var statusOperation: BlockOperation?
    private var diffOperation: BlockOperation?

    var visibleEntries: [GitStatusEntry] {
        guard let snapshot else { return [] }
        guard let directoryFilter else { return snapshot.entries }
        return snapshot.entries.filter { entry in
            entry.path.hasPrefix(directoryFilter + "/") || entry.originalPath?.hasPrefix(directoryFilter + "/") == true
        }
    }

    var selectedEntry: GitStatusEntry? {
        visibleEntries.first { $0.path == selectedPath }
    }

    func open(at url: URL) {
        guard !isPerforming else { return }
        actionError = nil
        actionMessage = nil
        commitPreview = nil
        commitMessage = ""
        sourceURL = url
        directoryFilter = nil
        selectedPath = nil
        snapshot = nil
        refresh(resetScope: true)
    }

    func refresh(resetScope: Bool = false) {
        guard !isPerforming, let sourceURL else { return }
        statusRevision += 1
        let revision = statusRevision
        statusOperation?.cancel()
        clearComparison()
        error = nil
        isLoading = true
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let result = Result { try GitStatusSnapshot.read(at: sourceURL) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.statusRevision == revision, !operation.isCancelled else { return }
                self.isLoading = false
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    if resetScope {
                        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
                        let root = snapshot.root.resolvingSymlinksInPath().standardizedFileURL
                        if source.path.hasPrefix(root.path + "/") {
                            let path = String(source.path.dropFirst(root.path.count + 1))
                            if (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                                self.directoryFilter = path
                            } else {
                                self.selectedPath = path
                            }
                        }
                    }
                    self.select(self.visibleEntries.first(where: { $0.path == self.selectedPath })?.path ?? self.visibleEntries.first?.path)
                case .failure(let error):
                    self.snapshot = nil
                    self.error = error.localizedDescription
                }
            }
        }
        statusOperation = operation
        if !FinderRightService.runGuarded(on: queue, work: { operation.start() }) {
            isLoading = false
            error = NSLocalizedString("FinderRight 正在退出，请稍后重试", comment: "")
        }
    }

    func showWholeRepository() {
        directoryFilter = nil
        select(selectedEntry?.path ?? visibleEntries.first?.path)
    }

    func select(_ path: String?) {
        guard !isPerforming else { return }
        selectedPath = path
        if let entry = selectedEntry {
            if scope == .staged && (!entry.hasStaged || entry.isConflict) { scope = .unstaged }
            if scope == .unstaged && !entry.hasUnstaged && !entry.isConflict { scope = .staged }
        }
        loadComparison()
    }

    func setScope(_ value: GitDiffScope) {
        scope = value
        loadComparison()
    }

    func cancel() {
        guard !isPerforming else { return }
        statusRevision += 1
        statusOperation?.cancel()
        clearComparison()
        isLoading = false
    }

    var hasConflicts: Bool { snapshot?.entries.contains(where: \.isConflict) == true }
    var canCommit: Bool { !isLoading && !isPerforming && !hasConflicts && snapshot?.entries.contains(where: \.hasStaged) == true }

    func paths(for entries: [GitStatusEntry], unstaging: Bool = false) -> [String] {
        entries.flatMap { entry in
            let original = unstaging || entry.worktreeStatus == "R" || entry.worktreeStatus == "C" ? entry.originalPath : nil
            return [entry.path, original].compactMap { $0 }
        }
    }

    func prepareCommit() {
        guard !isLoading, !isPerforming, let root = snapshot?.root else { return }
        isPerforming = true
        actionError = nil
        actionMessage = nil
        if !FinderRightService.runGuarded(on: queue, work: { [self] in
            let result = Result { try GitLocalRepository.prepareCommit(at: root) }
            DispatchQueue.main.async { [self] in
                isPerforming = false
                switch result {
                case .success(let value): commitPreview = value
                case .failure(let error): actionError = error.localizedDescription
                }
            }
        }) { rejectAction() }
    }

    func dismissCommit() {
        guard !isPerforming else { return }
        commitPreview = nil
        actionError = nil
    }

    func perform(_ action: GitLocalAction, success: String, onSuccess: @escaping () -> Void = {}) {
        guard !isLoading, !isPerforming, let root = snapshot?.root else { return }
        isPerforming = true
        actionError = nil
        actionMessage = nil
        clearComparison()
        if !FinderRightService.runGuarded(on: queue, work: { [self] in
            let result = Result { try GitLocalRepository.perform(action, at: root) }
            DispatchQueue.main.async { [self] in
                isPerforming = false
                switch result {
                case .success:
                    actionMessage = NSLocalizedString(success, comment: "")
                    if case .commit = action { commitPreview = nil; commitMessage = "" }
                    onSuccess()
                case .failure(let error): actionError = error.localizedDescription
                }
                // 切换分支可能移除原来选中的目录，后续读取始终从仓库根目录开始。
                sourceURL = root
                refresh()
            }
        }) { rejectAction() }
    }

    private func rejectAction() {
        isPerforming = false
        actionError = NSLocalizedString("FinderRight 正在退出，请稍后重试", comment: "")
    }

    private func clearComparison() {
        diffRevision += 1
        diffOperation?.cancel()
        comparison = nil
        diffError = nil
        isComparing = false
    }

    private func loadComparison() {
        clearComparison()
        guard let root = snapshot?.root, let entry = selectedEntry else { return }
        let revision = diffRevision, scope = scope
        isComparing = true
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation, !operation.isCancelled else { return }
            let result = Result { try GitFileComparison.read(root: root, entry: entry, scope: scope) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.diffRevision == revision, !operation.isCancelled else { return }
                self.isComparing = false
                switch result {
                case .success(let value): self.comparison = value
                case .failure(let error): self.diffError = error.localizedDescription
                }
            }
        }
        diffOperation = operation
        if !FinderRightService.runGuarded(on: queue, work: { operation.start() }) {
            isComparing = false
            diffError = NSLocalizedString("FinderRight 正在退出，请稍后重试", comment: "")
        }
    }
}

enum GitStatusLayout {
    static let contentSize = NSSize(width: 600, height: 480)
    static let minimumContentSize = NSSize(width: 520, height: 380)
}

struct GitStatusView: View {
    @ObservedObject var model: GitStatusModel
    @FRState private var isTargeted = false
    @FRState private var showingNewBranch = false
    @FRState private var branchName = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            FRDivider()
            if let snapshot = model.snapshot {
                if let filter = model.directoryFilter {
                    HStack {
                        Label(filter, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("整个仓库") { model.showWholeRepository() }.buttonStyle(.frLink)
                    }
                    .font(.system(size: 11)).foregroundColor(FRTheme.mute)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    FRDivider()
                }
                if model.visibleEntries.isEmpty {
                    message(snapshot.entries.isEmpty ? "工作区干净" : "当前目录没有改动", icon: "checkmark.circle", color: FRTheme.okText)
                } else {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            List(selection: Binding(get: { model.selectedPath }, set: { model.select($0) })) {
                                ForEach(model.visibleEntries) { entry in
                                    entryRow(entry).tag(entry.path)
                                }
                            }
                            .listStyle(.plain).scrollContentBackground(.hidden)
                            .frame(height: min(160, geometry.size.height * 0.34))
                            .disabled(model.isLoading || model.isPerforming)
                            FRDivider()
                            comparisonPane
                        }
                    }
                }
            } else if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                message(error, icon: "exclamationmark.triangle", color: FRTheme.danger)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 32, weight: .light)).foregroundColor(FRTheme.accentText)
                    Text("拖入项目文件夹或选择项目").font(.system(size: 13))
                    Button("选择项目…", action: chooseProject).buttonStyle(.frSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if model.snapshot != nil {
                FRDivider()
                actionBar
                GitActionFeedback(model: model)
            }
        }
        .sheet(isPresented: Binding(get: { model.commitPreview != nil }, set: { if !$0 { model.dismissCommit() } })) {
            GitCommitSheet(model: model)
        }
        .sheet(isPresented: $showingNewBranch) {
            newBranchSheet
        }
        .frame(minWidth: 520, minHeight: 380)
        .foregroundColor(FRTheme.text).background(isTargeted ? FRTheme.selection : FRTheme.window)
        .dropDestination(for: URL.self) { urls, _ in
            guard !model.isPerforming, urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            model.open(at: url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: model.snapshot?.root.lastPathComponent ?? NSLocalizedString("Git 状态", comment: ""))
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let snapshot = model.snapshot {
                    Menu {
                        ForEach(snapshot.localBranches, id: \.self) { branch in
                            Button { model.perform(.switchBranch(branch), success: "已切换分支") } label: {
                                if branch == snapshot.branch { Label(branch, systemImage: "checkmark") }
                                else { Text(verbatim: branch) }
                            }
                            .disabled(branch == snapshot.branch)
                        }
                        Divider()
                        Button("新建分支…") { showingNewBranch = true }
                    } label: {
                        Label(snapshot.branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11)).foregroundColor(FRTheme.accentText).lineLimit(1)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: 220, alignment: .leading)
                    .disabled(model.isLoading || model.isPerforming)
                    .help("切换本地分支")
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .help(Text(verbatim: model.snapshot?.root.path ?? ""))
            Spacer()
            if model.isLoading || model.isPerforming { ProgressView().controlSize(.small) }
            Button("选择项目…", action: chooseProject).buttonStyle(.frLink).disabled(model.isPerforming)
            Button("刷新") { model.refresh() }.buttonStyle(.frSecondary)
                .disabled(model.sourceURL == nil || model.isLoading || model.isPerforming)
                .keyboardShortcut("r", modifiers: .command)
        }
        .padding(12)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("暂存文件") {
                if let entry = model.selectedEntry { model.perform(.stage(model.paths(for: [entry])), success: "已暂存") }
            }
            .buttonStyle(.frSecondary)
            .disabled(model.selectedEntry?.hasUnstaged != true)
            Button("取消暂存") {
                if let entry = model.selectedEntry { model.perform(.unstage(model.paths(for: [entry], unstaging: true)), success: "已取消暂存") }
            }
            .buttonStyle(.frSecondary)
            .disabled(model.selectedEntry?.hasStaged != true)
            Menu("批量…") {
                Button(model.directoryFilter == nil ? "全部暂存" : "暂存当前目录") {
                    model.perform(.stage(model.paths(for: model.visibleEntries.filter(\.hasUnstaged))), success: "已暂存")
                }
                .disabled(!model.visibleEntries.contains(where: \.hasUnstaged))
                Button(model.directoryFilter == nil ? "全部取消暂存" : "取消当前目录暂存") {
                    model.perform(.unstage(model.paths(for: model.visibleEntries.filter(\.hasStaged), unstaging: true)), success: "已取消暂存")
                }
                .disabled(!model.visibleEntries.contains(where: \.hasStaged))
            }
            .fixedSize()
            Spacer(minLength: 4)
            Button("提交…") { model.prepareCommit() }
                .buttonStyle(.frPrimary).disabled(!model.canCommit)
                .help(model.hasConflicts ? "尚有未解决的冲突，请解决后暂存" : "提交整个仓库的暂存区")
            
            // 拉取/推送：只有配置了远端才可用；没有上游时拉取需要用户自行指定，
            // 这里禁用并给出提示，而不是让 git 报一句难以理解的英文错误。
            Button("拉取") {
                model.perform(.pull(rebase: false), success: NSLocalizedString("已拉取", comment: ""))
            }
            .buttonStyle(.frSecondary)
            .disabled(model.isLoading || model.isPerforming || model.snapshot?.upstream == nil)
            .help(model.snapshot?.upstream == nil ? "当前分支没有上游分支，请先在终端设置跟踪分支" : "拉取远端并合并到当前分支")

            Button("推送") {
                model.perform(.push(remoteBranch: nil), success: NSLocalizedString("已推送", comment: ""))
            }
            .buttonStyle(.frSecondary)
            .disabled(model.isLoading || model.isPerforming || model.snapshot?.hasRemote != true)
            .help(model.snapshot?.hasRemote == true ? "推送当前分支到远端" : "仓库没有配置远端")
        }
        .font(.system(size: 12)).padding(12)
        .disabled(model.isLoading || model.isPerforming)
    }

    private var newBranchSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建并切换分支").font(.system(size: 17, weight: .semibold))
            TextField("分支名称", text: $branchName).textFieldStyle(.roundedBorder)
                .disabled(model.isPerforming)
            GitActionFeedback(model: model)
            HStack {
                Spacer()
                Button("取消") { showingNewBranch = false }.buttonStyle(.frSecondary)
                    .keyboardShortcut(.cancelAction).disabled(model.isPerforming)
                Button("创建并切换") {
                    model.perform(.createBranch(branchName), success: "已创建并切换分支") {
                        showingNewBranch = false
                        branchName = ""
                    }
                }
                .buttonStyle(.frPrimary).keyboardShortcut(.defaultAction)
                .disabled(model.isPerforming || model.isLoading || branchName.isEmpty)
            }
        }
        .padding(20).frame(width: 380)
        .foregroundColor(FRTheme.text).background(FRTheme.window)
        .interactiveDismissDisabled(model.isPerforming)
    }

    private func entryRow(_ entry: GitStatusEntry) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: entry.isUntracked ? "??" : entry.indexStatus + entry.worktreeStatus)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(entry.isConflict ? FRTheme.danger : FRTheme.accentText)
                .frame(width: 26, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                if let original = entry.originalPath {
                    Text(verbatim: "← " + original).font(.system(size: 10)).foregroundColor(FRTheme.mute).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: statusLabel(entry)).font(.system(size: 10))
                .foregroundColor(entry.isConflict ? FRTheme.danger : FRTheme.mute)
        }
        .padding(.vertical, 3)
        .help(Text(verbatim: entry.path))
    }

    private func statusLabel(_ entry: GitStatusEntry) -> String {
        if entry.isConflict { return NSLocalizedString("冲突", comment: "") }
        if entry.isUntracked {
            return NSLocalizedString(entry.hasStaged ? "已暂存 · 未跟踪" : "未跟踪", comment: "")
        }
        if entry.hasStaged && entry.hasUnstaged { return NSLocalizedString("已暂存 · 未暂存", comment: "") }
        return NSLocalizedString(entry.hasStaged ? "已暂存" : "未暂存", comment: "")
    }

    private var comparisonPane: some View {
        VStack(spacing: 0) {
            if let entry = model.selectedEntry {
                HStack(spacing: 8) {
                    if entry.hasStaged && entry.hasUnstaged && !entry.isConflict {
                        Picker("差异范围", selection: Binding(get: { model.scope }, set: { model.setScope($0) })) {
                            Text("未暂存").tag(GitDiffScope.unstaged)
                            Text("已暂存").tag(GitDiffScope.staged)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 160)
                        .accessibilityLabel("差异范围")
                    } else {
                        Text(entry.isConflict ? "冲突：我方与工作区" : (model.scope == .staged ? "已暂存" : (entry.isUntracked ? "未跟踪" : "未暂存")))
                            .font(.system(size: 11, weight: .medium)).foregroundColor(FRTheme.mute)
                    }
                    Spacer()
                    if let diff = model.comparison {
                        Text(verbatim: "+\(diff.result.additions)").foregroundColor(FRTheme.okText)
                        Text(verbatim: "−\(diff.result.deletions)").foregroundColor(FRTheme.danger)
                    }
                }
                .font(.system(size: 11)).padding(.horizontal, 12).frame(height: 34)
                FRDivider()
                HStack {
                    Text(model.scope == .staged ? "HEAD" : (entry.isConflict ? "我方" : "暂存区"))
                        .frame(maxWidth: .infinity)
                    Text(model.scope == .staged ? "暂存区" : "工作区").frame(maxWidth: .infinity)
                }
                .font(.system(size: 10)).foregroundColor(FRTheme.mute)
                .padding(.vertical, 5).background(FRTheme.card)
                FRDivider()
            }
            if model.isComparing {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.diffError {
                message(error, icon: "exclamationmark.triangle", color: FRTheme.mute)
            } else if let comparison = model.comparison {
                if comparison.result.additions == 0 && comparison.result.deletions == 0 {
                    message(comparison.result.differentLineEndings ? "文本相同，换行格式不同" : "文本内容相同，请检查文件格式或属性", icon: "equal.circle", color: FRTheme.mute)
                } else {
                    FileComparisonDiffView(left: comparison.left, right: comparison.right, result: comparison.result)
                }
            } else {
                message("选择文件查看差异", icon: "doc.text", color: FRTheme.mute)
            }
        }
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 24, weight: .light))
            Text(verbatim: NSLocalizedString(text, comment: "")).font(.system(size: 12)).multilineTextAlignment(.center).textSelection(.enabled)
        }
        .foregroundColor(color).padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { model.open(at: url) }
    }
}

final class GitStatusController: NSObject, NSWindowDelegate {
    static let shared = GitStatusController()
    private var window: NSWindow?
    private var model: GitStatusModel?
    var isPerforming: Bool { model?.isPerforming == true }
    
    private let windowType = "gitStatus"

    func show(at url: URL? = nil) {
        if window == nil {
            let model = GitStatusModel()
            let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
            let contentRect = NSRect(origin: .zero, size: GitStatusLayout.contentSize)
            let window = NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
            window.title = NSLocalizedString("Git 状态", comment: "")
            window.minSize = NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: GitStatusLayout.minimumContentSize),
                                                styleMask: styleMask).size
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: GitStatusView(model: model))
            // 恢复了上次位置就不要再 center()，否则会把恢复结果覆盖掉
            if let saved = SharedConfig.shared.restoreWindowPosition(for: windowType),
               let adjusted = Self.fittedFrame(saved, window: window) {
                window.setFrame(adjusted, display: false)
            } else {
                window.center()
            }
            self.model = model
            self.window = window
        }
        if let url { model?.open(at: url) }
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 恢复的 frame 可能因屏幕变小或最小尺寸变化而越界，套回当前可见区域保证可操作。
    private static func fittedFrame(_ frame: NSRect, window: NSWindow) -> NSRect? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return nil }
        var result = frame
        result.size.width = max(window.minSize.width, min(result.width, screen.visibleFrame.width))
        result.size.height = max(window.minSize.height, min(result.height, screen.visibleFrame.height))
        result.origin.x = max(screen.visibleFrame.minX, min(result.minX, screen.visibleFrame.maxX - result.width))
        result.origin.y = max(screen.visibleFrame.minY, min(result.minY, screen.visibleFrame.maxY - result.height))
        return result
    }

    /// 拖动与缩放结束时保存一次；不要同时监听 windowDidMove，否则持续拖动会反复写盘。
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame(notification) }

    func windowDidEndMoving(_ notification: Notification) { saveFrame(notification) }

    private func saveFrame(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        SharedConfig.shared.saveWindowPosition(for: windowType, frame: window.frame)
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
                Text("正在执行 Git…").font(.system(size: 11))
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 10)
        } else if let error = model.actionError {
            ScrollView {
                Text(verbatim: error).font(.system(size: 11)).foregroundColor(FRTheme.danger)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 72).padding(.horizontal, 12).padding(.bottom, 10)
        } else if let message = model.actionMessage {
            Text(verbatim: message).font(.system(size: 11)).foregroundColor(FRTheme.okText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
        }
    }
}

struct GitCommitSheet: View {
    @ObservedObject var model: GitStatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提交暂存区").font(.system(size: 17, weight: .semibold))
            if let preview = model.commitPreview {
                Text(verbatim: String(format: NSLocalizedString("%d 个文件 · 整个仓库", comment: ""), preview.files.count))
                    .font(.system(size: 11)).foregroundColor(FRTheme.mute)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(preview.files, id: \.self) { path in
                            Text(verbatim: path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
                Text("提交说明").font(.system(size: 12, weight: .medium))
                TextEditor(text: $model.commitMessage)
                    .font(.system(size: 12)).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 100).background(FRTheme.field).cornerRadius(6)
                    .disabled(model.isPerforming)
                    .accessibilityLabel("提交说明")
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
    }
}
