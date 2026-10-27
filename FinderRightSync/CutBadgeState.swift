import Cocoa
import FinderSync
import FinderRightKit

// MARK: - 剪切队列（文件 IPC，跨沙箱共享）

/// 剪切队列存储：与主 App 共用 CutQueueStore，保证两侧对同一份队列文件的读写规则一致
private let cutQueueStore = CutQueueStore()

let cutBadgeIdentifier = "com.finderright.badge.cut"

/// 与 Kit 的 BadgeOwnershipProbe.normalize 共用唯一实现（去尾斜杠 / . / ..，统一 NFC）
func normalizePath(_ p: String) -> String {
    BadgeOwnershipProbe.normalize(p)
}

let cutBadgeLock = NSLock()
var inMemoryCutPaths: Set<String> = []
/// 本进程是否打过剪切角标（受 cutBadgeLock 保护）。从未打过时，角标回调无需逐个发送清除消息
var didSetCutBadge = false
/// 打过剪切角标的规范化路径（受 cutBadgeLock 保护）：队列被主 App 改写后据此清掉已不在队列里的角标
private var badgedCutPaths: Set<String> = []

/// 持久化队列的缓存：文件未变化时只 stat、不读盘（角标回调热路径）
private let cutQueueCache = CutQueueCache(store: cutQueueStore)

/// 规范化后的持久化剪切路径
func persistedCutQueuePaths() -> Set<String> {
    cutQueueCache.normalizedPaths()
}

/// 打剪切角标的唯一入口：同时记下「本进程打过角标」
func setCutBadge(for url: URL) {
    cutBadgeLock.lock()
    didSetCutBadge = true
    badgedCutPaths.insert(normalizePath(url.path))
    cutBadgeLock.unlock()
    FIFinderSyncController.default().setBadgeIdentifier(cutBadgeIdentifier, for: url)
}

/// 获取当前待剪切队列中的所有源文件路径集合（内存乐观队列与持久化队列的并集）
/// 主 App 改写剪切队列后（尤其是经服务快捷键剪切 / 粘贴，扩展事先不知情）按落盘队列对齐角标：
/// 落盘队列是权威状态，内存乐观集合只保留仍在队列里的路径；不在队列里的旧角标清掉，队列里的补上。
/// 扩展自己发起的剪切在 IPC 落盘前若碰上别的通知，乐观路径会被短暂剔除，落盘后的通知与 0.4s 补推会再打上。
/// 返回本次新打上角标的路径（此前未打过），调用方据此为其所在目录抢回角标归属。
@discardableResult
func reconcileCutBadgesWithQueue() -> Set<String> {
    let persisted = persistedCutQueuePaths()
    cutBadgeLock.lock()
    inMemoryCutPaths.formIntersection(persisted)
    let stale = badgedCutPaths.subtracting(persisted)
    badgedCutPaths.subtract(stale)
    let added = persisted.subtracting(badgedCutPaths)
    cutBadgeLock.unlock()

    for path in stale {
        FIFinderSyncController.default().setBadgeIdentifier("", for: URL(fileURLWithPath: path))
    }
    for path in persisted {
        setCutBadge(for: URL(fileURLWithPath: path))
    }
    logToFile("cutQueueChanged: badged=\(persisted.count) new=\(added.count) cleared=\(stale.count)")
    return added
}

func currentCutQueuePaths() -> Set<String> {
    cutBadgeLock.lock()
    let memoryPaths = inMemoryCutPaths
    cutBadgeLock.unlock()

    return memoryPaths.union(persistedCutQueuePaths())
}

// MARK: - 角标归属探测（每个扩展进程一份）

/// Finder 回调线程不固定（日志里 requestBadgeIdentifier 来自多个线程），统一加锁访问
private let badgeProbeLock = NSLock()
private var badgeProbe = BadgeOwnershipProbe()

func withBadgeProbe<T>(_ body: (inout BadgeOwnershipProbe) -> T) -> T {
    badgeProbeLock.lock()
    defer { badgeProbeLock.unlock() }
    return body(&badgeProbe)
}

/// 观察目录后多久判定「收不到角标请求」：日志中请求总与 beginObserving 在同一秒内到达
let badgeProbeDelay: TimeInterval = 1.5
/// 主 App 受理抢回后多久核验结果：ignore 停留 2s + Finder 重新请求的余量
let badgeReclaimVerifyDelay: TimeInterval = 3

/// 将角标预先绘制为 2x 位图，避免跨进程传递 NSCustomImageRep 的延迟绘制回调。
///
/// 角标图要经 XPC 交给 Finder 进程渲染，预渲染位图是最稳妥的形态，保持即可。
/// 注意：此前「惰性绘制写法导致角标消失、改回位图后恢复」的结论**不成立** —— 那几轮
/// 时好时坏实际是角标归属权竞争造成的（见下方「文件角标徽章回调」处的说明），
/// 与绘制方式无关。验证角标相关改动时，必须先确认本轮会话扩展确实收到了
/// requestBadgeIdentifier，否则「不显示」无法归因到改动本身。
func createCutBadgeImage() -> NSImage {
    let size = NSSize(width: 32, height: 32)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else {
        return NSImage(size: size)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: 2, y: 2)

    let bg = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 28, height: 28))
    NSColor(calibratedWhite: 0.15, alpha: 0.88).setFill()
    bg.fill()
    bg.lineWidth = 1.5
    NSColor(calibratedWhite: 1.0, alpha: 0.95).setStroke()
    bg.stroke()

    if let scissors = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        (scissors.withSymbolConfiguration(config) ?? scissors)
            .draw(in: NSRect(x: 7.5, y: 7.5, width: 17, height: 17))
    }
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    rep.size = size
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return image
}
