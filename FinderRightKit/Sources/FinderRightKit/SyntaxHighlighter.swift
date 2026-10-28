import AppKit
import Foundation

/// 支持语法高亮的编程与配置文件语言
public enum SyntaxLanguage: String, CaseIterable {
    case swift
    case go
    case rust
    case javascript
    case typescript
    case python
    case shell
    case json
    case yaml
    case toml

    /// 语言别名归一：忽略大小写、首尾空白与可选的扩展名点前缀；未知语言返回 nil
    public static func normalize(_ raw: String?) -> SyntaxLanguage? {
        guard let raw else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix(".") { trimmed.removeFirst() }
        switch trimmed {
        case "swift":
            return .swift
        case "go", "golang":
            return .go
        case "rs", "rust":
            return .rust
        case "js", "javascript", "mjs", "cjs", "jsx":
            return .javascript
        case "ts", "typescript", "mts", "cts", "tsx":
            return .typescript
        case "py", "python", "python3", "py3":
            return .python
        case "sh", "bash", "zsh", "shell":
            return .shell
        case "json", "jsonc", "json5", "jsonl", "ndjson":
            return .json
        case "yaml", "yml":
            return .yaml
        case "toml":
            return .toml
        default:
            return nil
        }
    }


}

/// 语法词元类别
public enum SyntaxTokenKind: Equatable {
    case plain
    case keyword
    case string
    case comment
    case number
}

/// 语法分词结果，位置使用 UTF-16 偏移以精确适配 NSAttributedString
public struct SyntaxToken: Equatable {
    public let range: NSRange
    public let kind: SyntaxTokenKind

    public init(range: NSRange, kind: SyntaxTokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// 高亮主题配色，自适应浅色与深色外观
public enum SyntaxTheme {
    public static let keywordColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.95, green: 0.45, blue: 0.75, alpha: 1.0)
            : NSColor(srgbRed: 0.65, green: 0.12, blue: 0.55, alpha: 1.0)
    }

    public static let stringColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 1.00, green: 0.55, blue: 0.45, alpha: 1.0)
            : NSColor(srgbRed: 0.78, green: 0.20, blue: 0.15, alpha: 1.0)
    }

    public static let commentColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.55, green: 0.62, blue: 0.68, alpha: 1.0)
            : NSColor(srgbRed: 0.42, green: 0.47, blue: 0.53, alpha: 1.0)
    }

    public static let numberColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0.45, green: 0.75, blue: 1.00, alpha: 1.0)
            : NSColor(srgbRed: 0.10, green: 0.35, blue: 0.80, alpha: 1.0)
    }

    public static func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .plain:
            return .textColor
        case .keyword:
            return keywordColor
        case .string:
            return stringColor
        case .comment:
            return commentColor
        case .number:
            return numberColor
        }
    }
}

/// 轻量级无第三方依赖的语法分词器
public enum SyntaxTokenizer {
    private struct LanguageRule {
        let hasSlashSlashComment: Bool
        let hasHashComment: Bool
        let hasBlockComment: Bool
        let nestedBlockComment: Bool
        let singleQuoteString: Bool
        let backtickString: Bool
        let tripleQuoteString: Bool
        let keywords: Set<String>
    }

    private static let swiftKeywords: Set<String> = [
        "class", "struct", "enum", "protocol", "extension", "func", "init", "deinit", "typealias",
        "let", "var", "static", "mutating", "nonmutating", "override", "final", "required",
        "private", "fileprivate", "internal", "public", "open",
        "if", "else", "guard", "switch", "case", "default", "for", "in", "while", "repeat",
        "return", "throw", "throws", "rethrows", "try", "catch", "defer",
        "break", "continue", "fallthrough",
        "as", "is", "self", "Self", "super", "nil", "true", "false",
        "async", "await", "actor", "some", "any", "import", "where"
    ]

    private static let goKeywords: Set<String> = [
        "break", "default", "func", "interface", "select",
        "case", "defer", "go", "map", "struct",
        "chan", "else", "goto", "package", "switch",
        "const", "fallthrough", "if", "range", "type",
        "continue", "for", "import", "return", "var",
        "nil", "true", "false", "iota", "make", "new", "len", "cap", "append", "copy", "delete", "panic", "recover"
    ]

    private static let rustKeywords: Set<String> = [
        "as", "async", "await", "break", "const", "continue", "crate", "dyn",
        "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
        "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
        "self", "Self", "static", "struct", "super", "trait", "true", "type",
        "unsafe", "use", "where", "while"
    ]

    private static let jsKeywords: Set<String> = [
        "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "export", "extends", "false",
        "finally", "for", "function", "if", "import", "in", "instanceof", "let",
        "new", "null", "return", "super", "switch", "this", "throw", "true",
        "try", "typeof", "var", "void", "while", "with", "yield", "of"
    ]

    private static let tsKeywords: Set<String> = jsKeywords.union([
        "type", "interface", "enum", "implements", "declare", "namespace", "readonly",
        "abstract", "as", "any", "unknown", "never", "keyof", "is", "override", "satisfies"
    ])

    private static let pythonKeywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await",
        "break", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
        "while", "with", "yield"
    ]

    private static let shellKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "case", "esac", "for", "select",
        "while", "until", "do", "done", "in", "function", "time", "return",
        "exit", "export", "local", "readonly", "set", "unset", "shift", "source",
        "echo", "alias"
    ]

    private static let jsonKeywords: Set<String> = ["true", "false", "null"]

    private static let yamlKeywords: Set<String> = [
        "true", "false", "yes", "no", "null", "on", "off", "y", "n", "TRUE", "FALSE", "True", "False"
    ]

    private static let tomlKeywords: Set<String> = ["true", "false", "inf", "nan"]

    private static func rule(for language: SyntaxLanguage) -> LanguageRule {
        switch language {
        case .swift:
            return LanguageRule(
                hasSlashSlashComment: true, hasHashComment: false, hasBlockComment: true, nestedBlockComment: true,
                singleQuoteString: false, backtickString: false, tripleQuoteString: true, keywords: swiftKeywords
            )
        case .go:
            return LanguageRule(
                hasSlashSlashComment: true, hasHashComment: false, hasBlockComment: true, nestedBlockComment: false,
                singleQuoteString: false, backtickString: true, tripleQuoteString: false, keywords: goKeywords
            )
        case .rust:
            return LanguageRule(
                hasSlashSlashComment: true, hasHashComment: false, hasBlockComment: true, nestedBlockComment: true,
                singleQuoteString: true, backtickString: false, tripleQuoteString: false, keywords: rustKeywords
            )
        case .javascript:
            return LanguageRule(
                hasSlashSlashComment: true, hasHashComment: false, hasBlockComment: true, nestedBlockComment: false,
                singleQuoteString: true, backtickString: true, tripleQuoteString: false, keywords: jsKeywords
            )
        case .typescript:
            return LanguageRule(
                hasSlashSlashComment: true, hasHashComment: false, hasBlockComment: true, nestedBlockComment: false,
                singleQuoteString: true, backtickString: true, tripleQuoteString: false, keywords: tsKeywords
            )
        case .python:
            return LanguageRule(
                hasSlashSlashComment: false, hasHashComment: true, hasBlockComment: false, nestedBlockComment: false,
                singleQuoteString: true, backtickString: false, tripleQuoteString: true, keywords: pythonKeywords
            )
        case .shell:
            return LanguageRule(
                hasSlashSlashComment: false, hasHashComment: true, hasBlockComment: false, nestedBlockComment: false,
                singleQuoteString: true, backtickString: false, tripleQuoteString: false, keywords: shellKeywords
            )
        case .json:
            return LanguageRule(
                hasSlashSlashComment: true, hasHashComment: false, hasBlockComment: true, nestedBlockComment: false,
                singleQuoteString: false, backtickString: false, tripleQuoteString: false, keywords: jsonKeywords
            )
        case .yaml:
            return LanguageRule(
                hasSlashSlashComment: false, hasHashComment: true, hasBlockComment: false, nestedBlockComment: false,
                singleQuoteString: true, backtickString: false, tripleQuoteString: false, keywords: yamlKeywords
            )
        case .toml:
            return LanguageRule(
                hasSlashSlashComment: false, hasHashComment: true, hasBlockComment: false, nestedBlockComment: false,
                singleQuoteString: true, backtickString: false, tripleQuoteString: true, keywords: tomlKeywords
            )
        }
    }

    /// 对输入源代码进行分词，线性时间复杂度 O(N)
    public static func tokenize(source: String, language: SyntaxLanguage) -> [SyntaxToken] {
        let utf16 = Array(source.utf16)
        let n = utf16.count
        if n == 0 || n > SyntaxHighlighter.maxHighlightedBytes {
            return []
        }

        let rule = self.rule(for: language)
        var tokens: [SyntaxToken] = []
        tokens.reserveCapacity(min(n / 8, 65536))
        var i = 0

        while i < n {
            let u = utf16[i]

            // 1. 斜杠单行注释 // 与多行注释 /* */
            if u == 47 /* / */ && i + 1 < n {
                let next = utf16[i + 1]
                if rule.hasSlashSlashComment && next == 47 /* / */ {
                    let start = i
                    i += 2
                    while i < n && utf16[i] != 10 /* \n */ && utf16[i] != 13 /* \r */ {
                        i += 1
                    }
                    tokens.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .comment))
                    continue
                } else if rule.hasBlockComment && next == 42 /* * */ {
                    let start = i
                    i += 2
                    var depth = 1
                    while i + 1 < n && depth > 0 {
                        if rule.nestedBlockComment && utf16[i] == 47 && utf16[i + 1] == 42 {
                            depth += 1
                            i += 2
                        } else if utf16[i] == 42 && utf16[i + 1] == 47 {
                            depth -= 1
                            i += 2
                        } else {
                            i += 1
                        }
                    }
                    if depth > 0 && i < n { i = n }
                    tokens.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .comment))
                    continue
                }
            }

            // 2. 井号单行注释 #
            if rule.hasHashComment && u == 35 /* # */ {
                let start = i
                i += 1
                while i < n && utf16[i] != 10 /* \n */ && utf16[i] != 13 /* \r */ {
                    i += 1
                }
                tokens.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            }

            // 3. 三引号多行字符串 """ 或 '''
            if rule.tripleQuoteString && (u == 34 /* " */ || u == 39 /* ' */) {
                if i + 2 < n && utf16[i + 1] == u && utf16[i + 2] == u {
                    let quote = u
                    let start = i
                    i += 3
                    while i < n {
                        if utf16[i] == 92 /* \ */ && i + 1 < n {
                            i += 2
                        } else if i + 2 < n && utf16[i] == quote && utf16[i + 1] == quote && utf16[i + 2] == quote {
                            i += 3
                            break
                        } else {
                            i += 1
                        }
                    }
                    tokens.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .string))
                    continue
                }
            }

            // 4. 双引号字符串 "..."
            if u == 34 /* " */ {
                let start = i
                i += 1
                while i < n {
                    if utf16[i] == 92 /* \ */ && i + 1 < n {
                        i += 2
                    } else if utf16[i] == 34 {
                        i += 1
                        break
                    } else if utf16[i] == 10 || utf16[i] == 13 {
                        break
                    } else {
                        i += 1
                    }
                }
                tokens.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .string))
                continue
            }

            // 5. 单引号字符串 '...'
            if rule.singleQuoteString && u == 39 /* ' */ {
                let start = i
                i += 1
                while i < n {
                    if utf16[i] == 92 /* \ */ && i + 1 < n {
                        i += 2
                    } else if utf16[i] == 39 {
                        i += 1
                        break
                    } else if utf16[i] == 10 || utf16[i] == 13 {
                        break
                    } else {
                        i += 1
                    }
                }
                tokens.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .string))
                continue
            }

            // 6. 反引号字符串 `...`
            if rule.backtickString && u == 96 /* ` */ {
                let start = i
                i += 1
                while i < n {
                    if utf16[i] == 92 /* \ */ && i + 1 < n && language != .go {
                        i += 2
                    } else if utf16[i] == 96 {
                        i += 1
                        break
                    } else {
                        i += 1
                    }
                }
                tokens.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .string))
                continue
            }

            // 7. 数字字面量
            if u >= 48 && u <= 57 /* 0-9 */ {
                let prev = i > 0 ? utf16[i - 1] : 0
                let isPrevIdent = (prev >= 97 && prev <= 122) || (prev >= 65 && prev <= 90) || prev == 95 || prev == 36
                if !isPrevIdent {
                    let start = i
                    i += 1
                    while i < n {
                        let c = utf16[i]
                        if (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) ||
                            c == 120 || c == 88 || c == 95 || c == 46 || c == 111 || c == 79 || c == 98 || c == 66 {
                            i += 1
                        } else {
                            break
                        }
                    }
                    tokens.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .number))
                    continue
                }
            }

            // 8. 标识符与关键字
            if (u >= 97 && u <= 122) || (u >= 65 && u <= 90) || u == 95 || u == 36 {
                let start = i
                i += 1
                while i < n {
                    let c = utf16[i]
                    if (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 || c == 36 {
                        i += 1
                    } else {
                        break
                    }
                }
                let len = i - start
                let word = String(utf16CodeUnits: Array(utf16[start..<i]), count: len)
                if rule.keywords.contains(word) {
                    tokens.append(SyntaxToken(range: NSRange(location: start, length: len), kind: .keyword))
                }
                continue
            }

            i += 1
        }
        return tokens
    }
}

/// 语法高亮器入口
public enum SyntaxHighlighter {
    /// 纯文本与代码块着色的最大字节数（1 MiB，超过则降级为纯文本）
    public static let maxHighlightedBytes: Int = 1_048_576

    /// 生成带有语法高亮属性的 NSAttributedString
    public static func highlight(
        source: String,
        language: SyntaxLanguage?,
        baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        baseColor: NSColor = .textColor,
        paragraphStyle: NSParagraphStyle? = nil
    ) -> NSAttributedString {
        var baseAttributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: baseColor
        ]
        if let paragraphStyle {
            baseAttributes[.paragraphStyle] = paragraphStyle
        }

        guard let language, source.utf8.count <= maxHighlightedBytes else {
            return NSAttributedString(string: source, attributes: baseAttributes)
        }

        let tokens = SyntaxTokenizer.tokenize(source: source, language: language)
        if tokens.isEmpty {
            return NSAttributedString(string: source, attributes: baseAttributes)
        }

        let attributed = NSMutableAttributedString(string: source, attributes: baseAttributes)
        attributed.beginEditing()
        for token in tokens where token.kind != .plain {
            attributed.addAttribute(.foregroundColor, value: SyntaxTheme.color(for: token.kind), range: token.range)
        }
        attributed.endEditing()
        return attributed
    }
}
