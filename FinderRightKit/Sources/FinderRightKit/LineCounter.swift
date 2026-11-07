import Foundation

/// 单门语言的代码行数统计结果
public struct LanguageStats: Identifiable, Equatable {
    public var id: String { language }
    public let language: String
    public var files: Int
    public var code: Int
    public var comment: Int
    public var blank: Int
    public var total: Int { code + comment + blank }

    public init(language: String, files: Int = 0, code: Int = 0, comment: Int = 0, blank: Int = 0) {
        self.language = language
        self.files = files
        self.code = code
        self.comment = comment
        self.blank = blank
    }
}

/// 代码行数统计总体汇总
public struct LineCountResult: Equatable {
    public let targetURL: URL
    public let languages: [LanguageStats]
    public let totalFiles: Int
    public let totalCode: Int
    public let totalComment: Int
    public let totalBlank: Int
    public var totalLines: Int { totalCode + totalComment + totalBlank }
    public let durationMs: Double

    public init(
        targetURL: URL,
        languages: [LanguageStats],
        totalFiles: Int,
        totalCode: Int,
        totalComment: Int,
        totalBlank: Int,
        durationMs: Double
    ) {
        self.targetURL = targetURL
        self.languages = languages
        self.totalFiles = totalFiles
        self.totalCode = totalCode
        self.totalComment = totalComment
        self.totalBlank = totalBlank
        self.durationMs = durationMs
    }

    /// 格式化为类似 cloc 的纯文本表格，便于复制分享
    public func formatTable() -> String {
        let separator = "-------------------------------------------------------------------------------"
        let doubleSeparator = "==============================================================================="
        var lines: [String] = []
        lines.append(separator)
        lines.append(String(format: "%-20s %10s %12s %12s %12s", "Language", "Files", "Blank", "Comment", "Code"))
        lines.append(doubleSeparator)
        for stat in languages {
            lines.append(String(format: "%-20s %10d %12d %12d %12d", stat.language, stat.files, stat.blank, stat.comment, stat.code))
        }
        lines.append(separator)
        lines.append(String(format: "%-20s %10d %12d %12d %12d", "SUM:", totalFiles, totalBlank, totalComment, totalCode))
        lines.append(separator)
        lines.append(String(format: "Total lines: %d | Time: %.1fms", totalLines, durationMs))
        return lines.joined(separator: "\n")
    }
}

/// 纯 Swift 代码行数统计引擎
public enum LineCounter {

    /// 统计时跳过的常见依赖和编译产物目录
    public static let defaultIgnoredDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "Pods", "Carthage",
        ".build", "build", "dist", "out", "DerivedData", ".gradle",
        ".idea", ".vscode", "vendor", "__pycache__", ".next", ".nuxt",
        "target", "bin", "obj", ".bundle", "coverage", ".pytest_cache"
    ]

    /// 常见文本文件最大读取上限（10MB），避免遍历误读巨型文件
    public static let maxFileSizeBytes: Int64 = 10 * 1024 * 1024

    struct CommentSpec {
        let linePrefixes: [String]
        let block: (start: String, end: String)?
    }

    private static let slashStarSpec = CommentSpec(linePrefixes: ["//"], block: ("/*", "*/"))
    private static let hashSpec = CommentSpec(linePrefixes: ["#"], block: nil)
    private static let pythonSpec = CommentSpec(linePrefixes: ["#"], block: ("\"\"\"", "\"\"\""))
    private static let dashDashSpec = CommentSpec(linePrefixes: ["--"], block: ("--[[", "]]"))
    private static let xmlSpec = CommentSpec(linePrefixes: [], block: ("<!--", "-->"))
    private static let percentSpec = CommentSpec(linePrefixes: ["%"], block: nil)
    private static let semicolonSpec = CommentSpec(linePrefixes: [";"], block: nil)
    private static let noneSpec = CommentSpec(linePrefixes: [], block: nil)

    private struct LanguageDef {
        let name: String
        let spec: CommentSpec
    }

    private static let extensionMap: [String: LanguageDef] = [
        "swift": LanguageDef(name: "Swift", spec: slashStarSpec),
        "c": LanguageDef(name: "C", spec: slashStarSpec),
        "h": LanguageDef(name: "C/C++ Header", spec: slashStarSpec),
        "cpp": LanguageDef(name: "C++", spec: slashStarSpec),
        "cc": LanguageDef(name: "C++", spec: slashStarSpec),
        "cxx": LanguageDef(name: "C++", spec: slashStarSpec),
        "hpp": LanguageDef(name: "C++", spec: slashStarSpec),
        "m": LanguageDef(name: "Objective-C", spec: slashStarSpec),
        "mm": LanguageDef(name: "Objective-C++", spec: slashStarSpec),
        "js": LanguageDef(name: "JavaScript", spec: slashStarSpec),
        "mjs": LanguageDef(name: "JavaScript", spec: slashStarSpec),
        "cjs": LanguageDef(name: "JavaScript", spec: slashStarSpec),
        "jsx": LanguageDef(name: "JavaScript (JSX)", spec: slashStarSpec),
        "ts": LanguageDef(name: "TypeScript", spec: slashStarSpec),
        "mts": LanguageDef(name: "TypeScript", spec: slashStarSpec),
        "cts": LanguageDef(name: "TypeScript", spec: slashStarSpec),
        "tsx": LanguageDef(name: "TypeScript (TSX)", spec: slashStarSpec),
        "py": LanguageDef(name: "Python", spec: pythonSpec),
        "go": LanguageDef(name: "Go", spec: slashStarSpec),
        "rs": LanguageDef(name: "Rust", spec: slashStarSpec),
        "java": LanguageDef(name: "Java", spec: slashStarSpec),
        "kt": LanguageDef(name: "Kotlin", spec: slashStarSpec),
        "kts": LanguageDef(name: "Kotlin", spec: slashStarSpec),
        "rb": LanguageDef(name: "Ruby", spec: hashSpec),
        "php": LanguageDef(name: "PHP", spec: slashStarSpec),
        "cs": LanguageDef(name: "C#", spec: slashStarSpec),
        "sh": LanguageDef(name: "Shell", spec: hashSpec),
        "bash": LanguageDef(name: "Shell", spec: hashSpec),
        "zsh": LanguageDef(name: "Shell", spec: hashSpec),
        "html": LanguageDef(name: "HTML", spec: xmlSpec),
        "htm": LanguageDef(name: "HTML", spec: xmlSpec),
        "css": LanguageDef(name: "CSS", spec: CommentSpec(linePrefixes: [], block: ("/*", "*/"))),
        "scss": LanguageDef(name: "SCSS", spec: slashStarSpec),
        "sass": LanguageDef(name: "Sass", spec: slashStarSpec),
        "less": LanguageDef(name: "Less", spec: slashStarSpec),
        "json": LanguageDef(name: "JSON", spec: noneSpec),
        "yaml": LanguageDef(name: "YAML", spec: hashSpec),
        "yml": LanguageDef(name: "YAML", spec: hashSpec),
        "toml": LanguageDef(name: "TOML", spec: hashSpec),
        "xml": LanguageDef(name: "XML", spec: xmlSpec),
        "plist": LanguageDef(name: "XML", spec: xmlSpec),
        "md": LanguageDef(name: "Markdown", spec: xmlSpec),
        "markdown": LanguageDef(name: "Markdown", spec: xmlSpec),
        "sql": LanguageDef(name: "SQL", spec: dashDashSpec),
        "vue": LanguageDef(name: "Vue", spec: xmlSpec),
        "dart": LanguageDef(name: "Dart", spec: slashStarSpec),
        "lua": LanguageDef(name: "Lua", spec: dashDashSpec),
        "zig": LanguageDef(name: "Zig", spec: slashStarSpec),
        "scala": LanguageDef(name: "Scala", spec: slashStarSpec),
        "tex": LanguageDef(name: "TeX", spec: percentSpec),
        "ini": LanguageDef(name: "INI", spec: semicolonSpec),
    ]

    /// 对目标目录或文件执行代码行数统计
    public static func count(
        at targetURL: URL,
        ignoredDirectories: Set<String> = defaultIgnoredDirectoryNames,
        isCancelled: @escaping () -> Bool = { false }
    ) -> LineCountResult? {
        let startTime = ProcessInfo.processInfo.systemUptime

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            return nil
        }

        var filesByLanguage: [String: [(url: URL, spec: CommentSpec)]] = [:]

        if !isDir.boolValue {
            // 单文件情况
            let ext = targetURL.pathExtension.lowercased()
            if let def = extensionMap[ext] {
                filesByLanguage[def.name] = [(targetURL, def.spec)]
            } else {
                return LineCountResult(
                    targetURL: targetURL,
                    languages: [],
                    totalFiles: 0,
                    totalCode: 0,
                    totalComment: 0,
                    totalBlank: 0,
                    durationMs: 0
                )
            }
        } else {
            // 目录递归扫描
            guard let enumerator = FileManager.default.enumerator(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return nil
            }

            for case let fileURL as URL in enumerator {
                if isCancelled() { return nil }

                let name = fileURL.lastPathComponent
                guard let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else {
                    continue
                }

                if values.isDirectory == true {
                    if ignoredDirectories.contains(name) {
                        enumerator.skipDescendants()
                    }
                    continue
                }

                if values.isSymbolicLink == true || values.isRegularFile != true {
                    continue
                }

                if let size = values.fileSize, Int64(size) > maxFileSizeBytes {
                    continue
                }

                let ext = fileURL.pathExtension.lowercased()
                if let def = extensionMap[ext] {
                    filesByLanguage[def.name, default: []].append((fileURL, def.spec))
                }
            }
        }

        if isCancelled() { return nil }

        var langStats: [LanguageStats] = []
        var totalFiles = 0
        var totalCode = 0
        var totalComment = 0
        var totalBlank = 0

        for (language, files) in filesByLanguage {
            var lCode = 0
            var lComment = 0
            var lBlank = 0
            var lFiles = 0

            for (fileURL, spec) in files {
                if isCancelled() { return nil }

                guard let (c, m, b) = countLines(in: fileURL, spec: spec) else { continue }
                lCode += c
                lComment += m
                lBlank += b
                lFiles += 1
            }

            if lFiles > 0 {
                langStats.append(LanguageStats(language: language, files: lFiles, code: lCode, comment: lComment, blank: lBlank))
                totalFiles += lFiles
                totalCode += lCode
                totalComment += lComment
                totalBlank += lBlank
            }
        }

        // 按代码行降序排序
        langStats.sort {
            if $0.code != $1.code { return $0.code > $1.code }
            return $0.files > $1.files
        }

        let durationMs = (ProcessInfo.processInfo.systemUptime - startTime) * 1000
        return LineCountResult(
            targetURL: targetURL,
            languages: langStats,
            totalFiles: totalFiles,
            totalCode: totalCode,
            totalComment: totalComment,
            totalBlank: totalBlank,
            durationMs: durationMs
        )
    }

    /// 统计单个文件的代码、注释和空行
    static func countLines(in fileURL: URL, spec: CommentSpec) -> (code: Int, comment: Int, blank: Int)? {
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return nil }
        guard let content = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            return nil
        }

        var code = 0
        var comment = 0
        var blank = 0
        var inBlock = false

        content.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blank += 1
                return
            }

            if inBlock {
                comment += 1
                if let block = spec.block, let endRange = trimmed.range(of: block.end) {
                    inBlock = false
                    // 如果块注释结束之后还有非空字符，可算作代码行（或保持为注释行）
                    let after = trimmed[endRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    if !after.isEmpty && !spec.linePrefixes.contains(where: { after.hasPrefix($0) }) {
                        // 包含有效代码
                        code += 1
                        comment -= 1
                    }
                }
                return
            }

            // 检查是否是行注释开头
            for prefix in spec.linePrefixes where trimmed.hasPrefix(prefix) {
                comment += 1
                return
            }

            // 检查是否有块注释开头
            if let block = spec.block, let startRange = trimmed.range(of: block.start) {
                let before = trimmed[..<startRange.lowerBound].trimmingCharacters(in: .whitespaces)
                if let endRange = trimmed[startRange.upperBound...].range(of: block.end) {
                    // 同一行中开启并关闭了块注释
                    let after = trimmed[endRange.upperBound...].trimmingCharacters(in: .whitespaces)
                    if before.isEmpty && after.isEmpty {
                        comment += 1
                    } else {
                        code += 1
                    }
                } else {
                    // 块注释未在该行结束
                    if before.isEmpty {
                        comment += 1
                    } else {
                        code += 1
                    }
                    inBlock = true
                }
                return
            }

            // 属于有效代码行
            code += 1
        }

        return (code, comment, blank)
    }
}
