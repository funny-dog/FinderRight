import Foundation

/// 批量重命名规则。只改主文件名，扩展名保持不变（文件夹与文件包整体视为主文件名）。
public enum BatchRenameRule: Equatable {
    /// 查找并替换；regex 为 true 时 `with` 支持 `$1` 捕获组
    case replace(find: String, with: String, regex: Bool)
    case affix(prefix: String, suffix: String)
    /// 「文本 + 序号」，序号按名称顺序从 start 起，不足 digits 位补零
    case sequence(text: String, start: Int, digits: Int)
    /// 把修改日期按 format 写进名称的开头或结尾，与原名用空格隔开
    case date(format: String, atStart: Bool)

    /// 正则不合法时规则无法生效，供界面提示
    public var isInvalid: Bool {
        if case .replace(let find, _, true) = self, !find.isEmpty {
            return (try? NSRegularExpression(pattern: find)) == nil
        }
        return false
    }
}

public struct BatchRenameEntry: Equatable {
    public enum Problem: Equatable {
        /// 新名称为空、含路径分隔符或控制字符，或过长
        case invalidName
        /// 与本批其他项的新名称相同（不区分大小写）
        case duplicate
        /// 目标位置已有同名项目（不属于本批）
        case exists
    }

    public let source: URL
    public let newName: String
    public let problem: Problem?

    public var isChanged: Bool { newName != source.lastPathComponent }
    public var isReady: Bool { problem == nil && isChanged }
}

public struct BatchRenameResult: Equatable {
    public struct Pair: Equatable {
        public let from: URL
        public let to: URL
    }

    public init() {}

    public var renamed: [Pair] = []
    /// 未能改名的项：原文件名与原因
    public var failures: [(name: String, reason: String)] = []

    public static func == (lhs: BatchRenameResult, rhs: BatchRenameResult) -> Bool {
        lhs.renamed == rhs.renamed
            && lhs.failures.map(\.name) == rhs.failures.map(\.name)
            && lhs.failures.map(\.reason) == rhs.failures.map(\.reason)
    }
}

public enum BatchRename {

    /// 按规则算出每一项的新名称并标出冲突。结果按名称的访达式顺序排列，序号规则据此编号
    public static func plan(items: [URL], rule: BatchRenameRule, fileManager: FileManager = .default) -> [BatchRenameEntry] {
        let sorted = items.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let regex: NSRegularExpression? = {
            if case .replace(let find, _, true) = rule, !find.isEmpty { return try? NSRegularExpression(pattern: find) }
            return nil
        }()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if case .date(let format, _) = rule { formatter.dateFormat = format }

        let names: [String] = sorted.enumerated().map { index, url in
            let (base, ext) = split(url)
            let newBase: String
            switch rule {
            case .replace(let find, let replacement, let isRegex):
                if find.isEmpty {
                    newBase = base
                } else if isRegex {
                    if let regex {
                        newBase = regex.stringByReplacingMatches(
                            in: base, range: NSRange(base.startIndex..., in: base), withTemplate: replacement)
                    } else {
                        newBase = base
                    }
                } else {
                    newBase = base.replacingOccurrences(of: find, with: replacement)
                }
            case .affix(let prefix, let suffix):
                newBase = prefix + base + suffix
            case .sequence(let text, let start, let digits):
                let number = String(start + index)
                newBase = text + String(repeating: "0", count: max(0, digits - number.count)) + number
            case .date(let format, let atStart):
                if !format.isEmpty,
                   let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
                    let stamp = formatter.string(from: date)
                    newBase = atStart ? "\(stamp) \(base)" : "\(base) \(stamp)"
                } else {
                    newBase = base
                }
            }
            return ext.isEmpty ? newBase : "\(newBase).\(ext)"
        }

        var counts: [String: Int] = [:]
        for name in names { counts[name.lowercased(), default: 0] += 1 }
        let sourcePaths = Set(sorted.map { $0.path.lowercased() })

        return zip(sorted, names).map { url, name in
            var problem: BatchRenameEntry.Problem?
            if name != url.lastPathComponent {
                let (base, ext) = split(name: name)
                let target = url.deletingLastPathComponent().appendingPathComponent(name)
                if !SafeFileName.isValid(baseName: base, ext: ext) {
                    problem = .invalidName
                } else if counts[name.lowercased(), default: 0] > 1 {
                    problem = .duplicate
                } else if !sourcePaths.contains(target.path.lowercased()),
                          (try? fileManager.attributesOfItem(atPath: target.path)) != nil {
                    problem = .exists
                }
            }
            return BatchRenameEntry(source: url, newName: name, problem: problem)
        }
    }

    /// 执行改名。先全部改成临时名再改成目标名，因此 a→b、b→c 这类首尾相接的改名也能完成；
    /// 目标名被抢占时不覆盖（沿用 ExclusiveRename 的追加编号），中途失败的项还原为原名
    public static func apply(_ entries: [BatchRenameEntry], fileManager: FileManager = .default) -> BatchRenameResult {
        var result = BatchRenameResult()
        var staged: [(entry: BatchRenameEntry, temp: URL)] = []
        for entry in entries where entry.isReady {
            let directory = entry.source.deletingLastPathComponent()
            let temp = directory.appendingPathComponent(".finderright-rename-\(UUID().uuidString)")
            do {
                try fileManager.moveItem(at: entry.source, to: temp)
                staged.append((entry, temp))
            } catch {
                result.failures.append((entry.source.lastPathComponent, error.localizedDescription))
            }
        }
        for (entry, temp) in staged {
            let directory = entry.source.deletingLastPathComponent()
            let (base, ext) = split(name: entry.newName)
            do {
                let final = try ExclusiveRename.move(temp, into: directory) { n in
                    n == 0 ? entry.newName : (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                }
                result.renamed.append(.init(from: entry.source, to: final))
            } catch {
                try? fileManager.moveItem(at: temp, to: entry.source)
                result.failures.append((entry.source.lastPathComponent, error.localizedDescription))
            }
        }
        return result
    }

    private static func split(_ url: URL) -> (base: String, ext: String) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            return (url.lastPathComponent, "")
        }
        return split(name: url.lastPathComponent)
    }

    private static func split(name: String) -> (base: String, ext: String) {
        let ns = name as NSString
        return (ns.deletingPathExtension, ns.pathExtension)
    }
}
