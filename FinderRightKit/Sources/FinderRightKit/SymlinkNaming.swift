import Foundation

/// 「创建符号链接」的命名：与访达「制作替身」一样保留完整文件名再加后缀（「报告.pdf 链接」），
/// 不把后缀插进扩展名前，避免链接被当成同类型文件打开。
public enum SymlinkNaming {

    /// 在源项目同一目录下取一个未被占用的链接路径；重名时追加「 1」「 2」……
    /// 不用 UniqueName：它的 fileExists 跟随符号链接，同名的悬空链接会被当成不存在
    public static func linkURL(for source: URL, suffix: String, fileManager: FileManager = .default) -> URL {
        let directory = source.deletingLastPathComponent()
        let base = "\(source.lastPathComponent) \(suffix)"
        var url = directory.appendingPathComponent(base)
        var counter = 1
        while (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
            url = directory.appendingPathComponent("\(base) \(counter)")
            counter += 1
        }
        return url
    }
}
