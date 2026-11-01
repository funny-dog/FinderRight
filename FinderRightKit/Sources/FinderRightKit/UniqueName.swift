import Foundation

/// 在目录中为新文件挑选不冲突的名字：`base.ext`，已存在则依次尝试 `base 1.ext`、`base 2.ext`…
/// 新建文件与粘贴时的同名处理共用这一规则。
public enum UniqueName {

    /// 生成第 counter 次尝试的文件名（counter 从 0 开始，0 为原名，1 为 name 1.ext…）
    public static func candidateName(baseName: String, ext: String, counter: Int) -> String {
        if counter == 0 {
            return ext.isEmpty ? baseName : "\(baseName).\(ext)"
        } else {
            return ext.isEmpty ? "\(baseName) \(counter)" : "\(baseName) \(counter).\(ext)"
        }
    }

    /// 检查指定路径的目录项（文件、目录、套接字或符号链接，含悬空符号链接）是否存在。
    public static func itemExists(atPath path: String, fileManager: FileManager = .default) -> Bool {
        var statBuf = stat()
        if lstat(path, &statBuf) == 0 {
            return true
        }
        return (try? fileManager.attributesOfItem(atPath: path)) != nil
    }

    public static func fileURL(baseName: String, ext: String, in directory: URL,
                               fileManager: FileManager = .default) -> URL {
        var counter = 0
        var name = candidateName(baseName: baseName, ext: ext, counter: counter)
        var url = directory.appendingPathComponent(name)
        while itemExists(atPath: url.path, fileManager: fileManager) {
            counter += 1
            name = candidateName(baseName: baseName, ext: ext, counter: counter)
            url = directory.appendingPathComponent(name)
        }
        return url
    }
}
