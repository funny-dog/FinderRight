import Foundation
import FinderRightKit

/// 系统的扩展选举状态就是唯一配置，避免另存一份开关后与系统设置不一致。
enum PreviewExtensionManager {
    static let identifier = "com.finderright.app.preview"

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

    static func isEnabled() throws -> Bool {
        try enabledState(in: run(["-m", "-i", identifier]))
    }

    static func enabledState(in output: String) throws -> Bool {
        guard let entry = FinderSyncElection.parse(output).first(where: { $0.bundleId == identifier }) else {
            throw Failure.unavailable
        }
        switch entry.state {
        // Quick Look 默认允许已注册的预览扩展；空格表示用户未覆盖这个默认选举。
        case "+", " ": return true
        case "-": return false
        default: throw Failure.unknownState
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        _ = try run(["-e", enabled ? "use" : "ignore", "-i", identifier])
        guard try isEnabled() == enabled else { throw Failure.changeFailed }
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
