import Foundation

/// 压缩等后台任务在用户目录里创建的隐藏临时目录的登记表（`archive-scratch.json`）。
///
/// 临时目录必须与输出放在同一个卷上（APFS 克隆、原子改名都要求同卷），所以只能建在用户目录里。
/// 正常流程由任务自己 remove；App 被强退或崩溃时，下次启动由 sweep 按登记清理，
/// 不让包含完整副本的隐藏目录永久留在用户文件夹里。
public struct ScratchDirectoryRegistry {

    public static let fileName = "archive-scratch.json"
    public static let namePrefix = ".finderright-scratch-"

    public let registryDirectory: URL

    public init(registryDirectory: URL = IPCBridge.rootDirectory) {
        self.registryDirectory = registryDirectory
    }

    var registryURL: URL { registryDirectory.appendingPathComponent(Self.fileName) }

    /// 在 parent 下创建并登记一个新的临时目录。先登记再创建：反过来的话，创建后、登记前崩溃会留下无人认领的目录
    public func makeScratchDirectory(in parent: URL) throws -> URL {
        let scratch = parent.appendingPathComponent(Self.namePrefix + UUID().uuidString, isDirectory: true)
        try save(load() + [scratch.path])
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        } catch {
            try? save(load().filter { $0 != scratch.path })
            throw error
        }
        return scratch
    }

    /// 删除临时目录并注销登记
    public func remove(_ scratch: URL) {
        try? FileManager.default.removeItem(at: scratch)
        try? save(load().filter { $0 != scratch.path })
    }

    /// 启动时调用：删除登记中仍存在的临时目录并清空登记，返回删除数量
    @discardableResult
    public func sweep() -> Int {
        var removed = 0
        for path in load() where Self.isOwnedScratch(path) {
            if (try? FileManager.default.removeItem(atPath: path)) != nil {
                removed += 1
            }
        }
        try? FileManager.default.removeItem(at: registryURL)
        return removed
    }

    /// 登记文件可被同用户进程篡改，而主 App 带「完全磁盘访问」：只删名字带本前缀、
    /// 且是真实目录（attributesOfItem 不跟随符号链接，链接会报 typeSymbolicLink）的路径
    static func isOwnedScratch(_ path: String) -> Bool {
        guard (path as NSString).lastPathComponent.hasPrefix(namePrefix),
              let type = try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeDirectory
    }

    private func load() -> [String] {
        guard let data = try? Data(contentsOf: registryURL),
              let paths = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }
        return paths
    }

    private func save(_ paths: [String]) throws {
        guard !paths.isEmpty else {
            try? FileManager.default.removeItem(at: registryURL)
            return
        }
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: paths).write(to: registryURL, options: .atomic)
    }
}
