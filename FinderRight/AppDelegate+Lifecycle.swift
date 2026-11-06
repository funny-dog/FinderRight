import SwiftUI
import FinderRightKit

extension AppDelegate {
    
    /// 在 willFinishLaunching 注册全局快捷键
    func registerGlobalHotkeys() {
        // 注册 Ctrl+Space 触发快速搜索（与其他应用不冲突的常用组合）
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.control),
                  (event.charactersIgnoringModifiers?.lowercased()) == " " else { return }
            
            DispatchQueue.main.async {
                // TODO: 快速搜索功能待实现
                // self?.showFastSearch()
            }
            
            // 阻止冒泡到其他应用
        }
    }
    
    // private func showFastSearch() {
    //     FastSearchController.shared.show()
    // }
    
    /// 检查旧版 staging/ 目录是否存在遗留文件，仅记录日志，不自动移动或删除
    func checkLegacyStagingDirectory() {
        // 一次性提醒：发送成功后才置位，避免每次冷启动重复弹同一条通知
        let sentKey = "stagingLegacyWarningSent"
        guard !UserDefaults.standard.bool(forKey: sentKey) else { return }

        let stagingDir = IPCBridge.rootDirectory.appendingPathComponent("staging", isDirectory: true)
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: stagingDir.path), !items.isEmpty {
            NSLog("[AppDelegate] 发现暂存区遗留文件: \(items.count) 个，位于 \(stagingDir.path)")
            UserDefaults.standard.set(true, forKey: sentKey)
        }
    }

    /// 检查上次更新是否有失败日志并弹窗提醒。
    ///
    /// 失败文案由替换脚本写好后原样展示：可能是「已回滚旧版本」，也可能是「回滚也失败、备份留在哪」，
    /// 不能一律说成自动更新失败或已回滚。
    func checkLastUpdateError() {
        let errorFileURL = IPCBridge.rootDirectory.appendingPathComponent("last-update-error.txt")
        let fm = FileManager.default
        if fm.fileExists(atPath: errorFileURL.path),
           let content = try? String(contentsOf: errorFileURL, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? fm.removeItem(at: errorFileURL)
            DispatchQueue.main.async { [weak self] in
                self?.showUpdateFailure(title: NSLocalizedString("更新未能完成", comment: "alert"),
                                        message: content.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    /// 新版完成基本初始化后回执，替换脚本只在这之后清理旧版备份。
    ///
    /// 任何启动方式（含自动更新重启的后台启动）走到这里都说明初始化已完成；
    /// 版本不低于待确认版本即确认，并核对运行实例后才清理，清理失败时保留回执下次重试。
    func confirmInstalledVersion() {
        guard UpdateInstallReceipt.decide(receipt: UpdateInstallReceipt.load(),
                                          currentVersion: UpdateChecker.shared.currentAppVersion)
        else { return }
        UpdateInstallReceipt.complete()
        FinderRestarter.restartFinderIfUpdated()
    }

    /// 自动检查并向系统注册自身的 FinderSync 扩展
    func registerFinderSyncPlugin() {
        guard let pluginsURL = Bundle.main.builtInPlugInsURL else { return }
        let appexURL = pluginsURL.appendingPathComponent("FinderRightSync.appex")
        guard FileManager.default.fileExists(atPath: appexURL.path) else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            /// 查询插件注册与选举状态。必须带 `-v`：输出形如
            /// `+    com.finderright.app.sync(1.1.10)<Tab><uuid><Tab><日期><Tab><路径>`；
            /// 不带 -v 时没有路径字段，路径比对永远失败（曾导致每次启动都重复 pluginkit -a）。
            func queryPluginState() -> (status: Int32, output: String) {
                let proc = Process()
                let pipe = Pipe()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                proc.arguments = ["-m", "-v", "-i", "com.finderright.app.sync"]
                proc.standardOutput = pipe
                // 启动失败时管道写端仍在本进程手里，直接读会永远等不到 EOF
                guard (try? proc.run()) != nil else { return (-1, "") }
                // 先读到 EOF 再等待退出，避免输出超过管道缓冲时互相等待（同 ProcessRunner）
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                let text = (String(data: data, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (proc.terminationStatus, text)
            }

            // 1. 仅在「未注册」「注册路径变化」或「注册版本与当前 bundle 不一致（刚升级）」时才注册。
            //
            // ⚠️ 不要改回每次启动都无条件 `pluginkit -a`：重复注册会让插件 UUID 变新并重启扩展进程，
            // 重启后的扩展成为与其他 Finder Sync 扩展（如 Keka）重叠目录的**最后注册者**，
            // 从而失去这些目录的角标归属（Finder 只把 requestBadgeIdentifier 交给最先注册者，
            // 见 FinderSync.requestBadgeIdentifier 处的说明），表现为重启 App 后剪切角标整体失效。
            // 版本号一致即同一份插件，重复注册有害无益；只有版本变化才需要让 PluginKit 更新。
            let appexVersion = (NSDictionary(contentsOf: appexURL.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? ""
            var (status, output) = queryPluginState()
            let isCurrent = FinderSyncElection.isRegistrationCurrent(
                verboseOutput: output, appexPath: appexURL.path, version: appexVersion)
            if status != 0 || !isCurrent {
                let regProc = Process()
                regProc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
                regProc.arguments = ["-a", appexURL.path]
                try? regProc.run()
                regProc.waitUntilExit()
                NSLog("[AppDelegate] 重新注册 FinderSync appex（未注册/路径或版本变化，当前 \(appexVersion)）: \(appexURL.path)")
                (status, output) = queryPluginState()
            } else {
                NSLog("[AppDelegate] FinderSync appex 已注册且版本一致 (\(appexVersion))，跳过 pluginkit -a（避免扰动角标回调）")
            }

            // 检查应用是否刚刚更新，若更新则重启一次 Finder 确保新扩展立刻被 Finder 挂载
            FinderRestarter.restartFinderIfUpdated()

            // 2. 读取插件当前选举状态（避免覆盖用户在系统设置里的显式禁用）
            let trimmed = output
            guard status == 0 else {
                NSLog("[AppDelegate] PlugInKit 查询失败 (exit=\(status))，跳过修改扩展启用状态")
                return
            }

            // 已启用时不反复注销/注册扩展，避免扰动 Finder 的回调路由。
            if trimmed.hasPrefix("+") {
                NSLog("[AppDelegate] FinderRightSync appex 已经处于启用状态 (+)，无需重复注册")
                return
            }

            // "-" 表示用户在系统设置里显式禁用了扩展（elected to ignore），必须尊重用户意图，禁止强制覆盖
            if trimmed.hasPrefix("-") {
                NSLog("[AppDelegate] FinderRightSync appex 已被用户手动关闭 (-)，尊重用户设置，跳过 pluginkit -e use")
                return
            }

            // 既非 "+" 也非 "-"（未选举的默认初始状态），进行首次自动开启
            let enableProc = Process()
            enableProc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            enableProc.arguments = ["-e", "use", "-i", "com.finderright.app.sync"]
            try? enableProc.run()
            enableProc.waitUntilExit()

            NSLog("[AppDelegate] FinderRightSync appex 首次注册并自动启用成功")
        }
    }

}
