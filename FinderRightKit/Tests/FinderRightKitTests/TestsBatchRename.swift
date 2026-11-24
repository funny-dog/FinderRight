import Foundation
import FinderRightKit

// 批量重命名
enum BatchRenameTests {
    static func run() {
        runTest("批量重命名：替换、前后缀、序号按规则生成新名称且保留扩展名") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let urls = ["a2.txt", "a10.txt"].map { dir.appendingPathComponent($0) }
            for url in urls { try Data().write(to: url) }
            func names(_ rule: BatchRenameRule) -> [String] { BatchRename.plan(items: urls, rule: rule).map(\.newName) }
            try assertEqual(names(.replace(find: "a", with: "b", regex: false)), ["b2.txt", "b10.txt"])
            try assertEqual(names(.replace(find: "(\\d+)", with: "[$1]", regex: true)), ["a[2].txt", "a[10].txt"])
            try assertEqual(names(.affix(prefix: "x-", suffix: "-y")), ["x-a2-y.txt", "x-a10-y.txt"])
            try assertEqual(names(.sequence(text: "p", start: 1, digits: 3)), ["p001.txt", "p002.txt"])
        }

        runTest("批量重命名：重名、已存在与非法名称标出问题且不可执行") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let urls = ["a.txt", "b.txt", "keep.txt"].map { dir.appendingPathComponent($0) }
            for url in urls { try Data().write(to: url) }
            let same = BatchRename.plan(items: Array(urls.prefix(2)), rule: .sequence(text: "", start: 1, digits: 0))
            try assertTrue(same.allSatisfy { $0.problem == nil })
            let dup = BatchRename.plan(items: Array(urls.prefix(2)), rule: .replace(find: "[ab]", with: "z", regex: true))
            try assertTrue(dup.allSatisfy { $0.problem == .duplicate && !$0.isReady })
            let exists = BatchRename.plan(items: [urls[0]], rule: .replace(find: "a", with: "keep", regex: false))
            try assertEqual(exists[0].problem, .exists)
            let invalid = BatchRename.plan(items: [urls[0]], rule: .replace(find: "a", with: "/", regex: false))
            try assertEqual(invalid[0].problem, .invalidName)
        }

        runTest("批量重命名：首尾相接的改名可完成，结果可逐项还原") {
            let dir = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let a = dir.appendingPathComponent("1.txt"), b = dir.appendingPathComponent("2.txt")
            try Data("a".utf8).write(to: a)
            try Data("b".utf8).write(to: b)
            let plan = BatchRename.plan(items: [a, b], rule: .sequence(text: "", start: 2, digits: 0))
            let result = BatchRename.apply(plan)
            try assertTrue(result.failures.isEmpty)
            try assertEqual(try String(contentsOf: dir.appendingPathComponent("2.txt")), "a")
            try assertEqual(try String(contentsOf: dir.appendingPathComponent("3.txt")), "b")
        }
    }
}
