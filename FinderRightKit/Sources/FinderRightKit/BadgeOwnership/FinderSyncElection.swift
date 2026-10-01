import Foundation

/// `pluginkit -m -p com.apple.FinderSync` 输出解析。
///
/// 每行形如 `+    com.aone.keka.KekaFinderIntegration(1.6.4)`：首字符为选举状态
/// （`+` 启用、`-` 禁用、空格为未选举、`!` / `=` 等其他状态），随后是空白与 `bundleId(版本)`。
public enum FinderSyncElection {

    public struct Entry: Equatable {
        public let state: Character
        public let bundleId: String
        public let version: String?

        public init(state: Character, bundleId: String, version: String?) {
            self.state = state
            self.bundleId = bundleId
            self.version = version
        }
    }

    private static let bundleIdCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")

    /// 解析全部条目；空行与无法识别的行忽略
    public static func parse(_ output: String) -> [Entry] {
        output.split(whereSeparator: \.isNewline).compactMap { parseLine(String($0)) }
    }

    /// 处于启用（`+`）状态的 bundle id：去重、保持出现顺序、排除 `excluding`
    public static func enabledBundleIds(in output: String, excluding: Set<String>) -> [String] {
        var seen = Set<String>()
        return parse(output)
            .filter { $0.state == "+" && !excluding.contains($0.bundleId) }
            .map(\.bundleId)
            .filter { seen.insert($0).inserted }
    }

    /// 主 App 启动时判断：系统里登记的扩展是否就是当前 bundle 内的这一份（版本与路径都一致）。
    /// 一致时**不得**再 `pluginkit -a` —— 重复注册会重启扩展进程、使其排到重叠扩展之后而丢失角标归属。
    ///
    /// - Parameter verboseOutput: `pluginkit -m -v -i <id>` 的输出。**必须带 -v**：非 verbose
    ///   输出没有路径字段，无法确认路径，这里会返回 false（曾因此每次启动都误判并重复注册）。
    public static func isRegistrationCurrent(verboseOutput: String, appexPath: String, version: String) -> Bool {
        for line in verboseOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let entry = parseLine(String(line.split(separator: "\t").first ?? "")),
                  version.isEmpty || entry.version == version else { continue }
            if fields.dropFirst().contains(appexPath) {
                return true
            }
        }
        return false
    }

    private static func parseLine(_ line: String) -> Entry? {
        guard let state = line.first else { return nil }
        let rest = line.dropFirst().trimmingCharacters(in: .whitespaces)

        let bundleId: String
        let version: String?
        if let open = rest.firstIndex(of: "("), rest.hasSuffix(")") {
            bundleId = String(rest[..<open])
            version = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
        } else {
            bundleId = rest
            version = nil
        }

        guard !bundleId.isEmpty, bundleId.contains("."),
              bundleId.unicodeScalars.allSatisfy({ bundleIdCharacters.contains($0) }) else {
            return nil
        }
        return Entry(state: state, bundleId: bundleId, version: version)
    }
}

/// 抢回期间的恢复标记（`badge-reclaim-restore.json`）。
///
/// 主 App 在 `pluginkit -e ignore` 其他扩展**之前**先落盘待恢复列表，全部 `-e use` 并核验后删除。
/// 若中途崩溃，下次启动按标记恢复，保证用户的其他扩展不会停留在禁用状态。
public struct BadgeReclaimRestoreStore {

    public static let fileName = "badge-reclaim-restore.json"

    public let directory: URL

    public init(directory: URL = IPCBridge.rootDirectory) {
        self.directory = directory
    }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private struct Payload: Codable {
        let bundleIds: [String]
        let createdAt: Date
    }

    public func save(_ bundleIds: [String]) throws {
        let data = try JSONEncoder().encode(Payload(bundleIds: bundleIds, createdAt: Date()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// 读取待恢复列表；无标记或内容损坏返回 `[]`
    public func load() -> [String] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return []
        }
        return payload.bundleIds
    }

    public func clear() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// 抢回限流：同一请求方只受理一次；两次受理至少间隔 `minInterval`；
/// 滚动 `window` 内最多 `maxPerWindow` 次。被拒绝的请求不占用名额。
///
/// 请求方标识为「扩展进程 pid:注册轮次」（见 `BadgeOwnershipProbe.requesterId`）：
/// 同一进程挂载新卷重新注册后进入新一轮，可再申请一次。
/// 主要防御对象是打开 / 存储面板拉起的扩展实例——它们同样会探测并申请抢回。
public struct BadgeReclaimRateLimiter {

    public enum Decision: Equatable {
        case accept
        case reject(reason: String)
    }

    private let minInterval: TimeInterval
    private let maxPerWindow: Int
    private let window: TimeInterval

    private var acceptedRequesters: Set<String> = []
    private var acceptedTimes: [Date] = []

    public init(minInterval: TimeInterval = 20, maxPerWindow: Int = 5, window: TimeInterval = 3600) {
        self.minInterval = minInterval
        self.maxPerWindow = maxPerWindow
        self.window = window
    }

    public mutating func evaluate(requester: String, now: Date) -> Decision {
        if acceptedRequesters.contains(requester) {
            return .reject(reason: "请求方 \(requester) 已受理过")
        }
        if let last = acceptedTimes.last, now.timeIntervalSince(last) < minInterval {
            return .reject(reason: "距上次不足 \(Int(minInterval))s")
        }
        acceptedTimes.removeAll { now.timeIntervalSince($0) > window }
        if acceptedTimes.count >= maxPerWindow {
            return .reject(reason: "\(Int(window))s 内已达 \(maxPerWindow) 次上限")
        }
        acceptedRequesters.insert(requester)
        acceptedTimes.append(now)
        return .accept
    }
}
