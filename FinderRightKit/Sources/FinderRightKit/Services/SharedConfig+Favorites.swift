import Foundation

extension SharedConfig {
    // MARK: - Favorite Directories

    /// 常用目录（绝对路径，按设置里的顺序），用于右键「移动到 / 复制到」
    public var favoriteDirectories: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.favoriteDirectories] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.favoriteDirectories] = newValue
            save()
        }
    }

    /// 常用目录按最近使用排序（默认开启）；关闭时按设置里拖动排好的顺序
    public var favoriteSortByRecent: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.favoriteSortByRecent] as? Bool ?? true
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.favoriteSortByRecent] = newValue
            save()
        }
    }

    /// 每个常用目录最近一次被「移动到 / 复制到」使用的时间（timeIntervalSince1970）
    public var favoriteLastUsed: [String: Double] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.favoriteLastUsed] as? [String: Double] ?? [:]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.favoriteLastUsed] = newValue
            save()
        }
    }

    /// 记下一次使用；顺手丢掉已不在列表里的目录，避免记录无限增长
    public func markFavoriteUsed(_ path: String, at date: Date = Date()) {
        let known = Set(favoriteDirectories)
        var updated = favoriteLastUsed.filter { known.contains($0.key) }
        updated[path] = date.timeIntervalSince1970
        favoriteLastUsed = updated
    }

    /// 右键菜单、服务菜单与设置页共用的显示顺序
    public var orderedFavoriteDirectories: [String] {
        FavoriteDirectories.ordered(favoriteDirectories, lastUsed: favoriteLastUsed, byRecent: favoriteSortByRecent)
    }
}
