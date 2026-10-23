import Cocoa
import FinderSync
import FinderRightKit
import os.log

private let log = OSLog(subsystem: "com.finderright.app.sync", category: "FinderSync")

// MARK: - 剪切队列（文件 IPC，跨沙箱共享）

/// 剪切队列存储：与主 App 共用 CutQueueStore，保证两侧对同一份队列文件的读写规则一致
private let cutQueueStore = CutQueueStore()

private let cutBadgeIdentifier = "com.finderright.badge.cut"

/// 与 Kit 的 BadgeOwnershipProbe.normalize 共用唯一实现（去尾斜杠 / . / ..，统一 NFC）
private func normalizePath(_ p: String) -> String {
    BadgeOwnershipProbe.normalize(p)
}

private let cutBadgeLock = NSLock()
private var inMemoryCutPaths: Set<String> = []
/// 本进程是否打过剪切角标（受 cutBadgeLock 保护）。从未打过时，角标回调无需逐个发送清除消息
private var didSetCutBadge = false
/// 打过剪切角标的规范化路径（受 cutBadgeLock 保护）：队列被主 App 改写后据此清掉已不在队列里的角标
private var badgedCutPaths: Set<String> = []

/// 持久化队列的缓存：文件未变化时只 stat、不读盘（角标回调热路径）
private let cutQueueCache = CutQueueCache(store: cutQueueStore)

/// 规范化后的持久化剪切路径
private func persistedCutQueuePaths() -> Set<String> {
    cutQueueCache.normalizedPaths()
}

/// 打剪切角标的唯一入口：同时记下「本进程打过角标」
private func setCutBadge(for url: URL) {
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
private func reconcileCutBadgesWithQueue() -> Set<String> {
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

private func currentCutQueuePaths() -> Set<String> {
    cutBadgeLock.lock()
    let memoryPaths = inMemoryCutPaths
    cutBadgeLock.unlock()

    return memoryPaths.union(persistedCutQueuePaths())
}

// MARK: - 角标归属探测（每个扩展进程一份）

/// Finder 回调线程不固定（日志里 requestBadgeIdentifier 来自多个线程），统一加锁访问
private let badgeProbeLock = NSLock()
private var badgeProbe = BadgeOwnershipProbe()

private func withBadgeProbe<T>(_ body: (inout BadgeOwnershipProbe) -> T) -> T {
    badgeProbeLock.lock()
    defer { badgeProbeLock.unlock() }
    return body(&badgeProbe)
}

/// 观察目录后多久判定「收不到角标请求」：日志中请求总与 beginObserving 在同一秒内到达
private let badgeProbeDelay: TimeInterval = 1.5
/// 主 App 受理抢回后多久核验结果：ignore 停留 2s + Finder 重新请求的余量
private let badgeReclaimVerifyDelay: TimeInterval = 3

/// 将角标预先绘制为 2x 位图，避免跨进程传递 NSCustomImageRep 的延迟绘制回调。
///
/// 角标图要经 XPC 交给 Finder 进程渲染，预渲染位图是最稳妥的形态，保持即可。
/// 注意：此前「惰性绘制写法导致角标消失、改回位图后恢复」的结论**不成立** —— 那几轮
/// 时好时坏实际是角标归属权竞争造成的（见下方「文件角标徽章回调」处的说明），
/// 与绘制方式无关。验证角标相关改动时，必须先确认本轮会话扩展确实收到了
/// requestBadgeIdentifier，否则「不显示」无法归因到改动本身。
private func createCutBadgeImage() -> NSImage {
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

// MARK: - 菜单图标


/// 菜单图标渲染：预渲染为 2x 位图并按「风格 + 符号 + 颜色 + 明暗」缓存。
///
/// 菜单要跨进程交给 Finder 绘制，图片在构建菜单时就得定型 —— 不能依赖延迟绘制或动态颜色，
/// 所以按当前系统明暗各画一份。代价是悬停高亮时彩色线条不会反白（模板图才会）。
enum MenuIconRenderer {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()
    private static let side: CGFloat = 16

    static func image(symbol: String, tint: MenuTint, style: MenuIconStyle) -> NSImage? {
        let appearance = NSApplication.shared.effectiveAppearance
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let key = "\(style.rawValue)|\(symbol)|\(tint.name)|\(dark ? "dark" : "light")"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var rendered: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            rendered = render(symbol: symbol, tint: tint, style: style, dark: dark)
        }
        guard let image = rendered else { return nil }
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }

    private static func render(symbol: String, tint: MenuTint, style: MenuIconStyle, dark: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 2, y: 2)

        let glyphColor: NSColor
        let box: NSRect
        let config: NSImage.SymbolConfiguration
        let asTile = style == .tile
        if asTile {
            srgb(dark ? tint.tile.dark : tint.tile.light).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 4, yRadius: 4).fill()
            glyphColor = tint.darkGlyph ? srgb(0x2B2200) : .white
            box = NSRect(x: 2, y: 2, width: 12, height: 12)
            config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        } else {
            glyphColor = style == .modern ? .labelColor : srgb(dark ? tint.line.dark : tint.line.light)
            box = NSRect(x: 0, y: 0, width: side, height: side)
            config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        }
        if asTile, let letter = tileLetter(for: symbol) {
            // 方块本身就是框：字母类符号（p.square 等）去掉外框，直接画字母，避免框套框
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: glyphColor,
            ]
            let size = (letter as NSString).size(withAttributes: attrs)
            (letter as NSString).draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
        } else {
            let source = asTile ? tileSymbol(for: symbol).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) } ?? base : base
            let glyph = source.withSymbolConfiguration(config.applying(.init(paletteColors: [glyphColor]))) ?? source
            glyph.draw(in: fitted(glyph.size, in: box))
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        rep.size = NSSize(width: side, height: side)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        // Finder 跨进程绘制时保留当前文字色，同时保留模板标记供菜单处理高亮。
        image.isTemplate = style == .modern
        return image
    }

    /// 单字母方框符号（如 p.square）在方块风格下改画的字母
    private static func tileLetter(for symbol: String) -> String? {
        guard symbol.hasSuffix(".square") else { return nil }
        let inner = symbol.dropLast(".square".count)
        return inner.count == 1 ? inner.uppercased() : nil
    }

    /// 自带外框的符号在方块风格下换成无框版本（如 dollarsign.square → dollarsign）
    private static func tileSymbol(for symbol: String) -> String? {
        switch symbol {
        case "dollarsign.square": return "dollarsign"
        case "play.rectangle": return "play.fill"
        default: return nil
        }
    }

    /// 等比缩小并居中，宽符号（如 </>）不会被拉伸或溢出
    private static func fitted(_ size: NSSize, in box: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(1, box.width / size.width, box.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return NSRect(x: box.midX - width / 2, y: box.midY - height / 2, width: width, height: height)
    }

    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}

// MARK: - 日志

private let logQueue = DispatchQueue(label: "com.finderright.app.sync.log", qos: .utility)
private let logDateFormatter: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return df
}()

private func logToFile(_ message: String) {
    // 1. 系统统一 OSLog（主线程毫秒级开销）
    // private：统一日志里路径等内容默认脱敏，避免留下可被任意进程读取的浏览记录
    os_log("%{private}@", log: log, type: .default, message)

    // 2. 本地调试文件：异步串行派发到后台队列，避免主线程磁盘 I/O 阻塞
    let timestamp = logDateFormatter.string(from: Date())
    logQueue.async {
        let fm = FileManager.default
        // 与 IPC 共用已授权目录，避免容器 Documents 日志被 TCC 阻止读取。
        let logDir = IPCBridge.rootDirectory
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logFile = logDir.appendingPathComponent("extension-debug.log")
        let oldLogFile = logDir.appendingPathComponent("extension-debug.log.1")
        let maxBytes: UInt64 = 1024 * 1024 // 1MB

        if let attrs = try? fm.attributesOfItem(atPath: logFile.path),
           let size = attrs[.size] as? UInt64, size >= maxBytes {
            try? fm.removeItem(at: oldLogFile)
            try? fm.moveItem(at: logFile, to: oldLogFile)
        }

        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logFile.path) {
            if let h = try? FileHandle(forWritingTo: logFile) {
                h.seekToEndOfFile(); h.write(data); h.closeFile()
            }
        } else {
            try? data.write(to: logFile)
        }
    }
}

// MARK: - FinderSync

class FinderSync: FIFinderSync {

    // MARK: - 静态图标与资源缓存（零 I/O、零解析延迟）
    private static let cacheQueue = DispatchQueue(label: "com.finderright.app.sync.cache", qos: .utility)

    private static func getSymbolImage(named name: String) -> NSImage? {
        MenuIconRenderer.image(symbol: name, tint: .graphite, style: .modern)
    }

    private static func preloadSymbols() {
        let symbols = [
            "doc.badge.plus", "link", "character.cursor.ibeam", "arrow.right.circle",
            "terminal", "curlybraces", "scissors", "doc.on.clipboard", "xmark.circle",
            "arrowshape.turn.up.right", "plus.square.on.square", "doc.zipper",
            "shippingbox.and.arrow.backward", "eye"
        ]
        for s in symbols {
            _ = getSymbolImage(named: s)
        }
    }

    /// 冷启动打点：init 入口时间（进程被拉起后尽早记录）
    private static var initStartUptime: TimeInterval = 0
    private var didDeferredSetup = false
    /// 当前构建的新建文件菜单项缓存，供 newFile(_ sender:) 按 tag 索引
    private var activeNewFileTemplates: [NewFileTemplateItem] = []

    override init() {
        Self.initStartUptime = ProcessInfo.processInfo.systemUptime
        super.init()

        // init 路径刻意保持极简：只有 directoryURLs 注册是扩展工作的前提。
        // 符号预热等全部延后到首次 menu(for:) 之后（见 deferredSetupIfNeeded），
        // 让系统回收扩展后的首次右键等待时间降到最低。
        let dirs = Self.buildMonitoredDirectories()
        FIFinderSyncController.default().directoryURLs = dirs

        // 注册剪切状态文件角标徽章（Finder 文件图标右下角显示）。
        // label 只是角标的辅助功能描述，界面上不可见，用字面量即可；菜单文案的本地化走 L()。
        logToFile("setBadgeImage registering: \(cutBadgeIdentifier)")
        FIFinderSyncController.default().setBadgeImage(createCutBadgeImage(), label: "已剪切", forBadgeIdentifier: cutBadgeIdentifier)
        logToFile("setBadgeImage registered for \(cutBadgeIdentifier)")

        // 服务快捷键剪切 / 粘贴由主 App 直接处理，扩展只能靠这条通知得知队列变化。
        // 必须在 init 注册：只用快捷键、从不展开右键菜单时，延后初始化永远不会执行。
        CutQueueChangeNotifier.observe { [weak self] in self?.handleCutQueueChanged() }

        // 后台预热编辑器与图标（派发即返回，不阻塞 init）
        Self.refreshInstalledEditorsAsync()

        let initMs = (ProcessInfo.processInfo.systemUptime - Self.initStartUptime) * 1000
        // 版本号写进日志：排查角标/回调问题时必须能区分「装的是哪一版扩展」
        let extVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        logToFile("init done: pid=\(getpid()) v\(extVersion) \(String(format: "%.1f", initMs))ms monitoredDirs=\(dirs.map(\.path).sorted())")
    }

    // MARK: - 文件角标徽章回调

    /// ⚠️ 角标归属权：同一个目录被多个 Finder Sync 扩展注册时，Finder 只把
    /// requestBadgeIdentifier 交给**最先注册**该目录的扩展（即使它根本不用角标），
    /// 其余扩展只收到 beginObserving / 菜单回调，setBadgeIdentifier 也不会显示。
    /// 各扩展随 Finder 启动并发注册，先后顺序不确定，于是表现为「同一二进制有的会话
    /// 0 次回调、有的会话 200+ 次」。参考：Keka issue #608、FB7711264、Apple DTS 答复
    /// （Finder Sync 按「一个目录一个后备扩展」设计，重叠时归属不可靠）。
    ///
    /// 2026-10-02 实测：Keka 的 MonitoredURLs 与本扩展完全重叠（~/Desktop、~/Documents、
    /// ~/Downloads、/Volumes），是角标时有时无的直接原因；本扩展进程重启（例如重复
    /// `pluginkit -a`）会让我们成为最后注册者，重叠目录全部失去归属。
    ///
    /// 应对：收到本回调即证明持有该目录归属（记入 badgeProbe）；观察了目录却收不到时，
    /// 请主 App 短暂重启其他扩展取回归属（见 requestBadgeReclaimIfNeeded）。
    override func requestBadgeIdentifier(for url: URL) {
        withBadgeProbe { $0.recordBadgeRequest(itemPath: url.path) }
        // 热路径：大目录会为每个可见文件回调一次。不逐项写日志（性能 + 不留浏览记录）
        if currentCutQueuePaths().contains(normalizePath(url.path)) {
            logToFile("requestBadgeIdentifier: 剪切项 \(url.lastPathComponent)")
            setCutBadge(for: url)
            return
        }
        // 本进程从未打过剪切角标时，Finder 上不可能有我们的旧角标，无需逐个发清除消息
        cutBadgeLock.lock()
        let mayHaveStaleBadge = didSetCutBadge
        cutBadgeLock.unlock()
        if mayHaveStaleBadge {
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
        }
    }

    /// 首次菜单构建之后执行的一次性延后初始化（冷启动瘦身的一部分）
    private func deferredSetupIfNeeded() {
        guard !didDeferredSetup else { return }
        didDeferredSetup = true

        // SF Symbols 预热（getSymbolImage 本身带懒缓存兜底，这里只是提前摊销）
        Self.preloadSymbols()

        // 卷挂载监听延后注册，并补并一次 init 之后、监听注册之前挂载的卷（集合未变化时不会重设）。
        // 只监听挂载、不监听卸载（见 volumeDidMount）。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(volumeDidMount(_:)),
            name: NSWorkspace.didMountNotification, object: nil)
        mergeMountedVolumes()
        logToFile("deferredSetup done")
    }

    /// 新卷挂载：把新卷并入监控集合。
    ///
    /// 重新设置 directoryURLs 等于重新注册，会让本扩展排到重叠扩展之后、可能丢失角标归属，
    /// 所以：只并入、不剔除（卸载卷的残留路径无害，不为它重设）；集合未变化时不重设；
    /// 重设后开启新的探测轮次，由归属探测 / 剪切兜底按需重新抢回。
    @objc func volumeDidMount(_ n: Notification) {
        mergeMountedVolumes()
    }

    private func mergeMountedVolumes() {
        let current = FIFinderSyncController.default().directoryURLs ?? []
        let merged = current.union(Self.buildMonitoredDirectories())
        guard merged != current else { return }
        FIFinderSyncController.default().directoryURLs = merged
        withBadgeProbe { $0.beginNewRegistrationEpoch() }
        logToFile("mergeMountedVolumes: directoryURLs 重新注册 count=\(merged.count)，开启新一轮角标归属探测")
    }

    /// 构建需要监控的目录集合：用户主目录 + 桌面/下载/文稿 + 已挂载卷。
    ///
    /// ⚠️ 外接卷必须逐个注册：2026-10-02 实测只注册 `/Volumes` 时，Finder 对 `/Volumes/E`
    /// 等卷内目录**不会**回调 beginObserving / menu(for:)（目录匹配按卷进行，不跨卷继承）。
    /// 这也是挂载新卷时不得不重新设置 directoryURLs 的原因（见 volumeDidMount）。
    ///
    /// FIFinderSync 只有当 Finder 当前目录在 directoryURLs 集合内（或其子目录内）时，
    /// 才会触发右键菜单与 requestBadgeIdentifier 回调。
    ///
    /// 这里显式列出 Desktop / Downloads / Documents 的真实路径，而不用
    /// `FileManager.urls(for:in:)`：沙箱 appex 里后者返回的是容器内私有路径
    /// （实测：…/Library/Containers/com.finderright.app.sync/Data/Desktop，且该目录并不存在），
    /// 注册等于没注册。真实目录本已被 home 覆盖，显式再列一次是无害的兜底。
    /// 注意：精确注册这些目录**不能**帮我们赢得角标归属 —— 其他扩展（如 Keka）注册了
    /// 完全相同的路径时仍是先注册者胜出（见 requestBadgeIdentifier 处的说明）。
    ///
    /// 注意：iCloud Drive、Google Drive 等云盘是 macOS 的 **File Provider 域**，目录归提供者
    /// 自己的扩展。Apple DTS 说明 Finder Sync 按「一个目录只归属一个扩展」设计，第三方扩展
    /// 本就不应期望在其中生效（https://github.com/aonez/Keka/issues/1327 中转述的 DTS 答复）。
    /// 实测：对这些路径的 directoryURLs 注册（含经安全书签授予目录访问后）不会触发
    /// `beginObservingDirectory` / `menu(for:)` 回调，且与完全磁盘访问无关 —— 那是文件权限，
    /// 这是扩展点按目录归属的路由。
    /// 因此这里不再尝试注册云盘路径；云盘文件夹的右键操作改由主 App 的 macOS Services 提供
    /// （见主 App 的 `ServicesProvider`）。
    private static func buildMonitoredDirectories() -> Set<URL> {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: "/Users/\(NSUserName())")
        var dirs: Set<URL> = [
            home,
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Documents")
        ]

        // 已挂载的物理 / 网络卷（/Volumes/E 等外接硬盘；也可能是 ~/OrbStack 这类挂载点）。
        // 不包含启动卷 /：系统目录的右键操作由 Services 覆盖。
        if let volumes = fm.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) {
            for vol in volumes {
                let p = vol.path
                if p != "/" && !p.hasPrefix("/System") && !p.hasPrefix("/private") {
                    dirs.insert(vol)
                }
            }
        }

        return dirs
    }

    // MARK: - 上下文

    private func currentContext() -> (directory: URL?, selectedItems: [URL]) {
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        let target = FIFinderSyncController.default().targetedURL()
        let dir = target ?? selected.first?.deletingLastPathComponent()
        return (dir, selected)
    }

    private func resolveWorkingDirectory() -> URL? {
        let (target, selected) = currentContext()
        if let first = selected.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir), isDir.boolValue {
                return first
            }
        }
        return target
    }

    // MARK: - Directory Observation

    /// Finder 开始显示某个受监控目录时调用。目录内有剪切项、且本进程首次观察该目录时，顺带做一次角标归属探测：
    /// 持有归属的扩展会在同一秒内收到目录内可见项的 requestBadgeIdentifier，收不到则可能已丢失。
    override func beginObservingDirectory(at url: URL) {
        logToFile("beginObserving: \(url.path)")
        let dir = url.path
        // 只为确实含有剪切项的目录探测归属：没有剪切项就不需要角标，不应为此重启其他扩展
        guard BadgeOwnershipProbe.directory(dir, containsAnyOf: currentCutQueuePaths()) else { return }
        guard withBadgeProbe({ $0.beginProbe(directory: dir) }) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + badgeProbeDelay) { [weak self] in
            // 等待期间可能已粘贴或取消剪切，届时同样不再需要抢回
            guard BadgeOwnershipProbe.directory(dir, containsAnyOf: currentCutQueuePaths()) else { return }
            self?.requestBadgeReclaimIfNeeded(directory: dir, reason: "probe")
        }
    }

    /// 剪切队列被主 App 改写：对齐角标；快捷键剪切与右键剪切一样，需为新剪切项所在目录兜底抢回角标归属，
    /// 否则目录归属在别的 Finder Sync 扩展手里时角标根本不显示，看起来像「剪切没生效」。
    private func handleCutQueueChanged() {
        let added = reconcileCutBadgesWithQueue()
        let parents = Set(added.map { ($0 as NSString).deletingLastPathComponent })
        for dir in parents {
            requestBadgeReclaimIfNeeded(directory: dir, reason: "cut")
        }
    }

    override func endObservingDirectory(at url: URL) {
        logToFile("endObserving: \(url.path)")
    }

    // MARK: - 角标归属抢回

    /// 目录归属未确认时，请主 App 短暂重启其他 Finder Sync 扩展以取回角标归属。
    ///
    /// - reason `probe`：目录观察后的被动探测。主 App 未运行时不发（IPC 会唤醒主 App，
    ///   不应因被动探测拉起用户主动退出的 App），留给剪切时兜底。
    /// - reason `cut`：剪切时兜底，剪切本身就会唤醒主 App。
    ///
    /// 配额与并发由 BadgeOwnershipProbe 约束：每进程至多受理一次、同一时刻一个在途请求；
    /// 探测撞上在途请求时稍后重试，确保同时观察的多个目录不会被漏判。
    private func requestBadgeReclaimIfNeeded(directory: String, reason: String) {
        let (owned, inFlight, allowed) = withBadgeProbe {
            ($0.isOwned(directory: directory), $0.reclaimInFlight, $0.canRequestReclaim(directory: directory))
        }
        if owned {
            if reason == "probe" { logToFile("badgeProbe dir=\(directory) owned") }
            return
        }
        if inFlight {
            if reason == "probe" {
                DispatchQueue.main.asyncAfter(deadline: .now() + badgeProbeDelay) { [weak self] in
                    self?.requestBadgeReclaimIfNeeded(directory: directory, reason: reason)
                }
            }
            return
        }
        guard allowed else { return }

        SharedConfig.shared.reload()
        guard SharedConfig.shared.badgeOwnershipReclaim else {
            logToFile("badgeProbe dir=\(directory) lost（自动解决角标冲突已关闭）")
            return
        }
        if reason == "probe",
           NSRunningApplication.runningApplications(withBundleIdentifier: IPCBridge.mainAppBundleIdentifier).isEmpty {
            logToFile("badgeProbe dir=\(directory) lost（主 App 未运行，留待剪切时兜底）")
            return
        }

        withBadgeProbe { $0.noteReclaimAttempt() }
        logToFile("badgeReclaim request reason=\(reason) dir=\(directory)")
        IPCClient.shared.callAsync(action: BadgeReclaimIPC.action, payload: [
            "directory": .string(directory),
            "requester": .string(withBadgeProbe { $0.requesterId(pid: getpid()) }),
            "reason": .string(reason)
        ], timeout: 5) { r in
            let outcome = BadgeReclaimOutcome(success: r.success, message: r.message)
            withBadgeProbe { $0.noteReclaimResponse(directory: directory, outcome: outcome) }
            guard outcome == .accepted else {
                logToFile("badgeReclaim rejected dir=\(directory) msg=\(r.message ?? "")")
                return
            }
            logToFile("badgeReclaim accepted dir=\(directory)")
            DispatchQueue.main.asyncAfter(deadline: .now() + badgeReclaimVerifyDelay) {
                let regained = withBadgeProbe { $0.isOwned(directory: directory) }
                logToFile(regained
                    ? "badgeReclaim verified dir=\(directory)"
                    : "badgeReclaim still lost dir=\(directory)（可能来自 File Provider 域等无法处理的接管）")
            }
        }
    }

    // MARK: - Context Menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu {
        let menuStart = ProcessInfo.processInfo.systemUptime
        // 读取主 App 设置界面最新写入的功能开关 / 终端 / 编辑器偏好
        SharedConfig.shared.reload()

        let (directory, selected) = currentContext()
        let hasSelection = !selected.isEmpty
        let exts = selected.prefix(10).map { $0.pathExtension.lowercased() }.joined(separator: ",")
            + (selected.count > 10 ? "..." : "")
        logToFile("menu(for:) kind=\(menuKind.rawValue) selected=\(selected.count) exts=[\(exts)] dir=\(directory?.lastPathComponent ?? "nil")")

        let menu = NSMenu(title: "FinderRight")
        let style = SharedConfig.shared.menuIconStyle

        // 功能开关：默认开启，用户在设置里关闭后对应菜单项隐藏
        func featureOn(_ id: String) -> Bool { SharedConfig.shared.isActionEnabled(id) }

        let isContainerLike = menuKind == .contextualMenuForContainer
            || menuKind == .contextualMenuForSidebar
            || !hasSelection

        // 在窗口空白处右键（容器菜单）时，Finder 会把当前目录本身放进 selectedItemURLs()，
        // hasSelection 因此为真。复制路径、打开编辑器作用于当前目录无害且有用，照常显示；
        // 但剪切 / 移动到 / 复制到 / 压缩会改动当前目录本身，必须是用户真正选中了条目才显示
        let hasExplicitSelection = hasSelection && menuKind != .contextualMenuForContainer

        // 剪切队列状态：剪切 / 粘贴 / 取消剪切的显示与文案都依赖它
        let cutPaths = currentCutQueuePaths()
        let hasCut = !cutPaths.isEmpty

        // 兜底刷新角标：对仍处于剪切队列的选中项再推一次角标标识，覆盖重绘时序问题。
        // 注意这只在本扩展持有该目录角标归属时有效；归属被其他扩展占走时推多少次都不会显示
        // （见 requestBadgeIdentifier 处的说明）。
        // 上限 50 项，避免「全选大目录」时拖慢菜单构建。
        if hasSelection, hasCut {
            var pushed = 0
            for url in selected.prefix(50) where cutPaths.contains(normalizePath(url.path)) {
                setCutBadge(for: url)
                pushed += 1
            }
            if pushed > 0 { logToFile("menu(for:) badge refresh: \(pushed) cut item(s)") }
        }

        let cancelCutItem = { self.makeItem(titleKey: "取消剪切", tint: .red, systemImage: "xmark.circle", action: #selector(self.cancelCut(_:)), shortcutId: nil, style: style) }

        // 每个功能一个构建闭包，按用户在设置里拖拽排好的顺序依次添加。
        // 显示条件与功能开关在闭包内判断；「取消剪切」没有独立开关，依附在剪切之后、随剪切一起排序
        let builders: [String: () -> Void] = [
            MenuFeatureCatalog.undo: {
                // 主 App 有可撤销的记录时才写这个状态文件；文件里只有显示信息，不含路径
                guard let state = UndoMenuState.read() else { return }
                let item = self.makeItem(titleKey: "撤销", tint: .gray, systemImage: "arrow.uturn.backward", action: #selector(self.undoLast(_:)), shortcutId: "shortcut.undo", style: style)
                item.title = UndoText.menuTitle(for: state, localize: self.L)
                menu.addItem(item)
            },
            MenuFeatureCatalog.newFile: {
                // 新建文件 —— 容器/侧边栏/空选中时
                guard isContainerLike else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "新建文件", tint: .blue, systemImage: "doc.badge.plus", shortcutId: "shortcut.newFile", style: style, build: { self.buildNewFileMenu(style: style) }))
            },
            MenuFeatureCatalog.copyPath: {
                guard hasSelection else { return }
                menu.addItem(self.makeItem(titleKey: "复制路径", tint: .indigo, systemImage: "link", action: #selector(self.copyPath(_:)), shortcutId: "shortcut.copyPath", style: style))
            },
            MenuFeatureCatalog.copyFileName: {
                guard hasSelection else { return }
                menu.addItem(self.makeItem(titleKey: "复制文件名", tint: .indigo, systemImage: "character.cursor.ibeam", action: #selector(self.copyFileName(_:)), shortcutId: "shortcut.copyFileName", style: style))
            },
            MenuFeatureCatalog.copyFileContent: {
                // 仅单选普通文本文件且在大小限制内时显示
                guard selected.count == 1, let url = selected.first else { return }
                guard FileContentReader.isEligible(url: url, maxBytes: SharedConfig.shared.copyFileContentMaxBytes) else { return }
                menu.addItem(self.makeItem(titleKey: "复制文件内容", tint: .teal, systemImage: "doc.plaintext", action: #selector(self.copyFileContent(_:)), shortcutId: "shortcut.copyFileContent", style: style))
            },
            MenuFeatureCatalog.goToDirectory: {
                menu.addItem(self.makeItem(titleKey: "打开路径…", tint: .cyan, systemImage: "arrow.right.circle", action: #selector(self.goToDirectory(_:)), shortcutId: "shortcut.goToDirectory", style: style))
            },
            MenuFeatureCatalog.openTerminal: {
                let config = SharedConfig.shared
                let terminals = TerminalCatalog.menuTerminals(
                    selected: config.selectedTerminals, preferred: config.preferredTerminal,
                    order: config.terminalOrder)
                guard !terminals.isEmpty else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "打开终端", tint: .graphite, systemImage: "terminal", shortcutId: "shortcut.openTerminal", style: style, build: { self.buildTerminalMenu(terminals, style: style) }))
            },
            MenuFeatureCatalog.openEditor: {
                guard hasSelection else { return }
                let editors = self.installedEditors()
                guard !editors.isEmpty else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "打开编辑器", tint: .purple, systemImage: "curlybraces", shortcutId: "shortcut.openEditor", style: style, build: { self.buildEditorMenu(editors, style: style) }))
            },
            MenuFeatureCatalog.cut: {
                if hasExplicitSelection {
                    let selectedPaths = Set(selected.map(\.path))
                    let alreadyCut = !selectedPaths.isEmpty && selectedPaths.isSubset(of: cutPaths)
                    let cutTitleKey = alreadyCut ? "剪切 (已在剪切队列)" : "剪切"
                    menu.addItem(self.makeItem(titleKey: cutTitleKey, tint: .orange, systemImage: "scissors", action: #selector(self.cutFiles(_:)), shortcutId: "shortcut.cut", style: style))
                }
                if hasCut {
                    menu.addItem(cancelCutItem())
                }
            },
            MenuFeatureCatalog.paste: {
                if hasCut || isContainerLike {
                    let pasteTitleKey = hasCut
                        ? String(format: self.L("粘贴 (已剪切 %d 项)"), cutPaths.count)
                        : "粘贴"
                    let pasteItem = self.makeItem(titleKey: pasteTitleKey, tint: .orange, systemImage: "doc.on.clipboard", action: #selector(self.pasteFiles(_:)), shortcutId: "shortcut.paste", style: style)
                    pasteItem.isEnabled = hasCut
                    menu.addItem(pasteItem)
                }
            },
            MenuFeatureCatalog.moveTo: {
                guard hasExplicitSelection else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "移动到", tint: .green, systemImage: "arrowshape.turn.up.right", shortcutId: nil, style: style, build: { self.buildFavoritesMenu(mode: .move, selected: selected, style: style) }))
            },
            MenuFeatureCatalog.copyTo: {
                guard hasExplicitSelection else { return }
                menu.addItem(self.makeSubmenuItem(titleKey: "复制到", tint: .green, systemImage: "plus.square.on.square", shortcutId: nil, style: style, build: { self.buildFavoritesMenu(mode: .copy, selected: selected, style: style) }))
            },
            MenuFeatureCatalog.compress: {
                guard hasExplicitSelection else { return }
                menu.addItem(self.makeItem(titleKey: "压缩为 ZIP", tint: .brown, systemImage: "doc.zipper", action: #selector(self.archiveOperation(_:)), shortcutId: "shortcut.compress", tag: 0, style: style))
            },
            MenuFeatureCatalog.decompress: {
                guard hasSelection, selected.contains(where: { ArchiveKind.isArchive(fileName: $0.lastPathComponent) }) else { return }
                menu.addItem(self.makeItem(titleKey: "解压到当前目录", tint: .brown, systemImage: "shippingbox.and.arrow.backward", action: #selector(self.archiveOperation(_:)), shortcutId: "shortcut.decompress", tag: 2, style: style))
            },
            MenuFeatureCatalog.toggleHidden: {
                // 无状态固定文案：CGEvent 切换是 fire-and-forget（无回执），跨进程读
                // com.apple.finder 偏好又命中 cfprefsd 客户端缓存，**不存在可靠的状态通道** ——
                // 「显示/隐藏」状态文案曾两轮实测反转（并留下过 settings.plist 里的死值
                // showHiddenFiles，该键已彻底删除）。固定文案永不撒谎，代价是不显示当前状态。
                // 因此主 App 启动时也不需要把任何状态锚定到 Finder 真实状态（见 FinderRightApp）。
                menu.addItem(self.makeItem(
                    titleKey: "切换隐藏文件",
                    tint: .pink,
                    systemImage: "eye",
                    action: #selector(self.toggleHiddenFiles(_:)),
                    shortcutId: "shortcut.toggleHidden",
                    style: style
                ))
            },
        ]

        for feature in MenuFeatureCatalog.ordered(by: SharedConfig.shared.menuOrder) where featureOn(feature.id) {
            builders[feature.id]?()
        }

        // 「取消剪切」平时紧跟「剪切」，但它不能跟着「剪切」开关一起消失：
        // 用户可能先剪切了一批文件，再到设置里关掉「剪切」，此时队列仍在，
        // 没有入口就只能靠「粘贴」或重启 App 才能清掉。开关关掉时补在「粘贴」后面。
        if hasCut, !featureOn(MenuFeatureCatalog.cut) {
            let item = cancelCutItem()
            let pasteIndex = menu.items.firstIndex { $0.action == #selector(self.pasteFiles(_:)) }
            if let pasteIndex {
                menu.insertItem(item, at: pasteIndex + 1)
            } else {
                menu.addItem(item)
            }
        }

        // 冷启动打点：仅首次菜单记录 init→首菜单间隔与菜单构建耗时，之后执行延后初始化
        if !didDeferredSetup {
            let sinceInitMs = (menuStart - Self.initStartUptime) * 1000
            let buildMs = (ProcessInfo.processInfo.systemUptime - menuStart) * 1000
            logToFile("coldStart: initToFirstMenu=\(String(format: "%.1f", sinceInitMs))ms firstMenuBuild=\(String(format: "%.1f", buildMs))ms")
        }
        deferredSetupIfNeeded()
        return menu
    }

    // MARK: - 菜单构建辅助

    private static let englishBundle: Bundle? = {
        guard let path = Bundle.main.path(forResource: "en", ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }()

    /// 本地化菜单标题（按 SharedConfig.appLanguage 选择资源或系统本地化）
    private func L(_ title: String) -> String {
        switch SharedConfig.shared.appLanguage {
        case "en":
            return Self.englishBundle?.localizedString(forKey: title, value: nil, table: nil) ?? title
        case "zh-Hans":
            return title
        default:
            return NSLocalizedString(title, comment: "menu item")
        }
    }

    /// 根据配置的图标风格（单色线条 / 彩色线条 / 彩色方块 / 无图标）设置菜单项的标题与图标
    private func configureMenuItem(
        _ item: NSMenuItem,
        titleKey: String,
        tint: MenuTint,
        systemImage: String?,
        style: MenuIconStyle
    ) {
        item.title = L(titleKey)
        guard let systemImage else {
            item.image = nil
            return
        }
        switch style {
        case .modern:
            item.image = Self.getSymbolImage(named: systemImage)
        case .tinted, .tile:
            item.image = MenuIconRenderer.image(symbol: systemImage, tint: tint, style: style)
        case .none:
            item.image = nil
        }
    }

    /// 构建通用菜单项（支持快捷键、tag 与图标风格自适应）
    private func makeItem(
        titleKey: String,
        tint: MenuTint,
        systemImage: String?,
        action: Selector? = nil,
        shortcutId: String? = nil,
        tag: Int = 0,
        style: MenuIconStyle
    ) -> NSMenuItem {
        let sc = shortcutId.flatMap { SharedConfig.shared.shortcut(forActionId: $0) }
        let key = sc?.key ?? ""
        let i = NSMenuItem(title: "", action: action, keyEquivalent: key)
        i.target = self
        i.tag = tag
        if let sc = sc, !key.isEmpty {
            i.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: UInt(sc.modifiers))
        }
        configureMenuItem(i, titleKey: titleKey, tint: tint, systemImage: systemImage, style: style)
        return i
    }

    private func makeSubmenuItem(
        titleKey: String,
        tint: MenuTint,
        systemImage: String?,
        shortcutId: String? = nil,
        style: MenuIconStyle,
        build: () -> NSMenu
    ) -> NSMenuItem {
        let i = makeItem(titleKey: titleKey, tint: tint, systemImage: systemImage, shortcutId: shortcutId, style: style)
        i.setSubmenuOrSingleAction(build())
        return i
    }

    private func buildNewFileMenu(style: MenuIconStyle) -> NSMenu {
        let m = NSMenu(title: L("新建文件"))
        let customTemplates = SharedConfig.shared.customFileTemplates
        let order = SharedConfig.shared.newFileOrder
        let hidden = SharedConfig.shared.hiddenNewFileTemplates
        let allTemplates = NewFileTemplateCatalog.resolvedTemplates(order: order, customTemplates: customTemplates)
        let activeTemplates = allTemplates.filter { !hidden.contains($0.id) }
        self.activeNewFileTemplates = activeTemplates

        for (index, item) in activeTemplates.enumerated() {
            let title = item.isCustom ? (item.name.isEmpty ? ".\(item.fileExtension)" : "\(item.name) (.\(item.fileExtension))") : item.name
            let menuItem = makeItem(titleKey: title, tint: item.tint, systemImage: item.systemImage, action: #selector(newFile(_:)), tag: index, style: style)
            m.addItem(menuItem)
        }

        return m
    }

    // MARK: - Actions

    @objc func newFile(_ sender: NSMenuItem) {
        guard let dir = currentContext().directory else {
            logToFile("newFile: no directory"); return
        }
        let index = sender.tag
        guard activeNewFileTemplates.indices.contains(index) else {
            logToFile("newFile: template index out of bounds (\(index))"); return
        }
        let item = activeNewFileTemplates[index]
        if item.isOffice {
            logToFile("newFile ipc (async) → dir=\(dir.lastPathComponent) template=\(item.fileExtension)")
            IPCClient.shared.callAsync(action: "createFile", payload: [
                "directory": .string(dir.path),
                "baseName": .string("untitled"),
                "template": .string(item.fileExtension)
            ]) { r in
                logToFile("newFile ipc result: success=\(r.success) msg=\(r.message ?? "")")
            }
            return
        }

        logToFile("newFile ipc (async) → dir=\(dir.lastPathComponent) tag=\(sender.tag) ext=\(item.fileExtension)")
        IPCClient.shared.callAsync(action: "createFile", payload: [
            "directory": .string(dir.path),
            "baseName": .string("untitled"),
            "ext": .string(item.fileExtension),
            "content": .string(item.content)
        ]) { r in
            logToFile("newFile ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("copyPath: no items"); return }
        // 主目录必须用真实路径：沙箱扩展里 NSHomeDirectory() 指向自己的容器目录
        let format = SharedConfig.shared.copyPathFormat
        let path = PathFormatter.string(for: urls, format: format, home: IPCBridge.realUserHomeDirectory.path)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(path, forType: .string) else {
            logToFile("copyPath: pasteboard write failed"); return
        }
        ClipboardToast.showCopied()
        logToFile("copyPath ok: count=\(urls.count) format=\(format.rawValue)")
    }

    @objc func copyFileName(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("copyFileName: no items"); return }
        let names = PathFormatter.string(for: urls, format: .name, home: IPCBridge.realUserHomeDirectory.path)
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(names, forType: .string) else {
            logToFile("copyFileName: pasteboard write failed"); return
        }
        ClipboardToast.showCopied()
        logToFile("copyFileName ok: count=\(urls.count)")
    }

    @objc func copyFileContent(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard urls.count == 1, let url = urls.first else {
            logToFile("copyFileContent: not single item")
            return
        }
        logToFile("copyFileContent: sending ipc for \(url.path)")
        IPCClient.shared.callAsync(action: "copyFileContent", payload: ["path": .string(url.path)]) { r in
            logToFile("copyFileContent ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    private var terminalMenuIds: [String] = []

    private func buildTerminalMenu(_ terminals: [KnownTerminal], style: MenuIconStyle) -> NSMenu {
        let menu = NSMenu(title: L("打开终端"))
        terminalMenuIds = terminals.map(\.bundleIdentifier)
        for (index, terminal) in terminals.enumerated() {
            menu.addItem(makeItem(titleKey: terminal.name, tint: .graphite, systemImage: terminal.icon,
                                  action: #selector(openTerminal(_:)), tag: index, style: style))
        }
        return menu
    }

    @objc func openTerminal(_ sender: NSMenuItem) {
        guard let dir = resolveWorkingDirectory() else {
            logToFile("openTerminal: no dir"); return
        }
        guard terminalMenuIds.indices.contains(sender.tag) else {
            logToFile("openTerminal: bad tag \(sender.tag)"); return
        }
        let bundleId = terminalMenuIds[sender.tag]
        logToFile("openTerminal ipc (async) → dir=\(dir.lastPathComponent) bundle=\(bundleId)")
        IPCClient.shared.callAsync(action: "openTerminal", payload: [
            "directory": .string(dir.path),
            "bundleId": .string(bundleId)
        ]) { r in
            logToFile("openTerminal ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    // MARK: - 编辑器探测与图标缓存（零等待内存快照 + 后台静默刷新）
    //
    // 线程模型：快照整体由 editorCacheLock 保护（持锁时间仅为字典读写，纳秒级），
    // 耗时的 LaunchServices 查询与 icns 读取一律在 cacheQueue 串行队列的锁外完成，
    // 主线程 menu(for:) 只取快照，绝不被后台刷新阻塞。
    private struct EditorCacheSnapshot {
        /// 经过文档编辑能力校验的应用快照
        var editors: [KnownEditor] = []
        /// 上次检测覆盖到的手动添加项；设置里新增的项不在其中时需要补检
        var checkedCustomIds: Set<String> = []
        var icons: [String: NSImage] = [:]
        var lastCheckTime: TimeInterval = 0
        /// 区分「还没检测过」与「检测结果为空」——否则一台没装任何编辑器的机器
        /// 会让每次右键都走同步 LaunchServices 探测
        var hasChecked = false
    }

    private static let editorCacheLock = NSLock()
    private static var editorCache = EditorCacheSnapshot()
    /// 仅允许在 cacheQueue 串行队列上访问
    private static var isRefreshingEditors = false
    /// 最近一次构建的「打开编辑器」子菜单中各项的 bundle id，菜单项 tag 即其下标（受 editorCacheLock 保护）
    private static var editorMenuIds: [String] = []

    private static func editorSnapshot() -> EditorCacheSnapshot {
        editorCacheLock.lock()
        defer { editorCacheLock.unlock() }
        return editorCache
    }

    /// 启动时或后台静默刷新编辑器与图标（绝不阻塞主线程）
    static func refreshInstalledEditorsAsync() {
        cacheQueue.async {
            guard !isRefreshingEditors else { return }
            isRefreshingEditors = true
            defer { isRefreshingEditors = false }

            let config = SharedConfig.shared
            let custom = config.customEditors
            let existingIcons = editorSnapshot().icons
            let fresh = EditorCatalog.installed(custom: custom, preferred: config.preferredEditor)
            var freshIcons: [String: NSImage] = [:]

            for editor in fresh {
                let id = editor.id
                if let existing = existingIcons[id] {
                    freshIcons[id] = existing
                } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                    icon.size = NSSize(width: 16, height: 16)
                    freshIcons[id] = icon
                }
            }

            editorCacheLock.lock()
            editorCache.editors = fresh
            editorCache.checkedCustomIds = Set(custom.map(\.id))
            editorCache.icons = freshIcons
            editorCache.lastCheckTime = ProcessInfo.processInfo.systemUptime
            editorCache.hasChecked = true
            editorCacheLock.unlock()
        }
    }

    /// 右键子菜单要展示的编辑器：主线程只读内存快照，0ms 立即返回。
    /// 超过 5 分钟未检查、或设置里新增了手动项时派发后台异步刷新，主线程绝不等待。
    /// 调用前 menu(for:) 已 reload 过 SharedConfig，手动添加项与隐藏项是最新的。
    private func installedEditors() -> [KnownEditor] {
        let config = SharedConfig.shared
        let custom = config.customEditors
        let hidden = config.hiddenEditors
        var snap = Self.editorSnapshot()
        let now = ProcessInfo.processInfo.systemUptime
        if !snap.hasChecked {
            // 预热未完成时只校验默认项和手动项，不在右键线程枚举应用。
            let ids = Set(custom.map(\.id)).union([EditorCatalog.defaultEditorBundleIdentifier()] + [config.preferredEditor].compactMap { $0 })
            let fallback = ids.sorted().compactMap { EditorCatalog.editor(bundleIdentifier: $0) }
            Self.editorCacheLock.lock()
            if !Self.editorCache.hasChecked {
                Self.editorCache.editors = fallback
                Self.editorCache.checkedCustomIds = Set(custom.map(\.id))
                Self.editorCache.lastCheckTime = now
                Self.editorCache.hasChecked = true
            }
            snap = Self.editorCache
            Self.editorCacheLock.unlock()
            Self.refreshInstalledEditorsAsync()
        } else {
            // 手动项也先校验能力；旧配置中混入的普通应用不能绕过筛选。
            let unchecked = Set(custom.map(\.id)).subtracting(snap.checkedCustomIds)
            let existing = Set(snap.editors.map(\.id))
            snap.editors += unchecked.subtracting(existing).sorted().compactMap { EditorCatalog.editor(bundleIdentifier: $0) }
            if !unchecked.isEmpty || now - snap.lastCheckTime > 300.0 {
                Self.refreshInstalledEditorsAsync()
            }
        }
        return EditorCatalog.menuEditors(available: snap.editors, hidden: hidden, order: config.editorOrder)
    }

    /// 构建「打开编辑器」子菜单。
    ///
    /// 注意：FIFinderSync 的菜单会跨进程传给 Finder 渲染，NSMenuItem 的
    /// `representedObject`（Any）在跨进程序列化时会丢失，因此必须用 `tag`（Int）
    /// 携带数据 —— 这里 tag = 编辑器在本次 editorMenuIds 快照中的下标。
    private func buildEditorMenu(_ editors: [KnownEditor], style: MenuIconStyle) -> NSMenu {
        let m = NSMenu(title: L("打开编辑器"))
        let icons = style != .none ? Self.editorSnapshot().icons : [:]
        Self.editorCacheLock.lock()
        Self.editorMenuIds = editors.map(\.id)
        Self.editorCacheLock.unlock()
        for (idx, ed) in editors.enumerated() {
            let item = NSMenuItem(title: ed.name, action: #selector(openEditorWith(_:)), keyEquivalent: "")
            item.target = self
            item.tag = idx
            if style != .none {
                item.image = icons[ed.id]
            }
            m.addItem(item)
        }
        return m
    }

    @objc func openEditorWith(_ sender: NSMenuItem) {
        let idx = sender.tag
        Self.editorCacheLock.lock()
        let menuIds = Self.editorMenuIds
        Self.editorCacheLock.unlock()
        guard idx >= 0, idx < menuIds.count else {
            logToFile("openEditorWith: bad tag \(idx)"); return
        }
        let bundleId = menuIds[idx]
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("openEditorWith: no items"); return }
        let paths = urls.map(\.path)
        logToFile("openEditorWith ipc (async) → bundle=\(bundleId) count=\(paths.count)")
        IPCClient.shared.callAsync(action: "openWithApp", payload: [
            "paths": .stringArray(paths),
            "bundleId": .string(bundleId)
        ]) { r in
            logToFile("openEditorWith ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func cutFiles(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("cutFiles: no items"); return }
        let paths = urls.map { $0.path }
        logToFile("cutFiles ipc (async) → count=\(paths.count)")

        // 1. 同步更新扩展内部内存集合，彻底消除异步 IPC 写磁盘与 Finder 刷新回调的时序竞争
        cutBadgeLock.lock()
        for p in paths {
            inMemoryCutPaths.insert(normalizePath(p))
        }
        cutBadgeLock.unlock()

        // 2. 立即给选中的文件打上剪切角标，提供即时视觉反馈
        for url in urls {
            logToFile("cutFiles setBadgeIdentifier for: \(url.path)")
            setCutBadge(for: url)
            setCutBadge(for: url.standardizedFileURL)
        }

        // 3. 剪切时兜底：所在目录尚未确认角标归属（探测没结论或主 App 当时未运行）时立即申请抢回。
        //    抢回成功后 Finder 会重新请求可见项角标，requestBadgeIdentifier 据内存队列给出剪切角标。
        if let parent = urls.first?.deletingLastPathComponent().path {
            requestBadgeReclaimIfNeeded(directory: parent, reason: "cut")
        }

        IPCClient.shared.callAsync(action: "cutFiles", payload: [
            "paths": .stringArray(paths)
        ]) { r in
            logToFile("cutFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
            guard r.success else {
                let persisted = persistedCutQueuePaths()
                let staleURLs = urls.filter { !persisted.contains(normalizePath($0.path)) }
                cutBadgeLock.lock()
                for url in staleURLs { inMemoryCutPaths.remove(normalizePath(url.path)) }
                cutBadgeLock.unlock()
                DispatchQueue.main.async {
                    for url in staleURLs {
                        FIFinderSyncController.default().setBadgeIdentifier("", for: url)
                        FIFinderSyncController.default().setBadgeIdentifier("", for: url.standardizedFileURL)
                    }
                }
                return
            }

            // 主 App 已落盘：延迟再推一次角标，覆盖「菜单刚关闭、Finder 还没重绘」的时序。
            // 同样只在持有角标归属时有效（见 requestBadgeIdentifier 处的说明）。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let stillCut = currentCutQueuePaths()
                var pushed = 0
                for url in urls where stillCut.contains(normalizePath(url.path)) {
                    setCutBadge(for: url)
                    pushed += 1
                }
                logToFile("cutFiles badge re-push: \(pushed)/\(urls.count) item(s) still cut")
            }
        }
    }

    @objc func cancelCut(_ sender: NSMenuItem) {
        let cutPaths = currentCutQueuePaths()
        logToFile("cancelCut ipc (async) → clearing \(cutPaths.count) badges")

        // 立即清除内存队列中的待剪切路径
        cutBadgeLock.lock()
        inMemoryCutPaths.removeAll()
        cutBadgeLock.unlock()

        for path in cutPaths {
            let u = URL(fileURLWithPath: path)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u.standardizedFileURL)
        }
        IPCClient.shared.callAsync(action: "cancelCut", payload: [:]) { r in
            logToFile("cancelCut ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    /// 撤销 FinderRight 的上一次操作。结果提示由主 App 弹出，扩展只记日志
    @objc func undoLast(_ sender: NSMenuItem) {
        IPCClient.shared.callAsync(action: "undoLast", payload: [:]) { r in
            logToFile("undoLast ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func pasteFiles(_ sender: NSMenuItem) {
        // 粘贴目标始终是 Finder 当前正在浏览的目录（targetedURL），
        // 而不是选中的项——否则当用户选中一个子文件夹时会错误地粘贴进去。
        guard let destDir = FIFinderSyncController.default().targetedURL() else {
            logToFile("pasteFiles: no destination directory"); return
        }
        let cutPaths = currentCutQueuePaths()
        logToFile("pasteFiles ipc (async) → destDir=\(destDir.lastPathComponent) pendingCutCount=\(cutPaths.count)")

        // 立即清除待粘贴源文件的剪切角标并清空内存队列
        cutBadgeLock.lock()
        inMemoryCutPaths.removeAll()
        cutBadgeLock.unlock()

        for path in cutPaths {
            let u = URL(fileURLWithPath: path)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u)
            FIFinderSyncController.default().setBadgeIdentifier("", for: u.standardizedFileURL)
        }

        IPCClient.shared.callAsync(action: "pasteFiles", payload: [
            "destination": .string(destDir.path)
        ]) { r in
            logToFile("pasteFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    // MARK: - 移动到 / 复制到常用目录

    /// 「移动到 / 复制到」子菜单：每个常用目录一项（tag 为其在列表中的下标），末尾是「管理常用目录…」
    private func buildFavoritesMenu(mode: FileTransferCheck.Mode, selected: [URL], style: MenuIconStyle) -> NSMenu {
        let m = NSMenu(title: L(mode == .move ? "移动到" : "复制到"))
        let favorites = SharedConfig.shared.favoriteDirectories
        let names = FavoriteDirectories.displayNames(for: favorites, home: IPCBridge.realUserHomeDirectory.path)
        let action = mode == .move ? #selector(moveToFavorite(_:)) : #selector(copyToFavorite(_:))

        if favorites.isEmpty {
            let empty = makeItem(titleKey: "尚未添加常用目录", tint: .gray, systemImage: nil, style: .none)
            empty.isEnabled = false
            m.addItem(empty)
        }
        for (index, (path, name)) in zip(favorites, names).enumerated() {
            let item = makeItem(titleKey: name, tint: .cyan, systemImage: "folder", action: action, tag: index, style: style)
            // 没有任何一项能放过去时置灰：移动时全部已在该目录，或目标位于选中的文件夹内部
            item.isEnabled = selected.contains {
                FileTransferCheck.check(source: normalizePath($0.path), destinationDirectory: path, mode: mode) == .ok
            }
            m.addItem(item)
        }

        m.addItem(.separator())
        m.addItem(makeItem(titleKey: "管理常用目录…", tint: .gray, systemImage: "gearshape", action: #selector(manageFavorites(_:)), style: style))
        return m
    }

    @objc func moveToFavorite(_ sender: NSMenuItem) {
        transferToFavorite(sender, mode: .move)
    }

    @objc func copyToFavorite(_ sender: NSMenuItem) {
        transferToFavorite(sender, mode: .copy)
    }

    private func transferToFavorite(_ sender: NSMenuItem, mode: FileTransferCheck.Mode) {
        let urls = currentContext().selectedItems
        let favorites = SharedConfig.shared.favoriteDirectories
        guard !urls.isEmpty, favorites.indices.contains(sender.tag) else {
            logToFile("transferItems: no items or favorite index out of range (\(sender.tag))"); return
        }
        let destination = favorites[sender.tag]
        logToFile("transferItems ipc (async) → mode=\(mode.rawValue) count=\(urls.count) dest=\((destination as NSString).lastPathComponent)")
        IPCClient.shared.callAsync(action: "transferItems", payload: [
            "items": .stringArray(urls.map(\.path)),
            "destination": .string(destination),
            "mode": .string(mode.rawValue)
        ]) { r in
            logToFile("transferItems ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    @objc func goToDirectory(_ sender: NSMenuItem) {
        guard let url = URL(string: "\(IPCBridge.urlScheme)://go-to-directory") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let appURL = IPCBridge.containingAppURL(forExtensionAt: Bundle.main.bundleURL) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg) { _, error in
                if let error { logToFile("goToDirectory: \(error.localizedDescription)") }
            }
        } else if !NSWorkspace.shared.open(url) {
            logToFile("goToDirectory: failed to open main app")
        }
    }

    /// 打开主 App 设置的「常用目录」页。与 IPC 唤醒一样定向投递给内嵌本扩展的主 App
    @objc func manageFavorites(_ sender: NSMenuItem) {
        guard let url = URL(string: "\(IPCBridge.urlScheme)://settings/favorites") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        if let appURL = IPCBridge.containingAppURL(forExtensionAt: Bundle.main.bundleURL) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: cfg, completionHandler: nil)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func archiveOperation(_ sender: NSMenuItem) {
        let urls = currentContext().selectedItems
        guard !urls.isEmpty else { logToFile("archiveOperation: no items"); return }
        let paths = urls.map(\.path)
        logToFile("archiveOperation ipc (async) → tag=\(sender.tag) count=\(paths.count)")

        switch sender.tag {
        case 0:
            IPCClient.shared.callAsync(action: "compressZip", payload: ["items": .stringArray(paths)], timeout: 30) { r in
                logToFile("compressZip ipc result: success=\(r.success) msg=\(r.message ?? "")")
            }
        case 2:
            DispatchQueue.global(qos: .userInitiated).async {
                var firstErr: String?
                for p in paths {
                    let one = IPCClient.shared.call(action: "decompress",
                                                    payload: ["archive": .string(p)],
                                                    timeout: 30)
                    if !one.success, firstErr == nil { firstErr = one.message }
                }
                logToFile("decompress ipc result: success=\(firstErr == nil) msg=\(firstErr ?? "")")
            }
        default:
            return
        }
    }

    @objc func toggleHiddenFiles(_ sender: NSMenuItem) {
        logToFile("toggleHiddenFiles clicked (async)")
        IPCClient.shared.callAsync(action: "toggleHiddenFiles", payload: [:]) { r in
            logToFile("toggleHiddenFiles ipc result: success=\(r.success) msg=\(r.message ?? "")")
        }
    }

    // MARK: - Utility

    private func newFileTypeInfo(for tag: Int) -> (ext: String, content: String) {
        let templates = BuiltInFileTemplates.text
        let template = templates.indices.contains(tag) ? templates[tag] : templates[0]
        return (template.fileExtension, template.content)
    }
}
