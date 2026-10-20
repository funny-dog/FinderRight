import Foundation

/// 新建文件子菜单中的条目（统一内置文本、Office 模板与自定义模板）
public struct NewFileTemplateItem: Identifiable, Equatable {
    public enum Kind: Equatable {
        case builtInText(content: String)
        case office(OfficeTemplate)
        case custom(content: String)
    }

    public let id: String
    public var name: String
    public var fileExtension: String
    public var systemImage: String
    public var tint: MenuTint
    public var kind: Kind

    public var isCustom: Bool {
        if case .custom = kind { return true }
        return false
    }

    public var isOffice: Bool {
        if case .office = kind { return true }
        return false
    }

    public var content: String {
        switch kind {
        case .builtInText(let c), .custom(let c):
            return c
        case .office:
            return ""
        }
    }

    public init(
        id: String,
        name: String,
        fileExtension: String,
        systemImage: String,
        tint: MenuTint,
        kind: Kind
    ) {
        self.id = id
        self.name = name
        self.fileExtension = fileExtension
        self.systemImage = systemImage
        self.tint = tint
        self.kind = kind
    }
}

/// 新建文件模板目录管理：统一内置与自定义模板的排序与解析
public enum NewFileTemplateCatalog {
    /// 10 种内置文本模板与 3 种 Office 模板的标准列表
    public static let builtInItems: [NewFileTemplateItem] = [
        NewFileTemplateItem(id: "txt", name: "文本文件 (.txt)", fileExtension: "txt", systemImage: "doc.plaintext", tint: .gray, kind: .builtInText(content: "")),
        NewFileTemplateItem(id: "md", name: "Markdown (.md)", fileExtension: "md", systemImage: "number", tint: .indigo, kind: .builtInText(content: "# Untitled\n\n")),
        NewFileTemplateItem(id: "html", name: "HTML (.html)", fileExtension: "html", systemImage: "chevron.left.forwardslash.chevron.right", tint: .orange, kind: .builtInText(content: "<!DOCTYPE html>\n<html lang=\"en\">\n<head><meta charset=\"UTF-8\"><title>Untitled</title></head>\n<body>\n</body>\n</html>\n")),
        NewFileTemplateItem(id: "py", name: "Python (.py)", fileExtension: "py", systemImage: "p.square", tint: .blue, kind: .builtInText(content: "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\n\n")),
        NewFileTemplateItem(id: "sh", name: "Shell (.sh)", fileExtension: "sh", systemImage: "dollarsign.square", tint: .graphite, kind: .builtInText(content: "#!/bin/bash\n\n")),
        NewFileTemplateItem(id: "json", name: "JSON (.json)", fileExtension: "json", systemImage: "curlybraces", tint: .yellow, kind: .builtInText(content: "{\n    \n}\n")),
        NewFileTemplateItem(id: "xml", name: "XML (.xml)", fileExtension: "xml", systemImage: "doc.text", tint: .brown, kind: .builtInText(content: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n</root>\n")),
        NewFileTemplateItem(id: "csv", name: "CSV (.csv)", fileExtension: "csv", systemImage: "tablecells", tint: .green, kind: .builtInText(content: "")),
        NewFileTemplateItem(id: "swift", name: "Swift (.swift)", fileExtension: "swift", systemImage: "swift", tint: .red, kind: .builtInText(content: "import Foundation\n\n")),
        NewFileTemplateItem(id: "js", name: "JavaScript (.js)", fileExtension: "js", systemImage: "j.square", tint: .yellow, kind: .builtInText(content: "\"use strict\";\n\n")),
        NewFileTemplateItem(id: "docx", name: OfficeTemplate.docx.titleKey, fileExtension: "docx", systemImage: "doc.richtext", tint: .blue, kind: .office(.docx)),
        NewFileTemplateItem(id: "xlsx", name: OfficeTemplate.xlsx.titleKey, fileExtension: "xlsx", systemImage: "tablecells", tint: .green, kind: .office(.xlsx)),
        NewFileTemplateItem(id: "pptx", name: OfficeTemplate.pptx.titleKey, fileExtension: "pptx", systemImage: "play.rectangle", tint: .orange, kind: .office(.pptx)),
    ]

    /// 默认排序 ID
    public static let defaultOrder: [String] = builtInItems.map(\.id)

    /// 将 FileTemplate 转换为 NewFileTemplateItem
    public static func makeCustomItem(from template: FileTemplate) -> NewFileTemplateItem {
        let displayName = template.name.isEmpty ? ".\(template.fileExtension)" : template.name
        return NewFileTemplateItem(
            id: template.id,
            name: displayName,
            fileExtension: template.fileExtension,
            systemImage: "doc",
            tint: .gray,
            kind: .custom(content: template.content)
        )
    }

    /// 根据用户保存的 order 和自定义模板列表解析出有序项目列表。
    /// - order: 用户定制的顺序 id 列表；若为空则返回默认内置 + 自定义列表。
    /// - customTemplates: 当前配置的自定义模板列表。
    public static func resolvedTemplates(
        order: [String],
        customTemplates: [FileTemplate]
    ) -> [NewFileTemplateItem] {
        let customItems = customTemplates.map { makeCustomItem(from: $0) }
        let allItems = builtInItems + customItems
        guard !order.isEmpty else {
            return allItems
        }

        var itemMap: [String: NewFileTemplateItem] = [:]
        for item in allItems {
            itemMap[item.id] = item
        }

        var result: [NewFileTemplateItem] = []
        var seen = Set<String>()

        for id in order {
            if let item = itemMap[id], !seen.contains(id) {
                result.append(item)
                seen.insert(id)
            }
        }

        // 追加未在 order 中列出的新项（保持默认内置与自定义添加的原有相对顺序）
        for item in allItems where !seen.contains(item.id) {
            result.append(item)
            seen.insert(item.id)
        }

        return result
    }
}
