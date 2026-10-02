import Foundation
import CryptoKit

/// 扩展 ↔ 主 App 的文件型 IPC 桥。
///
/// 为什么不用 NSXPCListenerEndpoint：
///   - `NSXPCListenerEndpoint` 实现的 `NSSecureCoding` 只能在 NSXPCCoder 上下文里使用，
///     用 NSKeyedArchiver 序列化会抛 "This class may only be encoded by an NSXPCCoder"。
///   - 没有 launchd plist 注册 mach service 的情况下，标准 NSXPCConnection 也连不上主 App。
///
/// 因此走文件 IPC：
///   - 扩展把 request JSON 写到 `pendingDir/<uuid>.req.json`
///   - 扩展用自定义 URL scheme `finderright://execute?id=<uuid>` 唤醒主 App
///   - 主 App 处理后把结果写到 `pendingDir/<uuid>.resp.json`
///   - 扩展 poll 等待 response 文件出现
public enum IPCBridge {

    /// 真实用户 home 目录（绕过沙箱重定向）。
    /// 注意：不能用 NSHomeDirectory()（沙箱环境下会返回容器私有目录）。
    public static var realUserHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            let path = String(cString: pwDir)
            if !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/Users/\(NSUserName())")
    }

    /// 共享根目录（在真实用户 home，绕过沙箱重定向）
    public static var rootDirectory: URL {
        return realUserHomeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("FinderRight", isDirectory: true)
    }

    /// 待处理请求目录
    public static var pendingDir: URL {
        rootDirectory.appendingPathComponent("ipc", isDirectory: true)
    }

    /// 主 App bundle identifier
    public static let mainAppBundleIdentifier = "com.finderright.app"

    /// FinderSync 扩展 bundle identifier
    public static let extensionBundleIdentifier = "com.finderright.app.sync"

    /// URL scheme
    public static let urlScheme = "finderright"

    /// 构造 request 文件 URL
    public static func requestFile(id: String) -> URL {
        pendingDir.appendingPathComponent("\(id).req.json")
    }

    /// 构造 response 文件 URL
    public static func responseFile(id: String) -> URL {
        pendingDir.appendingPathComponent("\(id).resp.json")
    }

    /// 确保 pendingDir 存在
    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: pendingDir, withIntermediateDirectories: true)
    }
}

extension IPCBridge {
    /// 由扩展自身的 bundle 位置推出宿主主 App：`<App>.app/Contents/PlugIns/<Ext>.appex`。
    /// 结构不符（例如扩展被单独拷出）时返回 nil，调用方应退回普通 URL 唤醒。
    public static func containingAppURL(forExtensionAt bundleURL: URL) -> URL? {
        let plugIns = bundleURL.deletingLastPathComponent()
        let contents = plugIns.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard bundleURL.pathExtension == "appex",
              plugIns.lastPathComponent == "PlugIns",
              contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else {
            return nil
        }
        return app
    }
}

extension IPCBridge {
    /// 请求文件内容的 SHA-256（小写十六进制）
    public static func requestDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 唤醒主 App 的 URL：`finderright://execute?id=<uuid>&digest=<请求文件 SHA-256>`。
    ///
    /// 主 App 会确认发出这条 URL 的进程就是内嵌扩展；把请求文件的摘要放进这条已确认来源的 URL，
    /// 才能保证主 App 读到的文件就是扩展写的那份——请求目录对同用户进程可写，
    /// 不带摘要时，文件可能在扩展写完、主 App 读取之前被替换。
    public static func executeURL(id: String, requestData: Data) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "execute"
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "digest", value: requestDigest(requestData)),
        ]
        return components.url
    }

    /// 解析并校验 execute URL：id 必须是 UUID（会被拼进文件路径），digest 必须是 64 位十六进制
    public static func parseExecuteURL(_ url: URL) -> (id: String, digest: String)? {
        guard url.scheme == urlScheme, url.host == "execute",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "id" })?.value,
              UUID(uuidString: id) != nil,
              let digest = items.first(where: { $0.name == "digest" })?.value?.lowercased(),
              digest.count == 64,
              digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return nil
        }
        return (id, digest)
    }
}

// MARK: - 数据结构

/// 一次 IPC 请求的统一信封
public struct IPCRequest: Codable {
    public let id: String
    public let action: String     // 操作类型，如 "createFile" / "compressZip" / ...
    public let payload: [String: AnyJSON]  // 参数字典

    public init(id: String, action: String, payload: [String: AnyJSON]) {
        self.id = id
        self.action = action
        self.payload = payload
    }
}

/// 一次 IPC 响应
public struct IPCResponse: Codable {
    public let id: String
    public let success: Bool
    public let message: String?  // 失败时是错误描述；成功时可以是路径等附加信息

    public init(id: String, success: Bool, message: String?) {
        self.id = id
        self.success = success
        self.message = message
    }
}

/// 让 [String: Any] 能 Codable —— 简化版只支持 String / [String] / Bool / Int
public enum AnyJSON: Codable {
    case string(String)
    case stringArray([String])
    case bool(Bool)
    case int(Int)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([String].self) { self = .stringArray(v); return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported AnyJSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .stringArray(let a): try c.encode(a)
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .null: try c.encodeNil()
        }
    }

    public var stringValue: String? { if case let .string(s) = self { return s } else { return nil } }
    public var stringArrayValue: [String]? {
        if case let .stringArray(a) = self { return a } else { return nil }
    }
    public var boolValue: Bool? { if case let .bool(b) = self { return b } else { return nil } }
    public var intValue: Int? { if case let .int(i) = self { return i } else { return nil } }
}
