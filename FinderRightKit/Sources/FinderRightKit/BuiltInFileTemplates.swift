import Foundation

/// Finder 菜单与 Services 共用的内置文本模板，顺序对应原菜单的 0–9 tag。
public enum BuiltInFileTemplates {
    public static let text: [FileTemplate] = [
        FileTemplate(id: "txt", name: "文本文件 (.txt)", fileExtension: "txt", content: ""),
        FileTemplate(id: "md", name: "Markdown (.md)", fileExtension: "md", content: "# Untitled\n\n"),
        FileTemplate(id: "html", name: "HTML (.html)", fileExtension: "html", content: "<!DOCTYPE html>\n<html lang=\"en\">\n<head><meta charset=\"UTF-8\"><title>Untitled</title></head>\n<body>\n</body>\n</html>\n"),
        FileTemplate(id: "py", name: "Python (.py)", fileExtension: "py", content: "#!/usr/bin/env python3\n# -*- coding: utf-8 -*-\n\n"),
        FileTemplate(id: "sh", name: "Shell (.sh)", fileExtension: "sh", content: "#!/bin/bash\n\n"),
        FileTemplate(id: "json", name: "JSON (.json)", fileExtension: "json", content: "{\n    \n}\n"),
        FileTemplate(id: "xml", name: "XML (.xml)", fileExtension: "xml", content: "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<root>\n</root>\n"),
        FileTemplate(id: "csv", name: "CSV (.csv)", fileExtension: "csv", content: ""),
        FileTemplate(id: "swift", name: "Swift (.swift)", fileExtension: "swift", content: "import Foundation\n\n"),
        FileTemplate(id: "js", name: "JavaScript (.js)", fileExtension: "js", content: "\"use strict\";\n\n"),
    ]
}
