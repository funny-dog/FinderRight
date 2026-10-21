import AppKit
import SwiftUI
import FinderRightKit

@main
struct OperationHistoryChecks {
    static func main() throws {
        let ok = OperationRecord(kind: .compress, subject: "资料")
        let cancelled = OperationRecord(kind: .decompress, subject: "资料.zip", cancelled: true)
        let failed = OperationRecord(kind: .decompress, subject: "资料.zip", failure: "unsupported compression method (exit 1)")
        let partial = OperationRecord(kind: .move, subject: "3 个项目", failure: "Permission denied",
                                      results: [URL(fileURLWithPath: "/tmp/completed.txt")])
        let destination = URL(fileURLWithPath: "/tmp/目标文件夹")
        let results = [destination.appendingPathComponent("a.txt"), destination.appendingPathComponent("b.txt")]
        for (kind, action) in [(OperationRecord.Kind.move, "移动"), (.copy, "复制")] {
            let completed = OperationRecord(kind: kind, subject: "3 个项目", results: results, location: destination)
            precondition(OperationHistoryPresentation.transferSuccessMessage(completed) == "已\(action) 2 项到“目标文件夹”")
            precondition(OperationHistoryPresentation.transferSuccessMessage(
                OperationRecord(kind: kind, subject: "a", results: results, cancelled: true)) == nil)
            precondition(OperationHistoryPresentation.transferSuccessMessage(
                OperationRecord(kind: kind, subject: "a")) == nil)
        }
        for record in [ok, cancelled, failed, partial,
                       OperationRecord(kind: .paste, subject: "a", results: results)] {
            precondition(OperationHistoryPresentation.transferSuccessMessage(record) == nil)
        }
        precondition(OperationHistoryPresentation.transferSuccessMessage(
            OperationRecord(kind: .copy, subject: "a", results: [results[0]])) == "已复制 1 项到“目标文件夹”")
        precondition(OperationHistoryPresentation.status(ok) == "已完成")
        precondition(OperationHistoryPresentation.status(cancelled) == "已取消")
        precondition(OperationHistoryPresentation.status(failed) == "未完成")
        precondition(OperationHistoryPresentation.status(partial) == "部分完成")
        precondition(OperationHistoryPresentation.failureSummary(partial).contains("权限"))
        precondition(!OperationHistoryPresentation.failureSummary(failed).contains("exit"))
        precondition(OperationHistoryPresentation.failureSummary(failed).contains("格式"))
        for (reason, expected) in [("No space left on device", "空间"), ("Incorrect password", "密码"),
                                   ("No such file", "找不到"), ("File exists", "同名")] {
            precondition(OperationHistoryPresentation.failureSummary(
                OperationRecord(kind: .copy, subject: "a", failure: reason)).contains(expected))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 5))!
        precondition(OperationHistoryPresentation.dayTitle(now, now: now, calendar: calendar) == "今天")
        precondition(OperationHistoryPresentation.dayTitle(now.addingTimeInterval(-600), now: now, calendar: calendar) == "昨天")
        let groups = OperationHistoryPresentation.dayGroups([
            OperationRecord(kind: .copy, subject: "a", date: now.addingTimeInterval(60)),
            OperationRecord(kind: .copy, subject: "b", date: now.addingTimeInterval(-600)),
            OperationRecord(kind: .copy, subject: "c", date: now),
        ], calendar: calendar)
        precondition(groups.map { $0.records.map(\.subject) } == [["a", "c"], ["b"]], "按天分组：组按日期倒序，组内保持原顺序")
        precondition([ok, cancelled, failed, partial].map(OperationHistoryPresentation.Outcome.init)
                     == [.completed, .cancelled, .failed, .partial])
        print("✓ 历史状态、用户可读失败原因及跨午夜日期分组检查通过")

        let searchRecord = OperationRecord(kind: .copy, subject: "3 个项目",
                                           results: [URL(fileURLWithPath: "/tmp/Projects/Résumé.PDF")],
                                           location: URL(fileURLWithPath: "/tmp/Projects"))
        let candidates = [ok, cancelled, failed, partial, searchRecord]
        precondition(OperationHistoryFilter().apply(to: candidates) == candidates)
        precondition(OperationHistoryFilter(searchText: " \n ").apply(to: candidates) == candidates)
        precondition(!OperationHistoryFilter(searchText: " \n ").isActive)
        precondition(OperationHistoryFilter(searchText: "资料").apply(to: candidates) == [ok, cancelled, failed])
        precondition(OperationHistoryFilter(searchText: "复制 resume projects").apply(to: candidates) == [searchRecord])
        precondition(OperationHistoryFilter(searchText: "résumé.pdf").apply(to: candidates) == [searchRecord])
        precondition(OperationHistoryFilter(searchText: "权限").apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(searchText: "unsupported").apply(to: candidates) == [failed])
        precondition(OperationHistoryFilter(searchText: "move").apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(kind: .move, status: .partial).apply(to: candidates) == [partial])
        precondition(OperationHistoryFilter(kind: .compress, status: .failed).apply(to: candidates).isEmpty)
        for (status, expected) in [(OperationHistoryFilter.Status.completed, [ok, searchRecord]),
                                   (.partial, [partial]), (.failed, [failed]), (.cancelled, [cancelled])] {
            precondition(OperationHistoryFilter(status: status).apply(to: candidates) == expected)
        }
        let counts = OperationHistoryFilter(status: .failed).statusCounts(in: candidates)
        precondition(counts == [.all: 5, .completed: 2, .partial: 1, .failed: 1, .cancelled: 1], "状态数量不受当前状态筛选影响")
        precondition(OperationHistoryFilter(kind: .decompress).statusCounts(in: candidates) == [.all: 2, .failed: 1, .cancelled: 1])
        let memoryStore = RecentOperations()
        candidates.reversed().forEach { memoryStore.record($0) }
        let before = memoryStore.records
        _ = OperationHistoryFilter(searchText: "不存在的文件", kind: .move, status: .failed).apply(to: before)
        precondition(memoryStore.records == before, "搜索和筛选不得删除或修改历史")
        print("✓ 搜索覆盖名称、操作、结果文件、位置、失败说明；组合筛选与空结果检查通过")

        // 仅 --render 创建离屏示例图，不读取真实历史、不修改应用偏好、不操作用户文件。
        guard CommandLine.arguments.contains("--render") else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let store = RecentOperations(capacity: 100)
        let failedID = UUID(), partialID = UUID()
        let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        store.record(OperationRecord(kind: .createFile, subject: "会议纪要.md", date: now.addingTimeInterval(-86400), location: downloads))
        store.record(OperationRecord(id: failedID, kind: .decompress, subject: "设计参考.zip", failure: "unsupported compression method", date: now.addingTimeInterval(-7200), location: downloads))
        store.record(OperationRecord(id: partialID, kind: .move, subject: "3 个项目", failure: "Permission denied", results: [downloads.appendingPathComponent("参考图.png")], date: now.addingTimeInterval(-3600), location: downloads))
        store.record(OperationRecord(kind: .compress, subject: "产品演示素材", results: [downloads.appendingPathComponent("产品演示素材.zip")], date: now, location: downloads))

        let output = URL(fileURLWithPath: "build/operation-history-work", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let expanded: Set<UUID> = [failedID, partialID]
        let scenes: [(String, NSAppearance.Name, Double, OperationHistoryFilter, Set<UUID>)] = [
            ("light", .aqua, 580, OperationHistoryFilter(), []),
            ("dark", .darkAqua, 580, OperationHistoryFilter(), []),
            ("narrow", .aqua, 480, OperationHistoryFilter(), []),
            ("expanded", .aqua, 580, OperationHistoryFilter(), expanded),
            ("expanded-dark", .darkAqua, 480, OperationHistoryFilter(), expanded),
            ("filtered", .aqua, 480, OperationHistoryFilter(searchText: "参考图", kind: .move, status: .partial), []),
            ("no-matches", .darkAqua, 480, OperationHistoryFilter(searchText: "不存在的文件"), []),
        ]
        for (name, appearance, width, filter, expandedIDs) in scenes {
            let hosting = NSHostingView(rootView: OperationHistoryView(store: store, filter: filter, expanded: expandedIDs)
                .frame(width: width, height: 920)
                .background(FRTheme.window))
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: 920)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                preconditionFailure("无法生成离屏示例图")
            }
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let image = bitmap.representation(using: .png, properties: [:])!
            try image.write(to: output.appendingPathComponent("history-\(name).png"))
            precondition(bitmap.pixelsWide >= Int(width))
            print("✓ 离屏示例图：history-\(name).png")
        }
    }
}
