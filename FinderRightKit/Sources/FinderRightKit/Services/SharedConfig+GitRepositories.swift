import Foundation

extension SharedConfig {
    /// 最近打开过的 Git 仓库路径列表（按最近使用排序，最多保留 30 个）
    public var recentGitRepositories: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.recentGitRepositories] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.recentGitRepositories] = newValue
            save()
        }
    }

    /// 记录最近访问的 Git 仓库
    public func markGitRepositoryUsed(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        var list = store[Keys.recentGitRepositories] as? [String] ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        if list.count > 30 {
            list = Array(list.prefix(30))
        }
        store[Keys.recentGitRepositories] = list
        save()
    }
}
