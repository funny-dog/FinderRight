import AppKit
import SwiftUI
import FinderRightKit

@main
struct OperationHistoryChecks {
    static func main() throws {
        // 仅 --render 创建离屏示例图，不读取真实历史、不修改应用偏好、不操作用户文件。
        guard CommandLine.arguments.contains("--render") else { return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 0, minute: 5))!
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
