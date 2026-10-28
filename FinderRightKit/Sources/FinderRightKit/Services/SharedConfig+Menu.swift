import Foundation

extension SharedConfig {
    // MARK: - Enabled Actions

    /// 每个 action 的开关状态，key 为 action id
    public var enabledActions: [String: Bool] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.enabledActions] as? [String: Bool] ?? [:]
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.enabledActions] = newValue
            save()
        }
    }

    /// 检查指定 action 是否启用（未设置时默认启用，MenuFeatureCatalog.disabledByDefault 中的除外）
    public func isActionEnabled(_ actionId: String) -> Bool {
        return enabledActions[actionId] ?? !MenuFeatureCatalog.disabledByDefault.contains(actionId)
    }

    /// 设置指定 action 的启用状态
    public func setActionEnabled(_ actionId: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var current = enabledActions
        current[actionId] = enabled
        enabledActions = current
    }

    // MARK: - Menu Icon Style

    /// 右键菜单图标风格（默认彩色线条）
    public var menuIconStyle: MenuIconStyle {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let raw = store[Keys.menuIconStyle] as? String,
               let style = MenuIconStyle(storedValue: raw) {
                return style
            }
            return .tinted
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.menuIconStyle] = newValue.rawValue
            save()
        }
    }

    /// 图标风格默认值从「单色线条」改成「彩色线条」：
    /// - **老用户**（升级前就存在配置文件）从没选过样式的，显式落盘旧的默认值「单色线条」，看到的菜单保持不变；
    /// - **新用户**（没有配置文件）不落盘，直接拿到新的默认值。
    ///
    /// 必须用独立的标记位而不是「文件是否存在」判断：新用户首次运行后配置文件可能因改别的设置而生成，
    /// 那时若再按「文件已存在」判断就会把他们的默认样式误钉成单色线条。
    func migrateIconStyleDefaultIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard store[Keys.iconStyleDefaultMigrated] as? Bool != true else { return }

        if FileManager.default.fileExists(atPath: configFileURL.path),
           store[Keys.menuIconStyle] == nil {
            store[Keys.menuIconStyle] = MenuIconStyle.modern.rawValue
        }
        store[Keys.iconStyleDefaultMigrated] = true
        save()
    }

    // MARK: - Copy Path Format

    /// 「复制路径」的格式（默认绝对路径）
    public var copyPathFormat: CopyPathFormat {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let raw = store[Keys.copyPathFormat] as? String, let format = CopyPathFormat(rawValue: raw) {
                return format
            }
            return .absolute
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.copyPathFormat] = newValue.rawValue
            save()
        }
    }

    // MARK: - Copy File Name Format

    /// 「复制文件名」的格式（默认含扩展名）
    public var copyFileNameFormat: CopyFileNameFormat {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let raw = store[Keys.copyFileNameFormat] as? String, let format = CopyFileNameFormat(rawValue: raw) {
                return format
            }
            return .full
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.copyFileNameFormat] = newValue.rawValue
            save()
        }
    }

    // MARK: - Menu Order

    /// 右键菜单功能的顺序（功能 id 列表）。未设置时为空，表示默认顺序；
    /// 读取方用 MenuFeatureCatalog.ordered(by:) 归一化，容忍新增或移除的功能
    public var menuOrder: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.menuOrder] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue.isEmpty {
                store.removeValue(forKey: Keys.menuOrder)
            } else {
                store[Keys.menuOrder] = newValue
            }
            save()
        }
    }

    // MARK: - Copy File Content Max Size

    /// 允许「复制文件内容」的最大文件大小（KB），默认 1024 KB (1 MB)
    public var copyFileContentMaxSizeKB: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            if let saved = store[Keys.copyFileContentMaxSizeKB] as? Int, saved > 0 {
                return saved
            }
            return 1024
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.copyFileContentMaxSizeKB] = max(1, newValue)
            save()
        }
    }

    /// 允许「复制文件内容」的最大字节数
    public var copyFileContentMaxBytes: Int64 {
        Int64(copyFileContentMaxSizeKB) * 1024
    }
}
