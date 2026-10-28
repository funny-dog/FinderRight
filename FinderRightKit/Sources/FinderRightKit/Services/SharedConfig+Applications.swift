import Foundation

extension SharedConfig {
    // MARK: - Preferred Terminal

    public var followsSystemTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return (store[Keys.preferredTerminal] as? String ?? "").isEmpty
    }

    /// 首选终端应用 bundle identifier
    public var preferredTerminal: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let saved = store[Keys.preferredTerminal] as? String, !saved.isEmpty {
                return saved
            }
            return TerminalCatalog.defaultTerminalBundleIdentifier()
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.preferredTerminal] = newValue
            save()
        }
    }

    /// 右键菜单启用的终端；未配置时只启用已有的默认终端。
    public var selectedTerminals: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let saved = store[Keys.selectedTerminals] as? [String] else {
                return [preferredTerminal]
            }
            return Set(saved)
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.selectedTerminals] = newValue.sorted()
            save()
        }
    }

    /// 默认菜单项随首选终端变化，不将当前系统默认固定保存为某个 bundle id。
    public func resetTerminalMenuToDefault() {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: Keys.selectedTerminals)
        save()
    }

    /// 终端 bundle identifier 的显示顺序；未配置的终端由清单顺序补到末尾。
    public var terminalOrder: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.terminalOrder] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.terminalOrder] = newValue
            save()
        }
    }

    // MARK: - Editors

    /// 编辑器 bundle identifier 的显示顺序。
    public var editorOrder: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.editorOrder] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.editorOrder] = newValue
            save()
        }
    }

    /// 用户选定的默认编辑器 bundle identifier（服务菜单 / 快捷键使用）。
    /// nil 表示跟随系统的纯文本默认打开应用，不保存当时解析出的 bundle identifier。
    public var preferredEditor: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let saved = store[Keys.preferredEditor] as? String, !saved.isEmpty else { return nil }
            return saved
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let newValue, !newValue.isEmpty {
                store[Keys.preferredEditor] = newValue
            } else {
                store.removeValue(forKey: Keys.preferredEditor)
            }
            save()
        }
    }

    /// 用户手动添加的编辑器（预置清单之外的应用），按添加顺序
    public var customEditors: [KnownEditor] {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = store[Keys.customEditors] as? Data else { return [] }
            return (try? JSONDecoder().decode([KnownEditor].self, from: data)) ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) {
                store[Keys.customEditors] = data
                save()
            }
        }
    }

    /// 在右键「打开编辑器」子菜单中隐藏的编辑器 bundle identifier
    public var hiddenEditors: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Set(store[Keys.hiddenEditors] as? [String] ?? [])
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.hiddenEditors] = newValue.sorted()
            save()
        }
    }
}
