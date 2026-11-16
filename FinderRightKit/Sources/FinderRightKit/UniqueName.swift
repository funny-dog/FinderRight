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

    /// 拆分冲突重命名与归档命名所用的基名和扩展名：
    /// 普通文件与包目录（如 `.app`）按扩展名拆分；非包普通目录保留完整目录名（避免 `v1.0` 被拆成 `v1 1.0`）。
    public static func splitName(for url: URL, fileManager: FileManager = .default) -> (baseName: String, ext: String) {
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        let isRealDirectory = (attrs?[.type] as? FileAttributeType) == .typeDirectory
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        if isRealDirectory && !isPackage {
            return (url.lastPathComponent, "")
        }
        return (url.deletingPathExtension().lastPathComponent, url.pathExtension)
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
