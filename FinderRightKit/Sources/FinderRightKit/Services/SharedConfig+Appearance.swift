import Foundation

extension SharedConfig {
    // MARK: - App Language

    /// 界面语言："system"（默认，跟随系统）/ "zh-Hans" / "en"。
    ///
    /// 扩展端在 menu(for:) 里 reload 后读取，运行时即时切换菜单语言；
    /// 主 App 端由设置界面同步写入 AppleLanguages，重启后生效。
    public var appLanguage: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.appLanguage] as? String ?? "system"
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.appLanguage] = newValue
            save()
        }
    }

    // MARK: - Badge Ownership

    /// 自动解决角标冲突（默认开启）：检测到剪切角标的显示权被其他 Finder Sync 扩展占用时，
    /// 由主 App 短暂重启这些扩展以取回。扩展端用来跳过无谓 IPC，主 App 端作为最终裁决。
    public var badgeOwnershipReclaim: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.badgeOwnershipReclaim] as? Bool ?? true
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.badgeOwnershipReclaim] = newValue
            save()
        }
    }

    // MARK: - App Theme

    /// 存储的 appTheme，nil 表示尚未写入
    public var appThemeValue: FRThemeID? {
        lock.lock()
        defer { lock.unlock() }
        if let raw = store[Keys.appTheme] as? String {
            return FRThemeID(rawValue: raw)
        }
        return nil
    }

    /// 界面主题色，默认午夜薄荷
    public var appTheme: FRThemeID {
        get {
            appThemeValue ?? .midnight
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            store[Keys.appTheme] = newValue.rawValue
            save()
        }
    }
}
