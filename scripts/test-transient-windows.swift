import AppKit

@main
struct TransientWindowChecks {
    static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            preconditionFailure("找不到访达进程")
        }
        let current = NSRunningApplication.current
        precondition(finder.processIdentifier != current.processIdentifier)

        var frontmost: NSRunningApplication? = finder
        var applicationIsActive = true
        var previousApplicationIsRunning = true
        var alwaysShowDockIcon = true
        var visibleStandardWindows: Set<ObjectIdentifier> = []
        var scheduled: [() -> Void] = []
        var activations: [pid_t] = []
        var accessoryReturns = 0

        var environment = TransientWindowManager.Environment()
        environment.frontmostApplication = { frontmost }
        environment.applicationIsActive = { applicationIsActive }
        environment.show = { _ in }
        environment.isWindowVisible = { visibleStandardWindows.contains(ObjectIdentifier($0)) }
        environment.hasVisibleStandardWindow = { closing in
            !visibleStandardWindows.subtracting(closing).isEmpty
        }
        environment.alwaysShowDockIcon = { alwaysShowDockIcon }
        environment.previousApplicationIsRunning = { _ in previousApplicationIsRunning }
        environment.activate = { activations.append($0.processIdentifier) }
        environment.returnToAccessory = { accessoryReturns += 1 }
        // 测试不进入真实 RunLoop，也不显示窗口，只在模拟 AppKit 完成关闭后执行回调。
        environment.schedule = { scheduled.append($0) }
        let manager = TransientWindowManager(environment: environment)

        func makeWindow() -> NSWindow {
            NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                     styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        }
        func present(
            _ window: NSWindow,
            transient: Bool = true,
            openedFromExternalApplication: Bool = true
        ) {
            if transient {
                manager.present(window, openedFromExternalApplication: openedFromExternalApplication)
            } else {
                manager.recordPresentation(
                    of: window, openedFromExternalApplication: openedFromExternalApplication)
            }
            visibleStandardWindows.insert(ObjectIdentifier(window))
            frontmost = current // 模拟产品的 NSApp.activate，测试本身不激活任何应用
            applicationIsActive = true
        }
        func close(_ window: NSWindow) {
            manager.windowWillClose(window)
            visibleStandardWindows.remove(ObjectIdentifier(window))
        }
        func drain() {
            while !scheduled.isEmpty { scheduled.removeFirst()() }
        }
        func reset() {
            activations.removeAll()
            accessoryReturns = 0
            frontmost = current
            applicationIsActive = true
            previousApplicationIsRunning = true
            alwaysShowDockIcon = true
        }

        let queue = makeWindow()
        frontmost = finder
        present(queue)
        // 再次显示同一个窗口不能丢失最初的前台来源。
        manager.recordPresentation(of: queue)
        close(queue)
        drain()
        precondition(activations == [finder.processIdentifier], "常驻 Dock 时也应把焦点交还访达")
        precondition(accessoryReturns == 0, "用户要求常驻 Dock 时不能切回 accessory")
        print("✓ 剪切队列类窗口关闭后交还焦点，常驻 Dock 保持不变")

        reset()
        let backgroundSettings = makeWindow()
        frontmost = finder
        present(backgroundSettings, transient: false)
        // 设置窗口保持打开，但用户已经切回访达，再从访达打开剪切队列。
        frontmost = finder
        present(queue)
        close(queue)
        drain()
        precondition(activations == [finder.processIdentifier],
                     "后台仍有设置窗口时，外部唤起的剪切队列关闭后也应交还焦点")
        precondition(accessoryReturns == 0, "设置窗口仍可见时不能切回 accessory")
        close(backgroundSettings)
        drain()
        print("✓ 后台其他窗口不妨碍外部唤起窗口交还焦点")

        reset()
        frontmost = finder
        present(backgroundSettings, transient: false)
        // 外部 URL/IPC 先把 App 激活，present 看到的已经是 FinderRight。
        frontmost = current
        present(queue)
        close(queue)
        drain()
        precondition(activations == [finder.processIdentifier],
                     "提前激活且后台仍有设置窗口时，外部窗口关闭后也应交还焦点")
        close(backgroundSettings)
        drain()
        print("✓ 提前激活不会把外部窗口误记为内部打开")

        reset()
        frontmost = finder
        present(queue)
        alwaysShowDockIcon = false
        close(queue)
        drain()
        precondition(activations == [finder.processIdentifier] && accessoryReturns == 1,
                     "最后一个窗口关闭后应恢复来源应用和 accessory")
        print("✓ 最后一个临时窗口关闭后恢复后台")

        reset()
        let settings = makeWindow()
        frontmost = finder
        present(settings, transient: false)
        present(queue, openedFromExternalApplication: false) // 从已在前台的设置页内部打开
        alwaysShowDockIcon = false
        close(queue)
        drain()
        precondition(activations.isEmpty && accessoryReturns == 0,
                     "设置仍可见时不能交还焦点或隐藏窗口")
        close(settings)
        drain()
        precondition(activations == [finder.processIdentifier] && accessoryReturns == 1,
                     "关闭最后的设置窗口应使用它自己的来源记录")
        print("✓ 设置窗口保持打开时不受临时窗口关闭影响")

        reset()
        frontmost = finder
        present(queue)
        let otherApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        frontmost = otherApp // 用户已将前台切换到其他无关应用
        alwaysShowDockIcon = false
        close(queue)
        drain()
        precondition(activations.isEmpty, "用户已切换应用时不能抢回焦点")
        precondition(accessoryReturns == 1, "不抢焦点也应恢复后台 Dock 策略")
        print("✓ 用户已切换前台应用时不抢焦点")

        reset()
        frontmost = finder
        present(queue)
        // 模拟 FRTransientPanel：系统前台应用依然是访达，但 App 处于活跃交互状态
        frontmost = finder
        applicationIsActive = true
        close(queue)
        drain()
        precondition(activations == [finder.processIdentifier], "FRTransientPanel 关闭后必须显式激活访达以恢复窗口焦点")
        print("✓ FRTransientPanel 关闭后重新激活来源应用")

        reset()
        frontmost = finder
        present(queue)
        previousApplicationIsRunning = false
        close(queue)
        drain()
        precondition(activations.isEmpty && accessoryReturns == 0,
                     "来源应用已退出时不能激活失效目标")
        print("✓ 来源应用已退出时安全跳过")

        reset()
        let second = makeWindow()
        frontmost = finder
        present(queue)
        present(second)
        close(queue)
        drain()
        precondition(activations.isEmpty && accessoryReturns == 0,
                     "关闭一个临时窗口不能影响另一个可见窗口")
        alwaysShowDockIcon = false
        close(second)
        drain()
        precondition(activations == [finder.processIdentifier] && accessoryReturns == 1,
                     "最后一个临时窗口应使用同一会话的来源")
        print("✓ 多个临时窗口按最后一个关闭窗口统一结算")

        reset()
        frontmost = finder
        present(queue)
        present(second)
        close(queue)
        close(second)
        drain()
        precondition(activations == [finder.processIdentifier], "连续关闭不能把焦点恢复两次")
        print("✓ 同一批窗口关闭只恢复一次前台来源")

        reset()
        frontmost = finder
        present(queue)
        close(queue)
        present(queue) // 旧关闭回调执行前已重新打开
        drain()
        precondition(activations.isEmpty && accessoryReturns == 0,
                     "关闭后马上重开的窗口不能被旧回调隐藏或切走焦点")
        close(queue)
        drain()
        precondition(activations == [finder.processIdentifier],
                     "重新打开后的关闭仍应恢复正确来源")
        print("✓ 旧关闭回调不影响重新打开的窗口")

        reset()
        frontmost = finder
        present(settings, transient: false)
        close(settings)
        drain()
        activations.removeAll()
        // IPC 或系统可能先把 FinderRight 激活，显示窗口时 frontmost 已经是自己。
        frontmost = current
        present(queue)
        close(queue)
        drain()
        precondition(activations == [finder.processIdentifier],
                     "显示前已被激活时，也应恢复最近一次外部前台应用")
        print("✓ 提前激活不会丢失外部前台来源")

        reset()
        let unmanagedMenuWindow = makeWindow()
        alwaysShowDockIcon = false
        // 未受管窗口（如状态栏菜单 NSPopupMenuWindow）从未调用过 present 或 recordPresentation
        manager.windowWillClose(unmanagedMenuWindow)
        precondition(scheduled.isEmpty, "未受管窗口关闭时不应调度 processClosedWindows")
        drain()
        precondition(accessoryReturns == 0 && activations.isEmpty,
                     "未受管窗口（如状态栏菜单）关闭时不能误切回 accessory 或抢交焦点")
        print("✓ 未受管系统内部窗口（如菜单弹窗）关闭被安全忽略")

        // 纯决策兜底：没有可靠的前台应用信息时，即便 App 自报 active 也不能随便激活来源。
        let decision = WindowActivationPolicy.decision(
            currentApplicationPID: current.processIdentifier,
            previousApplicationPID: finder.processIdentifier,
            frontmostApplicationPID: nil,
            isApplicationActive: true,
            hasVisibleStandardWindow: false,
            openedFromExternalApplication: false,
            previousApplicationIsRunning: true,
            alwaysShowDockIcon: false)
        precondition(decision.restoreApplicationPID == nil && decision.shouldReturnToAccessory)
        print("✓ 前台状态不明时不恢复错误应用")

        // 验证 FRTransientPanel 属性：带 nonactivatingPanel、hidesOnDeactivate 为 false、isFloatingPanel 为 false
        let panel = FRTransientPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            minSize: CGSize(width: 300, height: 200))
        precondition(panel.styleMask.contains(.nonactivatingPanel), "临时面板必须包含 nonactivatingPanel 样式以防激活整个应用")
        precondition(!panel.hidesOnDeactivate, "切换前台应用时临时面板不应自动隐藏")
        precondition(!panel.isFloatingPanel, "临时面板不应死死置顶所有应用")
        precondition(panel.minSize.width >= 300 && panel.minSize.height >= 200, "最小尺寸计算必须正确")
        print("✓ FRTransientPanel 样式与生命周期配置检查通过")

        precondition(visibleStandardWindows.isEmpty && scheduled.isEmpty)
        print("PASS: 临时窗口激活与关闭时序检查通过")
    }
}
