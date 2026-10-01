import Foundation

/// 角标归属抢回的 IPC 约定（扩展与主 App 共用）。
///
/// 背景：同一目录被多个 Finder Sync 扩展注册时，Finder 只把 requestBadgeIdentifier
/// 交给最先注册者。扩展判定自己丢失归属后，经 IPC 请主 App 短暂重启其他扩展以取回归属。
/// 详见 docs/superpowers/specs/2026-10-02-badge-ownership-reclaim-design.md。
public enum BadgeReclaimIPC {
    public static let action = "reclaimBadgeOwnership"
}

/// 主 App 拒绝抢回请求的原因。以 `<rawValue>: <detail>` 形式放进 IPCResponse.message。
public enum BadgeReclaimRejection: String {
    /// 设置中关闭了「自动解决角标冲突」
    case disabled
    /// 目录内没有可见项：收不到角标请求是正常的，不能据此判定丢失归属
    case noVisibleItems
    /// 目录无法读取，无法判定
    case cannotRead
    /// 命中限流
    case rateLimited

    public func message(detail: String) -> String {
        "\(rawValue): \(detail)"
    }
}

/// 扩展视角下一次抢回请求的结果
public enum BadgeReclaimOutcome: Equatable {
    case accepted
    case rejected
    case rejectedNoVisibleItems

    /// 由 IPC 响应映射；超时、未知错误一律视为普通拒绝
    public init(success: Bool, message: String?) {
        if success {
            self = .accepted
        } else if let message, message.hasPrefix(BadgeReclaimRejection.noVisibleItems.rawValue + ":") {
            self = .rejectedNoVisibleItems
        } else {
            self = .rejected
        }
    }
}

/// 扩展进程内的角标归属探测状态机（纯逻辑，不依赖 FinderSync，便于单测）。
///
/// 判定依据：Finder 只向持有归属的扩展回调 requestBadgeIdentifier。某目录收到过其中文件的
/// 角标请求 → 该目录归属确认；观察了目录却迟迟收不到 → 可能丢失，由主 App 核实目录非空后处理。
///
/// 配额：每个扩展进程（每个注册轮次）最多被受理一次抢回（受理后全部注册目录都已取回）；被拒绝只消耗一次
/// 尝试，上限 `maxAttempts`，为剪切时的兜底留出机会。「无可见项」不算尝试，但该目录不再申请。
public struct BadgeOwnershipProbe {

    public static let maxAttempts = 2

    public private(set) var attempts = 0
    public private(set) var reclaimAccepted = false
    /// 已发出、尚未收到响应的请求。同一时刻只允许一个，避免同进程的多个探测互相挤占配额
    public private(set) var reclaimInFlight = false
    /// 注册轮次：本进程每次重新设置 directoryURLs（挂载新卷）后加一
    public private(set) var epoch = 0

    private var ownedDirectories: Set<String> = []
    private var probedDirectories: Set<String> = []
    private var noVisibleItemDirectories: Set<String> = []

    public init() {}

    /// 路径规范化：去尾部斜杠 / `.` / `..`，并统一为 NFC。
    /// 注：Swift `String` 的相等与哈希本身按 Unicode 规范等价（NFD 与 NFC 视为相等），
    /// NFC 只是让日志输出与扩展里既有的 `normalizePath` 保持一致，不是匹配正确性的前提。
    public static func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath.precomposedStringWithCanonicalMapping
    }

    /// requestBadgeIdentifier 回调时调用：确认该文件所在目录的归属
    public mutating func recordBadgeRequest(itemPath: String) {
        let parent = (Self.normalize(itemPath) as NSString).deletingLastPathComponent
        ownedDirectories.insert(parent)
    }

    public func isOwned(directory: String) -> Bool {
        ownedDirectories.contains(Self.normalize(directory))
    }

    /// beginObserving 时调用：返回 true 表示应在延迟后检查该目录（本进程首次观察且尚未确认）
    public mutating func beginProbe(directory: String) -> Bool {
        let dir = Self.normalize(directory)
        guard !ownedDirectories.contains(dir) else { return false }
        return probedDirectories.insert(dir).inserted
    }

    /// 是否可以为该目录发起抢回请求
    public func canRequestReclaim(directory: String) -> Bool {
        let dir = Self.normalize(directory)
        return !reclaimAccepted
            && !reclaimInFlight
            && attempts < Self.maxAttempts
            && !ownedDirectories.contains(dir)
            && !noVisibleItemDirectories.contains(dir)
    }

    /// 主 App 限流用的请求方标识：同一进程的不同注册轮次视为不同请求方
    public func requesterId(pid: Int32) -> String {
        "\(pid):\(epoch)"
    }

    /// 本进程重新设置 directoryURLs 后调用。重新注册等于排到重叠扩展之后，可能已丢失归属：
    /// 作废旧的归属确认，允许重新探测，并重置抢回配额（主 App 按新轮次重新限流）。
    /// 在途请求不受影响，其响应仍会正常结束在途状态。
    public mutating func beginNewRegistrationEpoch() {
        epoch += 1
        attempts = 0
        reclaimAccepted = false
        ownedDirectories.removeAll()
        probedDirectories.removeAll()
        noVisibleItemDirectories.removeAll()
    }

    /// 请求真正发出时调用
    public mutating func noteReclaimAttempt() {
        attempts += 1
        reclaimInFlight = true
    }

    /// 收到主 App 响应时调用
    public mutating func noteReclaimResponse(directory: String, outcome: BadgeReclaimOutcome) {
        reclaimInFlight = false
        switch outcome {
        case .accepted:
            reclaimAccepted = true
        case .rejectedNoVisibleItems:
            attempts = max(0, attempts - 1)
            noVisibleItemDirectories.insert(Self.normalize(directory))
        case .rejected:
            break
        }
    }
}
