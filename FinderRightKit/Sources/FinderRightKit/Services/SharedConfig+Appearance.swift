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

public enum AppLanguage {
    /// 按目标设置值（"system" / "zh-Hans" / "en"）解析实际生效的本地化标识。
    /// 跟随系统但拿不到系统偏好语言列表时返回 nil，交由调用方保守重启。
    public static func resolvedLocalization(
        for target: String,
        availableLocalizations: [String],
        systemPreferredLanguages: [String]
    ) -> String? {
        let preferences: [String]
        switch target {
        case "zh-Hans", "en":
            preferences = [target]
        default:
            guard !systemPreferredLanguages.isEmpty else { return nil }
            preferences = systemPreferredLanguages
        }
        return Bundle.preferredLocalizations(
            from: availableLocalizations,
            forPreferences: preferences
        ).first
    }

    /// 切换界面语言后是否需要重启主 App：仅在实际生效语言变化（或无法判定）时返回 true。
    public static func requiresRelaunch(
        currentLocalization: String?,
        target: String,
        availableLocalizations: [String],
        systemPreferredLanguages: [String]
    ) -> Bool {
        guard let current = currentLocalization,
              let next = resolvedLocalization(
                  for: target,
                  availableLocalizations: availableLocalizations,
                  systemPreferredLanguages: systemPreferredLanguages
              )
        else {
            return true
        }
        return current != next
    }
}
