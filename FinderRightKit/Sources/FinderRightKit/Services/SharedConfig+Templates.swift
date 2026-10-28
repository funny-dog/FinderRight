import Foundation

extension SharedConfig {
    // MARK: - Custom File Templates

    /// 自定义文件模板列表
    public var customFileTemplates: [FileTemplate] {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let data = store[Keys.customFileTemplates] as? Data else { return [] }
            return (try? JSONDecoder().decode([FileTemplate].self, from: data)) ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if let data = try? JSONEncoder().encode(newValue) {
                store[Keys.customFileTemplates] = data
                save()
            }
        }
    }

    /// 添加自定义文件模板
    public func addFileTemplate(_ template: FileTemplate) {
        lock.lock()
        defer { lock.unlock() }
        var templates = customFileTemplates
        templates.append(template)
        customFileTemplates = templates
    }

    /// 更新已存在的自定义文件模板
    public func updateFileTemplate(_ template: FileTemplate) {
        lock.lock()
        defer { lock.unlock() }
        var templates = customFileTemplates
        if let idx = templates.firstIndex(where: { $0.id == template.id }) {
            templates[idx] = template
            customFileTemplates = templates
        }
    }

    /// 删除自定义文件模板
    public func removeFileTemplate(withId id: String) {
        lock.lock()
        defer { lock.unlock() }
        var templates = customFileTemplates
        templates.removeAll { $0.id == id }
        customFileTemplates = templates

        if newFileOrder.contains(id) {
            newFileOrder = newFileOrder.filter { $0 != id }
        }
        if hiddenNewFileTemplates.contains(id) {
            var hidden = hiddenNewFileTemplates
            hidden.remove(id)
            hiddenNewFileTemplates = hidden
        }
    }

    // MARK: - New File Order

    /// 新建文件子菜单项顺序（文件模板 id 列表）。未设置或为空时表示默认顺序
    public var newFileOrder: [String] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return store[Keys.newFileOrder] as? [String] ?? []
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue.isEmpty {
                store.removeValue(forKey: Keys.newFileOrder)
            } else {
                store[Keys.newFileOrder] = newValue
            }
            save()
        }
    }

    // MARK: - Hidden New File Templates

    /// 在新建文件子菜单中隐藏的文件模板 id 集合
    public var hiddenNewFileTemplates: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Set(store[Keys.hiddenNewFileTemplates] as? [String] ?? [])
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue.isEmpty {
                store.removeValue(forKey: Keys.hiddenNewFileTemplates)
            } else {
                store[Keys.hiddenNewFileTemplates] = newValue.sorted()
            }
            save()
        }
    }

    /// 检查指定模板是否启用
    public func isNewFileTemplateEnabled(_ id: String) -> Bool {
        return !hiddenNewFileTemplates.contains(id)
    }

    /// 设置指定模板的启用状态
    public func setNewFileTemplateEnabled(_ id: String, enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var hidden = hiddenNewFileTemplates
        if enabled {
            hidden.remove(id)
        } else {
            hidden.insert(id)
        }
        hiddenNewFileTemplates = hidden
    }

    // MARK: - Removed Built-in New File Templates

    /// 从设置的「文件模板」列表里移除的内置类型 id（自定义模板直接删除，不进这里）。
    /// 移除时同时记入 hiddenNewFileTemplates，访达菜单与服务只看隐藏集合，不必认识这个集合
    public var removedNewFileTemplates: Set<String> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return Set(store[Keys.removedNewFileTemplates] as? [String] ?? [])
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            if newValue.isEmpty {
                store.removeValue(forKey: Keys.removedNewFileTemplates)
            } else {
                store[Keys.removedNewFileTemplates] = newValue.sorted()
            }
            save()
        }
    }

    /// 移除内置类型：不再列出，也不出现在菜单中。不是内置类型的 id 忽略
    public func removeBuiltInNewFileTemplate(_ id: String) {
        guard NewFileTemplateCatalog.defaultOrder.contains(id) else { return }
        lock.lock()
        defer { lock.unlock() }
        removedNewFileTemplates.insert(id)
        setNewFileTemplateEnabled(id, enabled: false)
    }

    /// 恢复移除的内置类型，恢复后即为启用状态
    public func restoreBuiltInNewFileTemplate(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        removedNewFileTemplates.remove(id)
        setNewFileTemplateEnabled(id, enabled: true)
    }
}
