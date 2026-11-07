import AppKit
import SwiftUI
import FinderRightKit

enum FinderRightService {
    static let jobs = BackgroundJobs()
    static func runGuarded(on queue: DispatchQueue, work: @escaping () -> Void) -> Bool {
        jobs.run(on: queue, work)
    }
}

@main
struct GitStatusViewChecks {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FinderRight-git-view-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let folder = root.appendingPathComponent("Sources")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("settings.json")
        let other = root.appendingPathComponent("notes.txt")
        try "{\n  \"enabled\": false\n}\n".write(to: file, atomically: true, encoding: .utf8)
        try "before\n".write(to: other, atomically: true, encoding: .utf8)
        func git(_ arguments: [String]) throws {
            let result = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/git"),
                                               arguments: ["-c", "core.hooksPath=/dev/null"] + arguments, currentDirectoryURL: root)
            precondition(result.status == 0, result.stderr)
        }
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        try git(["config", "commit.gpgSign", "false"])
        try git(["config", "core.hooksPath", "/dev/null"])
        try git(["add", "."])
        try git(["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgSign=false", "commit", "-m", "fixture"])
        try "{\n  \"enabled\": true\n}\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "Sources/settings.json"])
        try "{\n  \"enabled\": true,\n  \"gitStatus\": true\n}\n".write(to: file, atomically: true, encoding: .utf8)
        try "after\n".write(to: other, atomically: true, encoding: .utf8)

        let model = GitStatusModel()
        model.open(at: folder)
        wait(model)
        precondition(model.error == nil && model.snapshot?.branch == "main")
        precondition(model.directoryFilter == "Sources" && model.visibleEntries.map(\.path) == ["Sources/settings.json"])
        precondition(model.scope == .unstaged && model.comparison?.right.text.contains("gitStatus") == true)
        model.setScope(.staged)
        wait(model)
        precondition(model.comparison?.left.text.contains("false") == true)
        precondition(model.comparison?.right.text.contains("gitStatus") == false)
        model.showWholeRepository()
        precondition(model.visibleEntries.count == 2 && model.directoryFilter == nil)
        model.select("notes.txt")
        wait(model)
        precondition(model.scope == .unstaged && model.comparison?.right.text == "after\n")
        model.open(at: root.deletingLastPathComponent())
        Thread.sleep(forTimeInterval: 0.05)
        model.open(at: file)
        wait(model)
        precondition(model.error == nil && model.selectedPath == "Sources/settings.json", "旧请求不能覆盖新项目与文件选择")
        model.refresh()
        wait(model)
        precondition(model.selectedPath == "Sources/settings.json" && model.comparison != nil)
        precondition(FinderRightService.jobs.waitUntilIdle(timeout: 2), "Git 任务必须纳入退出等待")
        print("✓ Git 状态界面：目录筛选、文件定位、暂存切换、刷新与旧请求隔离通过")

        if let outputPath = ProcessInfo.processInfo.environment["FINDERRIGHT_GIT_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                let view = NSHostingView(rootView: GitStatusView(model: model))
                window.contentView = view
                view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                precondition(view.bounds.size == NSSize(width: 600, height: 480), "内容撑大窗口：\(view.bounds.size)")
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("离屏渲染失败") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
                try data.write(to: directory.appendingPathComponent("git-status-\(name).png"))
                window.close()
            }
            print("✓ 使用临时仓库生成深浅色离屏预览，未操作真实 App 窗口")
        }
        model.open(at: folder)
        wait(model)
        model.perform(.stage(model.paths(for: model.visibleEntries.filter(\.hasUnstaged))), success: "已暂存")
        wait(model)
        precondition(model.visibleEntries.allSatisfy { !$0.hasUnstaged && $0.hasStaged })
        precondition(model.snapshot?.entries.first { $0.path == "notes.txt" }?.hasStaged == false, "目录暂存不能带入范围外文件")
        model.prepareCommit()
        wait(model)
        precondition(model.commitPreview?.files == ["Sources/settings.json"])
        model.commitMessage = "feat: 界面提交测试"
        try git(["add", "notes.txt"])
        let stale = model.commitPreview!
        model.perform(.commit(message: model.commitMessage, preview: stale), success: "提交完成")
        wait(model)
        precondition(model.actionError != nil && model.commitMessage == "feat: 界面提交测试" && model.commitPreview != nil)
        model.prepareCommit()
        wait(model)
        precondition(Set(model.commitPreview!.files) == ["Sources/settings.json", "notes.txt"], "提交预览必须包含整个仓库的暂存文件")
        if let path = ProcessInfo.processInfo.environment["FINDERRIGHT_GIT_PREVIEW_DIR"] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let view = NSHostingView(rootView: GitCommitSheet(model: model))
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("提交预览渲染失败") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path).appendingPathComponent("git-commit-dark.png"))
            window.close()
        }
        model.perform(.commit(message: model.commitMessage, preview: model.commitPreview!), success: "提交完成")
        wait(model)
        precondition(model.actionError == nil && model.commitPreview == nil && model.commitMessage.isEmpty)
        precondition(model.snapshot?.entries.isEmpty == true)
        try git(["mv", "Sources/settings.json", "Sources/settings-new.json"])
        let renamed = folder.appendingPathComponent("settings-new.json")
        try "{\n  \"enabled\": false,\n  \"gitStatus\": true\n}\n".write(to: renamed, atomically: true, encoding: .utf8)
        model.refresh()
        wait(model)
        model.select("Sources/settings-new.json")
        wait(model)
        let rename = model.selectedEntry!
        precondition(rename.originalPath == "Sources/settings.json")
        precondition(model.paths(for: [rename]) == ["Sources/settings-new.json"], "已暂存重命名再编辑时不能把已消失的旧路径传给 add")
        model.perform(.stage(model.paths(for: [rename])), success: "已暂存")
        wait(model)
        precondition(model.actionError == nil && model.selectedEntry?.hasUnstaged == false)
        model.perform(.unstage(model.paths(for: [model.selectedEntry!], unstaging: true)), success: "已取消暂存")
        wait(model)
        precondition(model.actionError == nil && model.snapshot?.entries.contains(where: \.hasStaged) == false)
        precondition(fm.fileExists(atPath: renamed.path) && !fm.fileExists(atPath: file.path))
        model.perform(.createBranch("feature/ui-check"), success: "已创建并切换分支")
        model.open(at: root.deletingLastPathComponent())
        model.perform(.createBranch("should-not-run"), success: "unexpected")
        wait(model)
        precondition(model.snapshot?.branch == "feature/ui-check" && model.snapshot?.localBranches.contains("should-not-run") == false)
        precondition(FinderRightService.jobs.waitUntilIdle(timeout: 2))
        print("✓ Git 界面操作：目录暂存、全仓库提交预览、失败保留草稿、重载提交与忙时隔离通过")
        model.open(at: root.deletingLastPathComponent())
        wait(model)
        precondition(model.snapshot == nil && model.error != nil && model.comparison == nil, "无仓库时清除旧状态")
        model.cancel()
    }

    private static func wait(_ model: GitStatusModel) {
        let deadline = Date(timeIntervalSinceNow: 15)
        while (model.isLoading || model.isComparing || model.isPerforming) && Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        precondition(!model.isLoading && !model.isComparing && !model.isPerforming, "Git 状态查询超时")
    }
}
