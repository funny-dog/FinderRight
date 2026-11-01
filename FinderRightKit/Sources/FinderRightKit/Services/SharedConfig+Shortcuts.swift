import Foundation

extension SharedConfig {
    // MARK: - Shortcuts

    /// 仅由用户主动开启，不改变升级前快捷键的作用范围。
    public var globalOpenPathShortcut: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.globalOpenPathShortcut] as? Bool ?? false
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.globalOpenPathShortcut] = newValue
            save()
        }
    }

    /// 菜单项快捷键，key 为 action ID（如 "shortcut.cut"）
    public var shortcuts: [String: ActionShortcut] {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = store[Keys.shortcuts] as? Data else { return [:] }
            return (try? JSONDecoder().decode([String: ActionShortcut].self, from: data)) ?? [:]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) {
                store[Keys.shortcuts] = data
                save()
            }
        }
    }

    /// 获取指定 action 的快捷键
    public func shortcut(forActionId id: String) -> ActionShortcut? {
        lock.lock()
        defer { lock.unlock() }
        return shortcuts[id]
    }

    /// 设置或清除指定 action 的快捷键
    public func setShortcut(_ shortcut: ActionShortcut?, forActionId id: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = shortcuts
        if let s = shortcut { current[id] = s } else { current.removeValue(forKey: id) }
        shortcuts = current
    }
}
