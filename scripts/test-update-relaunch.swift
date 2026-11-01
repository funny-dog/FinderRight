import Foundation
import AppKit
import FinderRightKit

// 替换脚本（UpdateChecker.relaunchScript）的临时目录验证：
// 只在临时目录里摆放假的 FinderRight.app，HOME 指向临时目录，open/killall/xattr/lsregister 换成记录器，
// 不会替换 /Applications/FinderRight.app、不终止真实应用、也不做真实系统注册。

enum FinderRightService {
    static let backgroundJobs = BackgroundJobs()
}

@main
struct UpdateRelaunchChecks {
    static var failures = 0

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        // 用环境变量而不是命令行参数：测速工具等外部条件不应影响入口判断
        if let raw = ProcessInfo.processInfo.environment["FR_RELAUNCH_CASE"], let value = Int(raw) {
            declareCases()
            runChild(index: value, cases: cases)
            return
        }
        declareCases()
        // 每个用例在子进程里跑：替换脚本要等的「旧进程」就是这个子进程，
        // 脚本跑完子进程即退出，和真实交接时旧版退出的时序一致。

        // 父进程逐个拉起子进程执行用例，每个用例的「旧进程」就是它自己
        for index in cases.indices {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            var environment = ProcessInfo.processInfo.environment
            environment["FR_RELAUNCH_CASE"] = String(index)
            environment.removeValue(forKey: "FR_FAKE_FAIL")
            environment.removeValue(forKey: "FR_FAKE_FAIL_ROLLBACK")
            environment.removeValue(forKey: "FR_FAKE_REMOVE_TARGET")
            child.environment = environment
            child.arguments = []
            do { try child.run() } catch { print("child run error: \(error)"); failures += 1; continue }
            child.waitUntilExit()
            if child.terminationStatus != 0 {
                failures += 1
                print("✗ \(cases[index].name)：子进程退出码 \(child.terminationStatus)")
            }
        }
        cleanRestoreCopies()

        if failures > 0 {
            print("更新替换脚本测试失败 \(failures) 项")
            exit(1)
        }
        print("✓ 替换脚本：成功、各步失败与回滚、版本不符、未确认备份停止安装、过期回执与目标恢复均符合预期")
    }

    /// 路径含空格、中文、引号、美元符号、反引号和 $() 时都必须按字面值处理。
    /// 子目录名用命令替换生成，保证与编译时留下的同名占位目录不会撞车
    static let trickyDirectoryName = "更新 目录 $(touch PWNED) `touch PWNED2` \"q\" 'q' $HOME "

    struct Layout {
        let oldVersion: String?
        let newVersion: String
        let expected: String
        var existingBackupVersion: String? = nil
        /// 预置一条备份已不存在的过期回执，验证脚本清掉它后照常安装
        var staleReceipt: Bool = false
        /// 自定义安装目录名，nil 则沿用 trickyDirectoryName
        var installDirectoryName: String? = nil
    }

    struct Actions {
        var failing: String? = nil
        var failRollback = false
        var removeTargetOnLaunchFailure = false
    }

    struct Environment {
        let home: URL
        let root: URL
        let target: URL
        let backup: URL
        let newApp: URL
        let baseDir: URL
        let receipt: URL
        let errorLog: URL
        let calls: [String]
        let error: String?
        let errorText: String

        func newVersion(at url: URL) -> String? {
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return dict["CFBundleShortVersionString"] as? String
        }
    }

    /// 需要临时目录与假 App 的用例，按声明顺序编号，由父进程逐个拉起子进程执行
    static var cases: [(name: String, layout: Layout, actions: Actions, check: (Environment) -> Void)] = []

    static func runScenario(_ name: String, layout: Layout, actions: Actions, check: @escaping (Environment) -> Void) {
        cases.append((name, layout, actions, check))
    }

    /// 用例声明：父进程注册后逐个拉起子进程执行
    static func declareCases() {
        runScenario(
            "成功替换：旧版进备份、新版就位、等待回执后才清理",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0"), actions: .init(),
            check: { env in
                precondition(env.newVersion(at: env.target) == "2.0.0", "目标应为新版")
                precondition(env.newVersion(at: env.backup) == "1.0.0", "备份应为旧版")
                precondition(FileManager.default.fileExists(atPath: env.receipt.path), "应写入待确认回执")
                precondition(!FileManager.default.fileExists(atPath: env.errorLog.path), "成功时不应留错误")
                precondition(env.calls.contains { $0.contains("open") && $0.contains(env.target.path) }, "应重新拉起")
                precondition(env.calls.contains { $0.contains("killall FinderRightSync") }, "应结束旧扩展进程")
                precondition(!FileManager.default.fileExists(atPath: env.newApp.path), "成功后清理解压出的新版本")
                precondition(!FileManager.default.fileExists(atPath: env.baseDir.path), "成功后清理临时目录")
                // 回执与备份：后台启动同样走到了初始化完成（自动更新重启就是后台启动），应当确认
                do {
                        try withTemporaryStateHome(home: env.home) {
                            let receipt = UpdateInstallReceipt.load()
                            precondition(receipt?.version == "2.0.0", "应读到回执，实际 \(String(describing: receipt)) 文件 \(env.receipt.path) 存在=\(FileManager.default.fileExists(atPath: env.receipt.path))")
                            UpdateInstallReceipt.useRunningBundle(env.target) {
                            precondition(UpdateInstallReceipt.decide(receipt: receipt, currentVersion: "2.0.0"),
                                         "后台启动完成初始化同样应确认回执")
                            precondition(UpdateInstallReceipt.decide(receipt: receipt, currentVersion: "2.1.0"),
                                         "更高版本应一并完成旧回执")
                            precondition(!UpdateInstallReceipt.decide(receipt: receipt, currentVersion: "1.9.9"),
                                         "版本低于待确认版本不能确认")
                            UpdateInstallReceipt.complete()
                            precondition(UpdateInstallReceipt.load() == nil, "回执应被删除")
                            precondition(!FileManager.default.fileExists(atPath: env.backup.path), "确认后清理备份")
                            UpdateInstallReceipt.complete()
                            UpdateInstallReceipt.complete()
                            precondition(env.newVersion(at: env.target) == "2.0.0", "重复处理确认不能改动目标")
                        }
                        // 清理失败保留回执，下次启动重试；运行实例与回执目标不符时不能动备份
                        try FileManager.default.createDirectory(at: env.backup, withIntermediateDirectories: true)
                        try Data("old".utf8).write(to: env.backup.appendingPathComponent("marker"))
                        let pending: [String: Any] = ["version": "2.0.0", "backup": env.backup.path]
                        try PropertyListSerialization.data(fromPropertyList: pending, format: .xml, options: 0)
                            .write(to: UpdateInstallReceipt.receiptURL)
                        precondition(UpdateInstallReceipt.load() != nil, "预置回执应可读回")
                        try UpdateInstallReceipt.useRunningBundle(env.target) {
                            UpdateInstallReceipt.useRunningBundle(URL(fileURLWithPath: "/nonexistent-instance/FinderRight.app")) {
                                UpdateInstallReceipt.complete()
                                precondition(UpdateInstallReceipt.load() != nil && FileManager.default.fileExists(atPath: env.backup.path),
                                             "运行实例与回执目标不符时不能清理")
                            }
                            // 备份删除失败（目录不可写）：回执与备份都保留，下次启动重试
                            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: env.backup.path)
                            UpdateInstallReceipt.complete()
                            precondition(FileManager.default.fileExists(atPath: env.backup.path), "清理失败应保留备份")
                            precondition(UpdateInstallReceipt.load() != nil, "清理失败应保留回执以便重试")
                            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.backup.path)
                            UpdateInstallReceipt.complete()
                            precondition(!FileManager.default.fileExists(atPath: env.backup.path), "重试应完成清理")
                            precondition(UpdateInstallReceipt.load() == nil, "清理成功后删除回执")
                        }
                    }
                } catch {
                    preconditionFailure("回执确认检查失败: \(error)")
                }
            })

        runScenario(
            "复制失败：目标仍是旧版、重新拉起、记录真实失败",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0"), actions: .init(failing: "cp"),
            check: { env in
                precondition(env.newVersion(at: env.target) == "1.0.0", "目标应保持旧版")
                precondition(!FileManager.default.fileExists(atPath: env.receipt.path), "失败不写回执")
                precondition(env.error == "COPY", "错误应是 COPY，实际 \(String(describing: env.error))")
                precondition(env.calls.contains { $0.contains("open") }, "应重新拉起旧版")
            })

        runScenario(
            "旧版备份失败：旧版仍在原位、不误报已回滚",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0"), actions: .init(failing: "backup-mv"),
            check: { env in
                precondition(env.newVersion(at: env.target) == "1.0.0", "目标应保持旧版")
                precondition(env.error == "BACKUP", "错误应是 BACKUP，实际 \(String(describing: env.error))")
                precondition(!env.errorText.contains("restored"), "不能提示已回滚")
            })

        runScenario(
            "新版移入失败：回滚旧版并如实记录",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0"), actions: .init(failing: "move-in"),
            check: { env in
                precondition(env.newVersion(at: env.target) == "1.0.0", "旧版应回到目标位置")
                precondition(!FileManager.default.fileExists(atPath: env.backup.path), "回滚成功后不再留备份")
                precondition(env.error == "MOVE_ROLLED_BACK", "错误应是 MOVE_ROLLED_BACK，实际 \(String(describing: env.error))")
            })

        runScenario(
            "回滚失败：不得提示已回滚，备份与待确认状态保留",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0"), actions: .init(failing: "move-in", failRollback: true),
            check: { env in
                for leftover in ["FinderRight.new.app", "FinderRight.failed.app"] {
                    let url = env.target.deletingLastPathComponent().appendingPathComponent(leftover)
                    precondition(!FileManager.default.fileExists(atPath: url.path), "不应留下 \(leftover)")
                }
                precondition(env.newVersion(at: env.backup) == "1.0.0", "旧版留在备份位置")
                precondition(env.error == "MOVE_STUCK", "错误应是 MOVE_STUCK，实际 \(String(describing: env.error))")
                precondition(!env.errorText.contains("restored"), "回滚失败不能提示已回滚")
            })

        runScenario(
            "启动失败：尝试恢复旧版并记录",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0"), actions: .init(failing: "first-open"),
            check: { env in
                precondition(env.error == "LAUNCH_ROLLED_BACK", "错误应是 LAUNCH_ROLLED_BACK，实际 \(String(describing: env.error))")
                precondition(!FileManager.default.fileExists(atPath: env.receipt.path), "启动失败作废回执")
                precondition(env.newVersion(at: env.target) == "1.0.0", "启动失败应把旧版放回原位")
                precondition(!FileManager.default.fileExists(atPath: env.backup.path), "旧版已回原位，不再留备份")
                let failed = env.target.deletingLastPathComponent().appendingPathComponent("FinderRight.failed.app")
                precondition(env.newVersion(at: failed) == "2.0.0", "启动失败的新版挪到 .failed.app 供排查")
                precondition(env.calls.filter { $0.contains("open") }.count >= 2, "应尝试重新拉起")
            })

        runScenario(
            "启动失败且目标缺失：用备份恢复旧版",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0"), actions: .init(failing: "first-open", removeTargetOnLaunchFailure: true),
            check: { env in
                precondition(env.newVersion(at: env.target) == "1.0.0", "旧版应恢复到目标位置")
                precondition(!FileManager.default.fileExists(atPath: env.backup.path), "恢复后不再留备份")
                precondition(env.error == "LAUNCH_ROLLED_BACK", "错误应是 LAUNCH_ROLLED_BACK，实际 \(String(describing: env.error))")
            })

        runScenario(
            "版本不符：不替换，保留目标并报错",
            layout: .init(oldVersion: "1.0.0", newVersion: "1.5.0", expected: "2.0.0"), actions: .init(),
            check: { env in
                precondition(env.newVersion(at: env.target) == "1.0.0", "目标应保持旧版")
                precondition(env.errorText.hasPrefix("VERSION"), "错误应是 VERSION，实际 \(String(describing: env.error))")
                precondition(!FileManager.default.fileExists(atPath: env.receipt.path))
            })

        runScenario(
            "已有未确认备份：真实 mv 之前停止本次安装，不嵌套移动",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0", existingBackupVersion: "0.9.0"), actions: .init(),
            check: { env in
                // mv 到已存在的目录会把当前 App 嵌套成 FinderRight.old.app/FinderRight.app，
                // 之后回滚会把错误结构搬回目标位置、清理备份时连当前版本一起删——必须在动手前停下
                precondition(env.error == "SUSPENDED", "应报告更新暂停，实际 \(String(describing: env.error))")
                precondition(env.newVersion(at: env.target) == "1.0.0", "目标应保持旧版")
                precondition(env.newVersion(at: env.backup) == "0.9.0", "旧备份应原样保留")
                precondition(!FileManager.default.fileExists(atPath: env.backup.appendingPathComponent("FinderRight.app").path),
                             "备份里不能嵌套进本次的 App")
                precondition(!FileManager.default.fileExists(atPath: env.receipt.path), "停止时不应写回执")
                precondition(!FileManager.default.fileExists(atPath: env.baseDir.path), "停止后应清理解压产物")
                precondition(env.calls.contains { $0.contains("open") }, "应重新拉起旧版")
            })

        runScenario(
            "过期回执不阻塞安装：备份已不在时清掉回执并继续",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0", staleReceipt: true), actions: .init(),
            check: { env in
                precondition(env.newVersion(at: env.target) == "2.0.0", "应正常替换")
                precondition(env.newVersion(at: env.backup) == "1.0.0", "备份应是本次旧版")
                precondition(env.error == nil, "不应有错误：\(String(describing: env.error))")
                withTemporaryStateHome(home: env.home) {
                    let receipt = UpdateInstallReceipt.load()
                    precondition(receipt?.version == "2.0.0", "过期回执应被本次回执覆盖：\(String(describing: receipt))")
                }
            })

        runScenario(
            "目标被留空且备份还在：先恢复旧版再继续安装",
            layout: .init(oldVersion: nil, newVersion: "2.0.0", expected: "2.0.0", existingBackupVersion: "0.9.0"), actions: .init(),
            check: { env in
                precondition(env.newVersion(at: env.target) == "2.0.0", "应先恢复旧版再替换成新版")
                precondition(env.newVersion(at: env.backup) == "0.9.0", "恢复出来的旧版成为本次备份")
                precondition(FileManager.default.fileExists(atPath: env.receipt.path), "安装成功应写回执")
                precondition(env.error == nil, "不应有错误：\(String(describing: env.error))")
            })

        runScenario(
            "目标位置缺少 App（首次安装）：直接放入新版",
            layout: .init(oldVersion: nil, newVersion: "2.0.0", expected: "2.0.0"), actions: .init(),
            check: { env in
                precondition(env.newVersion(at: env.target) == "2.0.0", "应放入新版")
                precondition(!FileManager.default.fileExists(atPath: env.backup.path), "没有旧版就不应有备份")
            })

        runScenario(
            "备份路径含 & 或 < 时回执可被正常解析并清理",
            layout: .init(oldVersion: "1.0.0", newVersion: "2.0.0", expected: "2.0.0",
                          installDirectoryName: "Tools & Apps <test>"), actions: .init(),
            check: { env in
                precondition(FileManager.default.fileExists(atPath: env.receipt.path),
                             "应写入回执，路径=\(env.receipt.path)")
                // 回执必须是合法 plist，即使备份路径含 & 或 < 这些 XML 特殊字符
                withTemporaryStateHome(home: env.home) {
                    let receipt = UpdateInstallReceipt.load()
                    precondition(receipt != nil,
                                 "含特殊字符路径的回执应可被成功解析，文件=\(env.receipt.path)")
                    precondition(receipt?.version == "2.0.0",
                                 "版本应正确，实际 \(String(describing: receipt?.version))")
                    // backup 字段必须保留原始路径（含 & 与 <），XML 转义由 plist 解析层还原
                    let backupPath = receipt?.backupPath ?? ""
                    precondition(backupPath.contains("&") && backupPath.contains("<"),
                                 "backup 字段应保留原始路径中的 & 和 <，实际=\(backupPath)")
                    // 完整流程：确认 → 清理备份
                    UpdateInstallReceipt.useRunningBundle(env.target) {
                        UpdateInstallReceipt.complete()
                        precondition(!FileManager.default.fileExists(atPath: env.backup.path),
                                     "确认后应清理备份")
                        precondition(UpdateInstallReceipt.load() == nil,
                                     "确认后应删除回执")
                    }
                }
            })
    }

    static func runChild(index: Int, cases: [(name: String, layout: Layout, actions: Actions, check: (Environment) -> Void)]) {
        guard cases.indices.contains(index) else { exit(2) }
        let entry = cases[index]
        do {
            let env = try run(layout: entry.layout, actions: entry.actions)
            entry.check(env)
            print("✓ \(entry.name)")
            exit(0)
        } catch {
            print("✗ \(entry.name)：\(error)")
            exit(1)
        }
    }

    static func run(layout: Layout, actions: Actions) throws -> Environment {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fr-relaunch-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home", isDirectory: true)
        let appsDirectory = root.appendingPathComponent(layout.installDirectoryName ?? trickyDirectoryName, isDirectory: true)
        let baseDir = root.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        let target = appsDirectory.appendingPathComponent("FinderRight.app", isDirectory: true)
        let backup = appsDirectory.appendingPathComponent("FinderRight.old.app", isDirectory: true)
        let newApp = baseDir.appendingPathComponent("FinderRight.app", isDirectory: true)
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let callsFile = root.appendingPathComponent("calls.log")
        let stateDir = home.appendingPathComponent("Library/Application Support/FinderRight", isDirectory: true)
        let receipt = stateDir.appendingPathComponent("update-pending.plist")
        let errorLog = stateDir.appendingPathComponent("last-update-error.txt")
        let fileManager = FileManager.default

        try fileManager.createDirectory(at: appsDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try "calls\n".write(to: callsFile, atomically: true, encoding: .utf8)
        if let oldVersion = layout.oldVersion { try makeApp(at: target, version: oldVersion) }
        try makeApp(at: newApp, version: layout.newVersion)
        if let existing = layout.existingBackupVersion { try makeApp(at: backup, version: existing) }
        if layout.staleReceipt {
            let pending: [String: Any] = ["version": "0.9.0", "backup": backup.path]
            try PropertyListSerialization.data(fromPropertyList: pending, format: .xml, options: 0)
                .write(to: receipt)
        }

        let homePath = home.path
        let callsPath = callsFile.path
        let fail = actions.failing ?? ""

        // 假的系统命令：只记录调用；cp 真的复制（新版本 App 里没有扩展，所以也能模拟备份失败）
        let cpBody = """
        #!/bin/bash
        echo "cp $*" >> "\(callsPath)"
        if [ "${FR_FAKE_FAIL:-}" = "cp" ]; then exit 1; fi
        exec /bin/cp "$@"
        """
        // 假命令按环境变量决定失败点；按参数结尾的文件名判断是哪一步 mv，不依赖路径里的引号
        // （路径本身含换行以外的任意字符，比较时只认结尾的 bundle 名）
        let mvBody = """
        #!/bin/bash
        echo "mv $*" >> "\(callsPath)"
        # 参数第 1 个是来源、第 2 个是目标：按它们在目标目录里的位置判断是哪一步
        case "$1" in */FinderRight.new.app) FROM=new ;; */FinderRight.old.app) FROM=old ;; *) FROM=other ;; esac
        case "$2" in */FinderRight.old.app) TO=old ;; */FinderRight.app) TO=target ;; *) TO=other ;; esac
        if [ "${FR_FAKE_FAIL:-}" = "backup-mv" ] && [ "$FROM" = "other" ] && [ "$TO" = "old" ]; then exit 1; fi
        if [ "${FR_FAKE_FAIL:-}" = "move-in" ] && [ "$FROM" = "new" ] && [ "$TO" = "target" ]; then exit 1; fi
        if [ "${FR_FAKE_FAIL_ROLLBACK:-}" = "1" ] && [ "$FROM" = "old" ] && [ "$TO" = "target" ]; then exit 1; fi
        exec /bin/mv "$@"
        """
        let openBody = """
        #!/bin/bash
        echo "open $*" >> "\(callsPath)"
        if [ "${FR_FAKE_FAIL:-}" = "first-open" ] && ! grep -q "open-failed" "\(callsPath)"; then
            echo "open-failed" >> "\(callsPath)"
            if [ "${FR_FAKE_REMOVE_TARGET:-}" = "1" ]; then
                for arg in "$@"; do
                    case "$arg" in
                        */FinderRight.app) LAST_DIR="${arg%/FinderRight.app}" ;;
                    esac
                done
                /bin/mv "$LAST_DIR/FinderRight.app" "$LAST_DIR/FinderRight.launched-away.app"
            fi
            exit 1
        fi
        exit 0
        """
        let noopBody = {
            (name: String) in "#!/bin/bash\necho \"\(name) $*\" >> \"\(callsPath)\"\nexit 0\n"
        }
        try write("cp", cpBody, in: binDir)
        try write("mv", mvBody, in: binDir)
        try write("open", openBody, in: binDir)
        try write("killall", noopBody("killall"), in: binDir)
        try write("lsregister", noopBody("lsregister"), in: binDir)
        try write("xattr", noopBody("xattr"), in: binDir)
        try write("date", noopBody("date"), in: binDir)

        // 替换脚本会从当前环境继承设置：先改本进程的环境，再取整份 environment 交给脚本，
        // 避免沿用父进程（可能是上一个用例）的失败点
        setenv("FR_FAKE_FAIL", fail, 1)
        setenv("FR_FAKE_FAIL_ROLLBACK", actions.failRollback ? "1" : "0", 1)
        setenv("FR_FAKE_REMOVE_TARGET", actions.removeTargetOnLaunchFailure ? "1" : "0", 1)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homePath
        environment["PATH"] = "\(binDir.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["FR_COPY_FAILED"] = "COPY"
        environment["FR_BACKUP_FAILED"] = "BACKUP"
        environment["FR_MOVE_FAILED_ROLLED_BACK"] = "MOVE_ROLLED_BACK"
        environment["FR_MOVE_FAILED_STUCK"] = "MOVE_STUCK"
        environment["FR_LAUNCH_FAILED"] = "LAUNCH_FAILED"
        environment["FR_LAUNCH_FAILED_ROLLED_BACK"] = "LAUNCH_ROLLED_BACK"
        environment["FR_LAUNCH_FAILED_KEPT_BACKUP"] = "LAUNCH_KEPT_BACKUP"
        environment["FR_LAUNCH_ARG"] = "--show-settings"
        environment["FR_VERSION_MISMATCH"] = "VERSION"
        environment["FR_VERSION_MISMATCH_DETAIL"] = "VERSION"
        environment["FR_UPDATE_SUSPENDED"] = "SUSPENDED"

        // 生成与真实安装完全相同的替换脚本
        let scriptURL = root.appendingPathComponent("relaunch.sh")
        try UpdateChecker.relaunchScript().write(to: scriptURL, atomically: true, encoding: .utf8)

        // 让一个用完即退的哨兵进程充当「旧的 FinderRight」：脚本会等这个 PID 退出后才会替换。
        // 不能用测试进程自己——脚本正经由本进程运行，等它退出就成了死锁。
        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
        oldProcess.arguments = ["-c", "sleep 0.3"]
        try oldProcess.run()
        defer { oldProcess.waitUntilExit() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, String(oldProcess.processIdentifier), target.path, newApp.path, layout.expected, "manual"]
        process.environment = environment
        process.currentDirectoryURL = root
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        try? String(process.processIdentifier).write(to: root.appendingPathComponent("relaunch.pid"), atomically: true, encoding: .utf8)
        pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 失败的用例脚本本来就返回非零，由各用例自行核对状态
        _ = process.terminationStatus

        let calls = (try? String(contentsOf: callsFile, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        let errorText = (try? String(contentsOf: errorLog, encoding: .utf8)) ?? ""
        // 目录名里的 $(…) 只会在被 shell 当代码执行时展开；只查这些目录自己的直接子项
        if containsInjectedFile(in: [appsDirectory, baseDir, root, home]) {
            throw Failure("路径中的 $() 被执行了")
        }

        return Environment(home: home, root: root, target: target, backup: backup, newApp: newApp, baseDir: baseDir,
                           receipt: receipt, errorLog: errorLog, calls: calls,
                           error: errorText.isEmpty ? nil : errorText.trimmingCharacters(in: .whitespacesAndNewlines),
                           errorText: errorText)
    }

    /// 回执读写走 IPCBridge（真实用户主目录），换成临时 HOME 里的状态目录，绝不能碰到真实文件
    // 回执默认读写真实用户目录（IPCBridge 用 getpwuid 取主目录，改 HOME 无效）；
    // 这里让被测函数改读临时场景目录，绝不碰真实文件
    static func withTemporaryStateHome<T>(home folder: URL, _ body: () throws -> T) rethrows -> T {
        try UpdateInstallReceipt.useDirectory(folder.appendingPathComponent("Library/Application Support/FinderRight")) {
            try body()
        }
    }

    /// 只清理本脚本在临时目录里的产物
    static func cleanRestoreCopies() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: temp.path) else { return }
        for item in items where item.hasPrefix("fr-relaunch-") {
            try? FileManager.default.removeItem(at: temp.appendingPathComponent(item))
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func containsInjectedFile(in directories: [URL]) -> Bool {
        directories.contains { directory in
            let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return items.contains("PWNED") || items.contains("PWNED2")
        }
    }

    static func write(_ name: String, _ body: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func makeApp(at url: URL, version: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.finderright.app",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": "1",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
