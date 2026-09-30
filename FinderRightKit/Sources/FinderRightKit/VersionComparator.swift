import Foundation

public enum VersionComparator {
    /// 比较两个版本号字符串（支持 v 前缀、纯数字点分版本、带 -beta 等后缀）
    public static func compareVersions(_ v1: String, _ v2: String) -> ComparisonResult {
        let clean1 = v1.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let clean2 = v2.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        let parts1 = clean1.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }
        let parts2 = clean2.split(separator: ".").compactMap { Int($0.prefix(while: { $0.isNumber })) }

        let maxCount = max(parts1.count, parts2.count)
        for i in 0..<maxCount {
            let p1 = i < parts1.count ? parts1[i] : 0
            let p2 = i < parts2.count ? parts2[i] : 0
            if p1 < p2 { return .orderedAscending }
            if p1 > p2 { return .orderedDescending }
        }
        return .orderedSame
    }
}
