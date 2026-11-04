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
struct FileComparisonViewChecks {
    static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FinderRight-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("settings-before.json")
        let updated = root.appendingPathComponent("settings-after.json")
        let third = root.appendingPathComponent("third.txt")
        try "{\n  \"name\": \"FinderRight\",\n  \"developerTools\": false,\n  \"preview\": true\n}\n".write(to: original, atomically: true, encoding: .utf8)
        try "{\n  \"name\": \"FinderRight\",\n  \"developerTools\": true,\n  \"preview\": true,\n  \"compareFiles\": true\n}\n".write(to: updated, atomically: true, encoding: .utf8)
        try "third\n".write(to: third, atomically: true, encoding: .utf8)
        let model = FileComparisonModel()
        precondition(!model.hasPair, "未选文件时只显示两个拖入框")
        model.setFile(original, onLeft: true)
        precondition(!model.hasPair, "只有一个文件时仍保留拖入布局")
        model.setFile(updated, onLeft: false)
        precondition(model.hasPair, "选齐后切换为顶部窄栏与下方 diff")
        Thread.sleep(forTimeInterval: 0.1) // 让旧操作完成但回调尚未回到主队列。
        model.setFile(third, onLeft: true)
        waitForResult(model)
        precondition(model.left?.url == third && model.right?.url == updated, "快速替换文件时只能展示最后一次选择")
        precondition(model.result != nil)
        model.setFile(root, onLeft: true)
        waitForResult(model)
        precondition(model.leftError != nil && model.result == nil, "错误输入必须清除旧 diff 并显示错误")
        model.setFiles([original, updated])
        waitForResult(model)
        precondition(model.leftError == nil && model.result?.additions == 3 && model.result?.deletions == 2)
        precondition(FinderRightService.jobs.waitUntilIdle(timeout: 1), "比较任务必须纳入退出等待并完成清理")
        print("✓ 文件比较界面：左右载入、快速替换、错误清理与重新比较通过")

        if let outputDirectory = ProcessInfo.processInfo.environment["FINDERRIGHT_COMPARISON_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            precondition(FileComparisonLayout.contentSize.width <= 600 && FileComparisonLayout.contentSize.height <= 450)
            for (state, previewModel) in [("before", FileComparisonModel()), ("after", model)] {
                for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: FileComparisonLayout.contentSize),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearance)
                    let view = NSHostingView(rootView: FileComparisonView(model: previewModel))
                    window.contentView = view
                    view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
                    precondition(view.fittingSize.width <= FileComparisonLayout.contentSize.width &&
                                 view.fittingSize.height <= FileComparisonLayout.contentSize.height, "内容不能撑大紧凑窗口")
                    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("离屏渲染失败") }
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG 编码失败") }
                    try data.write(to: directory.appendingPathComponent("file-comparison-\(state)-\(name).png"))
                    window.close()
                }
            }
            print("✓ 使用临时样例生成离屏预览，不打开或截取真实 App 窗口")
        }
    }

    private static func waitForResult(_ model: FileComparisonModel) {
        let deadline = Date(timeIntervalSinceNow: 5)
        while model.isLoading && Date() < deadline { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
        precondition(!model.isLoading, "文件比较未及时完成")
    }
}
