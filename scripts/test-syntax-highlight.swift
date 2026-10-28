import AppKit
import FinderRightKit
import Foundation

@main
struct SyntaxHighlightTests {
    static func main() throws {
        print("=== 开始运行轻量语法高亮独立测试 ===")

        // 1. 语言别名归一测试
        testLanguageNormalization()

        // 3. 各语言分词准确性测试
        testTokenization()

        // 4. 外观与主题自适应测试
        testThemeColors()

        // 5. 富文本高亮渲染与属性验证
        testHighlightRendering()

        // 6. 1 MiB 性能测试与大小降级测试
        testOneMegabytePerformanceAndDowngrade()

        print("✓ 轻量语法高亮全部测试通过！")
    }

    private static func testLanguageNormalization() {
        let testCases: [(raw: String?, expected: SyntaxLanguage?)] = [
            ("swift", .swift),
            ("Swift", .swift),
            (".SWIFT", .swift),
            ("  swift  ", .swift),
            ("go", .go),
            ("golang", .go),
            ("rs", .rust),
            ("rust", .rust),
            ("js", .javascript),
            ("javascript", .javascript),
            ("mjs", .javascript),
            ("cjs", .javascript),
            ("jsx", .javascript),
            ("ts", .typescript),
            ("typescript", .typescript),
            ("mts", .typescript),
            ("cts", .typescript),
            ("tsx", .typescript),
            ("py", .python),
            ("python", .python),
            ("python3", .python),
            ("py3", .python),
            ("sh", .shell),
            ("bash", .shell),
            ("zsh", .shell),
            ("shell", .shell),
            ("json", .json),
            ("jsonc", .json),
            ("json5", .json),
            ("jsonl", .json),
            ("ndjson", .json),
            ("yaml", .yaml),
            ("yml", .yaml),
            ("toml", .toml),
            // 未知语言与无效值必须归一化为 nil
            ("", nil),
            ("   ", nil),
            ("txt", nil),
            ("plaintext", nil),
            ("c", nil),
            ("cpp", nil),
            ("markdown", nil),
            ("html", nil),
            ("unknown_lang", nil),
            (nil, nil)
        ]

        for (raw, expected) in testCases {
            let actual = SyntaxLanguage.normalize(raw)
            precondition(actual == expected, "语言别名归一失败: 输入 [\(String(describing: raw))], 期望 \(String(describing: expected)), 实际 \(String(describing: actual))")
        }
        print("  ✓ 语言别名归一覆盖率通过（包含各主流别名、大小写、空白及未知语言）")
    }

    private static func testTokenization() {
        // Swift 分词
        let swiftCode = """
        // 头部注释
        func calculateSum(a: Int, b: Int) -> Int {
            /* 多行块注释 */
            let name = "FinderRight"
            let count = 1234
            return a + b
        }
        """
        let swiftTokens = SyntaxTokenizer.tokenize(source: swiftCode, language: .swift)
        precondition(swiftTokens.contains { $0.kind == .comment })
        precondition(swiftTokens.contains { $0.kind == .keyword })
        precondition(swiftTokens.contains { $0.kind == .string })
        precondition(swiftTokens.contains { $0.kind == .number })

        func slice(_ source: String, range: NSRange) -> String {
            let start = source.utf16.index(source.utf16.startIndex, offsetBy: range.location)
            let end = source.utf16.index(start, offsetBy: range.length)
            return String(source.utf16[start..<end])!
        }

        let comments = swiftTokens.filter { $0.kind == .comment }.map { slice(swiftCode, range: $0.range) }
        precondition(comments.contains("// 头部注释"))
        precondition(comments.contains("/* 多行块注释 */"))

        let strings = swiftTokens.filter { $0.kind == .string }.map { slice(swiftCode, range: $0.range) }
        precondition(strings.contains("\"FinderRight\""))

        let numbers = swiftTokens.filter { $0.kind == .number }.map { slice(swiftCode, range: $0.range) }
        precondition(numbers.contains("1234"))

        let keywords = swiftTokens.filter { $0.kind == .keyword }.map { slice(swiftCode, range: $0.range) }
        precondition(keywords.contains("func") && keywords.contains("let") && keywords.contains("return"))

        // Python 分词与三引号
        let pythonCode = """
        # Python 注释
        def test():
            msg = '''多行文本'''
            val = 999
            return msg
        """
        let pyTokens = SyntaxTokenizer.tokenize(source: pythonCode, language: .python)
        let pyComments = pyTokens.filter { $0.kind == .comment }.map { slice(pythonCode, range: $0.range) }
        precondition(pyComments.contains("# Python 注释"))
        let pyStrings = pyTokens.filter { $0.kind == .string }.map { slice(pythonCode, range: $0.range) }
        precondition(pyStrings.contains("'''多行文本'''"))

        // Go 反引号 raw string
        let goCode = "package main\nvar s = `raw text`\nvar num = 42"
        let goTokens = SyntaxTokenizer.tokenize(source: goCode, language: .go)
        let goStrings = goTokens.filter { $0.kind == .string }.map { slice(goCode, range: $0.range) }
        precondition(goStrings.contains("`raw text`"))

        for (language, source, keyword) in [
            (SyntaxLanguage.rust, "let name = \"中文😀\"; // 注释", "let"),
            (.javascript, "const name = \"中文😀\"; // 注释", "const"),
            (.typescript, "interface Thing {} // 注释", "interface"),
            (.shell, "if true; then echo \"中文😀\"; fi # 注释", "if"),
            (.json, "{\"name\": \"中文😀\", \"ok\": true}", "true"),
            (.yaml, "name: \"中文😀\"\nvalid: true # 注释", "true"),
            (.toml, "name = \"中文😀\"\nvalid = true # 注释", "true")
        ] {
            let tokens = SyntaxTokenizer.tokenize(source: source, language: language)
            precondition(tokens.contains { $0.kind == .keyword && (source as NSString).substring(with: $0.range) == keyword })
            for token in tokens {
                precondition(token.range.location + token.range.length <= source.utf16.count)
            }
        }

        print("  ✓ 多语言分词与范围校验通过（Swift、Python、Go 等）")
    }

    private static func testThemeColors() {
        let lightAppearance = NSAppearance(named: .aqua)!
        let darkAppearance = NSAppearance(named: .darkAqua)!

        for kind in [SyntaxTokenKind.keyword, .string, .comment, .number] {
            let color = SyntaxTheme.color(for: kind)
            var lightColor: NSColor?
            var darkColor: NSColor?
            lightAppearance.performAsCurrentDrawingAppearance {
                lightColor = color.usingColorSpace(.sRGB)
            }
            darkAppearance.performAsCurrentDrawingAppearance {
                darkColor = color.usingColorSpace(.sRGB)
            }
            precondition(lightColor != nil && darkColor != nil)
            precondition(lightColor != darkColor, "Token \(kind) 在浅色与深色外观下应具备区分色")
        }
        print("  ✓ 语法配色跟随浅色/深色主题动态适配验证通过")
    }

    private static func testHighlightRendering() {
        let snippet = "func demo() { let x = 10 }"
        let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let attributed = SyntaxHighlighter.highlight(
            source: snippet,
            language: .swift,
            baseFont: baseFont,
            baseColor: .textColor
        )

        precondition(attributed.string == snippet, "高亮后的富文本内容必须与原文一致")
        let ns = snippet as NSString
        let funcRange = ns.range(of: "func")
        let letRange = ns.range(of: "let")
        let numRange = ns.range(of: "10")
        let spaceRange = ns.range(of: "demo")

        let funcColor = attributed.attribute(.foregroundColor, at: funcRange.location, effectiveRange: nil) as? NSColor
        let letColor = attributed.attribute(.foregroundColor, at: letRange.location, effectiveRange: nil) as? NSColor
        let numColor = attributed.attribute(.foregroundColor, at: numRange.location, effectiveRange: nil) as? NSColor
        let spaceColor = attributed.attribute(.foregroundColor, at: spaceRange.location, effectiveRange: nil) as? NSColor

        precondition(funcColor != nil && funcColor == letColor, "关键字应赋予关键字前景色")
        precondition(numColor != nil && numColor != funcColor, "数字应赋予数字前景色")
        precondition(spaceColor == .textColor, "未匹配的标识符应保持基底前景色")

        // 未知语言保持纯文本
        let plain = SyntaxHighlighter.highlight(source: snippet, language: nil, baseColor: .textColor)
        plain.enumerateAttributes(in: NSRange(location: 0, length: plain.length)) { attrs, _, _ in
            precondition((attrs[.foregroundColor] as? NSColor) == .textColor, "未知语言必须保持纯文本前景色")
        }
        print("  ✓ 富文本渲染与属性匹配验证通过")
    }

    private static func testOneMegabytePerformanceAndDowngrade() {
        // 生成约 1 MiB 的源代码（约 1,048,500 字节）
        var lines: [String] = []
        lines.append("// 1 MiB 性能测试文件生成")
        lines.append("import Foundation")
        var currentBytes = lines.joined(separator: "\n").utf8.count
        var counter = 0
        while currentBytes < 1_048_000 {
            let line = "func generateFunction\(counter)(id: Int) -> String { let token = \"str_\(counter)\"; return token /* block */ }"
            lines.append(line)
            currentBytes += line.utf8.count + 1
            counter += 1
        }
        let generated = lines.joined(separator: "\n")
        let sample1MB = generated + String(repeating: " ", count: 1_048_576 - generated.utf8.count)
        let actualBytes = sample1MB.utf8.count
        precondition(actualBytes >= 1_000_000 && actualBytes <= 1_048_576, "样例应接近 1 MiB 边界")

        // 实际耗时基准测试
        let start = CFAbsoluteTimeGetCurrent()
        let result = SyntaxHighlighter.highlight(
            source: sample1MB,
            language: .swift,
            baseFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
            baseColor: .textColor
        )
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        print(String(format: "  ★ 1 MiB 样例实际处理耗时: %.2f ms (目标: < 300 ms, 字节数: %d)", elapsedMs, actualBytes))

        precondition(result.length == sample1MB.utf16.count, "渲染字符数一致")

        // 大小超限降级测试（> 1,048,576 字节自动降级为纯文本）
        let oversize = sample1MB + "\n// 溢出字符" + String(repeating: "x", count: 2000)
        precondition(oversize.utf8.count > 1_048_576)
        let downgradeStart = CFAbsoluteTimeGetCurrent()
        let downgradeResult = SyntaxHighlighter.highlight(source: oversize, language: .swift)
        let downgradeElapsedMs = (CFAbsoluteTimeGetCurrent() - downgradeStart) * 1000.0
        print(String(format: "  ✓ 大小超限自动降级耗时: %.2f ms（直接纯文本跳过分词）", downgradeElapsedMs))


        // 确认降级后无关键字高亮属性
        let nsOversize = oversize as NSString
        let funcRange = nsOversize.range(of: "func")
        let color = downgradeResult.attribute(.foregroundColor, at: funcRange.location, effectiveRange: nil) as? NSColor
        precondition(color == .textColor, "超过 1 MiB 限制必须自动降级为纯文本，不能着色")
    }
}
