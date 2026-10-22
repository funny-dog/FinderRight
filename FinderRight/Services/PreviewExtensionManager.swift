import Foundation
import FinderRightKit

/// 系统的扩展选举状态就是唯一配置，避免另存一份开关后与系统设置不一致。
enum PreviewExtensionManager {
    static let identifier = "com.finderright.app.preview"
    static let markdownIdentifier = "com.finderright.app.markdown"
    /// Markdown 扩展声明的类型；其他应用的预览扩展也声明时，系统选用哪个不确定。
    static let markdownTypes: Set<String> = ["net.daringfireball.markdown", "public.markdown", "io.typora.markdown"]

    enum Failure: LocalizedError {
        case unavailable, unknownState, commandFailed, changeFailed

        var errorDescription: String? {
            let key: String
            switch self {
            case .unavailable: key = "未找到快速查看扩展，请确认 FinderRight 已安装并在系统设置中启用扩展。"
            case .unknownState: key = "无法确认快速查看扩展状态，请在系统设置中检查后重新检测。"
            case .commandFailed: key = "无法访问系统扩展设置，请稍后重新检测。"
            case .changeFailed: key = "快速查看扩展开关未生效，请在系统设置中检查后重试。"
            }
            return NSLocalizedString(key, comment: "Quick Look extension settings")
        }
    }

    static func isEnabled(_ id: String = identifier) throws -> Bool {
        try enabledState(in: run(["-m", "-i", id]), identifier: id)
    }

    static func enabledState(in output: String, identifier id: String = identifier) throws -> Bool {
        guard let entry = FinderSyncElection.parse(output).first(where: { $0.bundleId == id }) else {
            throw Failure.unavailable
        }
        switch entry.state {
        // Quick Look 默认允许已注册的预览扩展；空格表示用户未覆盖这个默认选举。
        case "+", " ": return true
        case "-": return false
        default: throw Failure.unknownState
        }
    }

    static func setEnabled(_ enabled: Bool, identifier id: String = identifier) throws {
        _ = try run(["-e", enabled ? "use" : "ignore", "-i", id])
        guard try isEnabled(id) == enabled else { throw Failure.changeFailed }
    }

    /// 其他已启用且声明了 Markdown 类型的预览扩展所属的应用名称（如 MarkEdit）。
    static func markdownConflicts() -> [String] {
        guard let output = try? run(["-m", "-v", "-p", "com.apple.quicklook.preview"]) else { return [] }
        return markdownConflicts(verboseOutput: output) { path in
            let info = NSDictionary(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist"))
            let attributes = (info?["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
            return attributes?["QLSupportedContentTypes"] as? [String] ?? []
        }
    }

    /// verboseOutput 每行形如 `+    bundleId(版本)\tUUID\t时间\t路径`；空格状态表示未被用户覆盖的默认启用。
    static func markdownConflicts(verboseOutput: String, supportedTypes: (String) -> [String]) -> [String] {
        var names: [String] = []
        for line in verboseOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t")
            guard let entry = FinderSyncElection.parse(String(fields.first ?? "")).first,
                  entry.state == "+" || entry.state == " ",
                  !entry.bundleId.hasPrefix("com.finderright."),
                  let path = fields.last.map({ $0.trimmingCharacters(in: .whitespaces) }), path.hasSuffix(".appex"),
                  !markdownTypes.isDisjoint(with: supportedTypes(path)) else { continue }
            let app = URL(fileURLWithPath: path).pathComponents.last { $0.hasSuffix(".app") }
            let name = app.map { String($0.dropLast(4)) } ?? entry.bundleId
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        // 只查询固定的自身标识，输出很小；先读完再等待退出，避免管道互等。
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.commandFailed }
        return String(decoding: data, as: UTF8.self)
    }
}
