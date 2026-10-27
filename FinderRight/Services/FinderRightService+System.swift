import Foundation
import AppKit
import CoreGraphics
import FinderRightKit

private func L(_ key: String) -> String { NSLocalizedString(key, comment: "notification") }

// MARK: - 终端、编辑器与隐藏文件

extension FinderRightService {

    func openTerminal(_ req: IPCRequest) -> IPCResponse {
        guard let directory = req.payload["directory"]?.stringValue,
              let bundleId = req.payload["bundleId"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "openTerminal 参数缺失")
        }
        guard TerminalCatalog.terminal(bundleIdentifier: bundleId) != nil else {
            return IPCResponse(id: req.id, success: false,
                               message: NSLocalizedString("所选应用未声明终端功能，无法打开。", comment: ""))
        }

        // 只能用命令行参数指定工作目录的终端（Ghostty / Alacritty / Kitty）。
        //
        // 关键限制：`open --args` 的参数只在**应用冷启动**时进入 main() 的 argv（见 man open）。
        // 应用已在运行时，open 只发 reopen 事件、参数被直接丢弃 —— 实测（自建 .app 图标包，
        // 记录 argv 后长驻）：首次 --args ALPHA 生效；进程存活期间 --args BETA/GAMMA 既不产生
        // 新进程、argv 也不更新。因此这里先判断终端是否在运行，未运行才走 --args 冷启动；
        // 已在运行则落到下面的通用目录 URL 路径（至少不会用一个必然被忽略的参数假装成功）。
        if let args = Self.workingDirectoryArguments(for: bundleId, directory: directory),
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-b", bundleId, "--args"] + args
            do {
                try proc.run()
                // 不在这里 waitUntilExit：open 要等应用启动完成才返回（重终端可能上百毫秒），
                // 而本方法跑在 IPC 串行队列上。退出码只在后台记录。
                DispatchQueue.global(qos: .utility).async {
                    proc.waitUntilExit()
                    if proc.terminationStatus != 0 {
                        NSLog("[FinderRightService] openTerminal: \(bundleId) --args 退出码 \(proc.terminationStatus)")
                    } else {
                        NSLog("[FinderRightService] openTerminal: \(bundleId) 冷启动并携带工作目录参数")
                    }
                }
                return IPCResponse(id: req.id, success: true, message: nil)
            } catch {
                NSLog("[FinderRightService] openTerminal: \(bundleId) --args 启动失败: \(error)，退回目录 URL 路径")
            }
        }

        // 通用方式：NSWorkspace.open 传递目录 URL（Terminal / iTerm2 / Warp 原生支持；
        // Ghostty / Kitty 已在运行时也走这里，由各自对「打开文件夹」的处理决定是否换目录）
        let url = URL(fileURLWithPath: directory)
        let success = NSWorkspace.shared.open(
            [url],
            withAppBundleIdentifier: bundleId,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifiers: nil
        )
        return IPCResponse(id: req.id, success: success,
                           message: success ? nil : "NSWorkspace.open 返回 false")
    }

    /// 终端冷启动时用来指定工作目录的命令行参数；不需要的终端返回 nil（走通用目录 URL 路径）。
    /// 参数以数组形式直接交给 `/usr/bin/open`，不经 shell，含空格/中文的路径安全。
    private static func workingDirectoryArguments(for bundleId: String, directory: String) -> [String]? {
        switch bundleId {
        case "com.mitchellh.ghostty":
            return ["--working-directory=\(directory)"]
        case "org.alacritty":
            return ["--working-directory", directory]
        case "net.kovidgoyal.kitty":
            return ["--directory", directory]
        default:
            return nil
        }
    }

    func openWithApp(_ req: IPCRequest) -> IPCResponse {
        guard let paths = req.payload["paths"]?.stringArrayValue,
              let bundleId = req.payload["bundleId"]?.stringValue else {
            return IPCResponse(id: req.id, success: false, message: "openWithApp 参数缺失")
        }
        guard EditorCatalog.editor(bundleIdentifier: bundleId) != nil else {
            return IPCResponse(id: req.id, success: false,
                               message: NSLocalizedString("所选应用未声明文本编辑功能，无法打开。", comment: ""))
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let ok = NSWorkspace.shared.open(
            urls,
            withAppBundleIdentifier: bundleId,
            options: [],
            additionalEventParamDescriptor: nil,
            launchIdentifiers: nil
        )
        // 注：不接收 IPC 传入的可执行路径回退（历史 cliFallbackPaths 已移除）——
        // 该参数从未被扩展使用，且可被执行任意二进制的伪造请求利用。
        return IPCResponse(id: req.id, success: ok,
                           message: ok ? nil : "无法通过 \(bundleId) 打开")
    }

    func toggleHiddenFiles(_ req: IPCRequest) -> IPCResponse {
        serviceLog("toggleHiddenFiles requested")

        // 优先通过辅助功能权限模拟 Cmd+Shift+. 快捷键，实现 Finder 窗口不重启、不闪烁即时切换
        let checkOpts = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        if AXIsProcessTrustedWithOptions(checkOpts),
           let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let pid = finder.processIdentifier
            // 不 activate Finder：postToPid 直达进程事件队列，activate 会抢焦点导致菜单栏跳变卡顿

            // fire-and-forget：不再跟踪/回写任何状态（菜单文案已改无状态，见 FinderSync）。
            let src = CGEventSource(stateID: .hidSystemState)
            // kVK_ANSI_Period = 0x2F (47)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x2F, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 0x2F, keyDown: false)
            down?.flags = [.maskCommand, .maskShift]
            up?.flags   = [.maskCommand, .maskShift]
            down?.postToPid(pid)
            up?.postToPid(pid)

            serviceLog("sent Cmd+Shift+. to Finder pid=\(pid)")
            return IPCResponse(id: req.id, success: true, message: "toggled via CGEvent pid=\(pid)")
        }

        // 未授权辅助功能：降级方案要 killall Finder，会关闭所有访达窗口、可能中断正在进行的拷贝 / 移动，
        // 不能静默执行。先立即应答扩展（避免它等满 IPC 超时），再到主线程让用户明确选择。
        DispatchQueue.main.async { [weak self] in
            self?.confirmHiddenFilesFallback(req)
        }
        return IPCResponse(id: req.id, success: true, message: "no accessibility, awaiting user confirmation")
    }

    /// 只在主线程访问：防止确认框未关闭时重复右键触发，叠出多层模态框
    private static var isConfirmingHiddenFilesFallback = false

    /// 未授权辅助功能时的三选一：重启访达并切换 / 去授权 / 取消
    private func confirmHiddenFilesFallback(_ req: IPCRequest) {
        guard !Self.isConfirmingHiddenFilesFallback else { return }
        Self.isConfirmingHiddenFilesFallback = true
        defer { Self.isConfirmingHiddenFilesFallback = false }

        let dialog = FRDialog(
            title: L("切换隐藏文件需要重启访达"),
            message: L("FinderRight 尚未获得「辅助功能」权限，只能通过重启访达来切换。重启会关闭所有访达窗口，并可能中断正在进行的拷贝或移动。"),
            symbol: "exclamationmark.triangle", tone: .warning,
            buttons: [L("重启访达并切换"), L("授权辅助功能…"), L("取消")])

        switch dialog.runModal() {
        case 0:
            // defaults 读写与 killall 都会同步等待子进程，放到后台，不阻塞主线程
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let resp = self.toggleHiddenFilesViaDefaults(req, newValue: "toggle")
                self.serviceLog("toggleHiddenFiles 用户确认重启访达: \(resp.message ?? "")")
            }
        case 1:
            // 系统授权弹窗会把 FinderRight 加进辅助功能列表，用户只需打开开关
            let promptOpts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(promptOpts)
        default:
            serviceLog("toggleHiddenFiles 用户取消（未授权辅助功能）")
        }
    }

    private func toggleHiddenFilesViaDefaults(_ req: IPCRequest, newValue: String) -> IPCResponse {
        // 用 defaults CLI 读当前值：子进程每次冷启动读盘，绕开本进程 cfprefsd 客户端缓存
        // （UserDefaults(suiteName:) 读其他 App 的域可能命中过期缓存，导致取反后写回同值、看似没切换）
        var currentBool = false
        let readProc = Process()
        let readOut = Pipe()
        readProc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        readProc.arguments = ["read", "com.apple.finder", "AppleShowAllFiles"]
        readProc.standardOutput = readOut
        readProc.standardError = FileHandle.nullDevice
        if (try? readProc.run()) != nil {
            let data = readOut.fileHandleForReading.readDataToEndOfFile()
            readProc.waitUntilExit()
            let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            currentBool = (s == "1" || s.lowercased() == "true" || s.lowercased() == "yes")
        }
        let nextVal = !currentBool ? "YES" : "NO"
        let writeProc = Process()
        writeProc.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        writeProc.arguments = ["write", "com.apple.finder", "AppleShowAllFiles", nextVal]
        try? writeProc.run()
        writeProc.waitUntilExit()

        do {
            let killProc = Process()
            killProc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            killProc.arguments = ["Finder"]
            try killProc.run()
            killProc.waitUntilExit()

            return IPCResponse(id: req.id, success: true, message: "set to \(nextVal), restarted Finder")
        } catch {
            return IPCResponse(id: req.id, success: false, message: error.localizedDescription)
        }
    }
}
