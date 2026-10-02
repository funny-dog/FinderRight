import Foundation

/// 在目录中为新文件挑选不冲突的名字：`base.ext`，已存在则依次尝试 `base 1.ext`、`base 2.ext`…
/// 新建文件与粘贴时的同名处理共用这一规则。
public enum UniqueName {

    public static func fileURL(baseName: String, ext: String, in directory: URL,
                               fileManager: FileManager = .default) -> URL {
        let name = ext.isEmpty ? baseName : "\(baseName).\(ext)"
        var url = directory.appendingPathComponent(name)
        var counter = 1
        while fileManager.fileExists(atPath: url.path) {
            let numbered = ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
            url = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return url
    }
}
