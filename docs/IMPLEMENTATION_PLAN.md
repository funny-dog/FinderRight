# FinderRight 改动方案（v1.1.9 开发计划）

> 本方案由两轮代码审计合并而成，供实施者（Gemini）按批次执行，每批次独立可验收、独立提交。
> 所有行号基于 v1.1.8（commit 0a2cd9c）源码。改动前请先读对应文件确认现状，行号可能有小幅漂移。
>
> **全局约束（禁止违反）**：
> 1. 项目必须保持「无 Xcode 仅用 CommandLineTools 可构建」：`scripts/build.sh` 全链路（swiftc 直编 + ad-hoc 签名）改动后必须通过。
> 2. 主 App 保持非沙箱（空 entitlements）、`LSUIElement=true`；扩展保持 app-sandbox 及现有 temporary-exception 不变。签名流程严禁加 `--deep`（build.sh 注释里写明了原因，历史回归过）。
> 3. 不得回归以下历史修复（都有注释标记，勿删勿改语义）：
>    - `AppDelegate.applicationShouldHandleReopen` 是弹设置的唯一入口，不要在 `applicationDidBecomeActive` 弹窗（2026-09 修复）；
>    - `defaultsChanged` 的 `isUpdatingStatusItemVisibility` 防重入标志（防栈溢出）；
>    - `FinderSync.installedEditors()` 的 `hasChecked` 区分「未检测」与「检测为空」；
>    - 扩展 `entitlements` 里 `/Volumes/` 与 CloudStorage 的读写例外。
> 4. 所有改动只写必要的最小 diff；不要顺手重构无关代码；不要改 `FRState` 属性包装器。
> 5. 文案走「中文做 key、en.lproj 给英文」的既有本地化模式，新增菜单/设置文案必须同步补 `FinderRight/en.lproj/Localizable.strings` 和 `FinderRightSync/en.lproj/Localizable.strings`。

---

## 批次 A：数据安全与高危修复（最高优先级，一个 commit）

### A1. 剪切改为 Lazy Cut（延迟剪切）

**问题**：`FinderRight/Services/FinderRightService.swift:415-474` `cutFiles` 在点击「剪切」瞬间即 `moveItem` 把文件物理移入 `staging/`（系统盘）。跨卷剪切大文件会全量拷贝进系统盘（慢、磨损、可撑爆磁盘）；且剪切后未粘贴时原位置文件已消失，造成「文件被删」假象；扩展 10s 超时还会报「失败」但主 App 继续移动（假失败）。

**改法**：
1. `cutFiles(_:)` 不再调用 `moveItem`。只做：
   - 校验每个源路径存在；
   - 将**源路径**合并写入 `cut-queue.json`（复用现有 `cutPasteQueue` 串行队列保证互斥）；
   - 立即返回成功。
2. `pasteFiles` / `performPaste` 改为：从 `cut-queue.json` 读源路径 → 直接从源路径 `moveItem` 到目标目录（冲突自动重命名逻辑保留现有实现）→ 成功项从队列移除，失败项保留（现有语义保留）。
3. 删除 `stagingDirectory` 相关代码；`FinderRightKit` 无需改动（`cut-queue.json` 路径不变，扩展侧 `hasCutQueue()` 不用改——队列里存的源路径本来就存在，判断逻辑天然兼容）。
4. **一次性迁移**：主 App 启动时（`IPCWatcher.start()` 或 `AppDelegate.applicationDidFinishLaunching`）检查旧 `staging/` 目录：若存在遗留文件，发一条 `UNUserNotification` 告知用户「暂存区有 N 个历史遗留文件，位于 ~/Library/Application Support/FinderRight/staging」，**不要自动移动或删除**。
5. 边界处理：
   - 粘贴目标目录与源文件所在目录相同 → 跳过该文件（视为无操作），不生成 `xxx 1` 副本；
   - 粘贴时源文件已被外部删除 → 跳过并从队列剔除（现有 `performPaste` 语义已有，保留）；
   - 同一文件被重复剪切 → 队列去重。

**验收**：
- 同卷剪切+粘贴：瞬时完成，源目录文件在粘贴前始终可见；
- 跨卷剪切：点击剪切后源文件**不移动**，粘贴时数据从源卷直接流向目标卷，系统盘 `~/Library/Application Support/FinderRight/` 下无大文件中转；
- 剪切后不粘贴直接退出/重启 App：文件原位不动，重启后粘贴仍可用；
- 云盘目录（iCloud Drive）用 Services 剪切后，文件仍在原地（解决「云盘剪切有去无回」的数据丢失假象）。

### A2. 裸 .xz Python 回退改流式解压

**问题**：`FinderRightService.swift:174` `lzma.open(sys.argv[1]).read()` 把整个解压结果一次性读进内存，大文件 OOM（python3 子进程被 jetsam）。

**改法**：一行替换为分块流式：
```
import lzma, sys, shutil; shutil.copyfileobj(lzma.open(sys.argv[1]), sys.stdout.buffer)
```

**验收**：构造/下载一个解压后 ≥1GB 的 `.xz`（无 xz CLI 的环境或用 `env PATH=` 模拟回退路径），解压成功且 python3 进程峰值内存 <100MB（`ps -o rss` 观察）。

### A3. ZIP 压缩/解压统一换 ditto（双向解决中文乱码）

**问题**：
- 解压：`FinderRightService.swift:234` 用 `/usr/bin/unzip`，Windows GBK 编码的中文 ZIP 文件名必乱码；
- 压缩：`:84` 用 `/usr/bin/zip -r`，生成的中文文件名 ZIP 未设 UTF-8 flag，在 Windows 上打开乱码（报告的镜像问题）。

**改法**：
- 解压 ZIP 分支：`/usr/bin/unzip` → `/usr/bin/ditto -x -k <archive> <targetDir>`；
- 压缩：`/usr/bin/zip -r <dest> <names...>` → `/usr/bin/ditto -c -k --sequesterRsrc <dest> <names...>`（`currentDirectoryURL` 语义与现有保持一致，产物仍是不含父目录路径的平铺 zip；注意保持多选压缩命名为 `Archive.zip` 的现有逻辑）；
- `UpdateChecker.swift:199` 解压更新包的 `unzip` **保留不动**（更新包是构建机自产自销，无编码问题，减少变量）。

**验收**：
- 用 Windows 压缩一个含中文路径的 ZIP（GBK 编码）→ 本应用解压文件名无乱码；
- 本应用压缩含中文文件名的目录 → 产物在 Windows 资源管理器打开无乱码；
- 含 symlinks、空目录、深层嵌套的目录压缩/解压往返一致。

### A4. 更新安装前置权限检查 + 失败可见

**问题**：`UpdateChecker.swift:286-291` 启动 relaunch.sh 后立即 `NSApp.terminate`，脚本 `mv` 因权限失败时应用「莫名关闭」，无任何提示。

**改法**：
1. `performInstallAndRelaunch` 在写脚本**之前**：检查 `targetAppURL` 及其父目录对当前用户可写（`FileManager.isWritableFile`）；不可写则回调错误「无权限写入 /Applications，请手动下载安装」并打开 release 页面，**不退出 App**；
2. relaunch.sh 末尾追加失败留痕：任一关键步骤失败时把错误写入 `~/Library/Application Support/FinderRight/last-update-error.txt`（脚本各 exit 1 分支前 echo 原因）；
3. 新版 App 启动时检查该文件：存在则弹一次 alert 展示失败原因并删除该文件。

**验收**：`chmod 555` 模拟只读 /Applications（或把 App 放在无写权限目录）走自动更新 → 应用不退出、有明确错误提示。

### A5. 更新包 SHA256 校验

**问题**：自动更新对下载产物零校验，GitHub 账号被盗即供应链 RCE。

**改法**：
1. `build.sh` 打包时同时生成 `FinderRight-v$VERSION.zip.sha256`（`shasum -a 256` 输出，标准 `sha256sum` 文本格式）；
2. `UpdateChecker` 发现 update 时，若 assets 里存在同名 `.sha256` 则一并下载；安装前校验 ZIP 哈希，不匹配则报「更新包校验失败」并终止安装（不退出 App）；
3. 历史 release 没有 .sha256 资产时：降级为警告日志但允许安装（向后兼容），代码里留 TODO 注释「v1.2.0 起强制要求校验和」。

**验收**：手动篡改下载的 ZIP 一字节 → 安装被阻断并报错。

---

## 批次 B：健壮性（一个 commit）

### B1. SharedConfig 线程安全

**问题**：`FinderRightKit/.../SharedConfig.swift` 的 `store` 字典被 UI 线程、`IPCWatcher.queue`、`ServicesProvider.workQueue` 并发读写，无锁。

**改法**：加 `NSLock`，`load()`/`save()`/所有 getter/setter 的 `store` 访问全部持锁（注意不要在持锁状态下递归调用自身方法导致死锁——getter/setter 内部如调用 `save()`，改用可重入锁 `NSRecursiveLock` 或调整结构使锁粒度只在 `store` 读写瞬间）。

**验收**：新增单元测试：8 线程并发读写 `enabledActions`/`customFileTemplates` 10 万次不崩溃、数据不撕裂（见批次 E 测试基建）。

### B2. UpdateChecker 失败不计入 10 分钟缓存

**问题**：`UpdateChecker.swift:70,81,92` 失败分支都写了 `lastCheckedDate`，网络抖动后 10 分钟内非 force 检查直接返回缓存失败。

**改法**：`lastCheckedDate` 只在成功得到结论（`upToDate`/`updateAvailable`）时更新；失败分支不更新。

### B3. IPC 目录孤儿文件清扫

**改法**：`IPCWatcher.start()` 增加：扫描 `pendingDir`，删除 mtime 超过 10 分钟的 `*.req.json` / `*.resp.json`（主 App 处理中途崩溃、扩展解析失败都会留残留）。

### B4. home 路径解析改 getpwuid

**问题**：`FinderRightKit/.../XPCEndpointBridge.swift:19` `/Users/\(NSUserName())` 硬编码，网络账户/非常规 home 失效。

**改法**：改读 `getpwuid(getuid())?.pw_dir`，失败再回退现有拼法。注意不能用 `NSHomeDirectory()`（沙箱下返回容器路径，这正是当初硬编码的原因——保留该注释并补充说明）。

### B5. IPC 服务端路径白名单（安全加固）

**问题**：文件 IPC 无鉴权，本机任意进程可伪造 req 借主 App 的 FDA 执行文件操作。完全解决需 XPC + audit token（成本高，本期不做，代码留 TODO）；先做低成本收敛。

**改法**：`FinderRightService.handle(_:)` 入口统一校验：所有 payload 中的文件路径参数，展开 `~` 与解析 symlink 后必须位于 ① 用户真实 home、② `/Volumes`、③ `NSTemporaryDirectory()` 三者之一，否则返回「路径越界」错误。`openTerminal`/`openWithApp` 的 `bundleId` 参数校验 bundle id 字符集（字母数字点横线），防注入。

**验收**：手工构造指向 `/etc/`、`/System/` 的伪造 req 文件 + `open finderright://execute?id=...` → 全部拒绝并记日志；正常右键功能全部不受影响。

---

## 批次 C：性能与体验（一个 commit）

### C1. 扩展主线程去阻塞

**问题**：`FinderRightSync/FinderSync.swift` 各 action 在主线程同步调 `IPCClient.call()`（`XPCClient.swift` 内部 `Thread.sleep` 轮询最长 10~30s），主 App 卡顿时 Finder 右键彩球。

**改法**：`IPCClient` 新增 `callAsync(action:payload:completion?)`（内部就是把现有 `call` 包到后台队列，completion 回主线程可选）；`FinderSync` 中 `openTerminal`/`cutFiles`/`pasteFiles`/`archiveOperation`/`toggleHiddenFiles`/`newFile`/`openEditorWith` 全部改用 `callAsync`，结果只记日志（这些 action 本来就不用结果驱动 UI）。`copyPath` 不走 IPC 无需改。

**验收**：右键点击任一功能，菜单立即收起、Finder 无卡顿；主 App 被 `kill -STOP` 冻结时点「打开终端」，Finder 不彩球，10s 后日志出现超时记录。

### C2. beginActivity 不再永久持有

**问题**：`FinderSync.swift:108-111` `beginActivity(.latencyCritical)` 永不 `endActivity`，压制系统节能调度。

**改法**：删除 init 中的永久 activity（菜单构建本身已优化到毫秒级，不需要常驻 latencyCritical）。若担心回归，备选：仅在 `menu(for:)` 构建期间临时 begin/end。**任选其一，提交说明里写明选择理由。**

### C3. 隐藏文件状态回写与菜单文案联动

**问题**：`FinderRightService.toggleHiddenFiles` 从不回写状态，`FinderSync.swift:282` 菜单文案永远固定「切换隐藏文件」（strings 里已备有「显示隐藏文件」「隐藏隐藏文件」文案但无引用）。

**改法**：
1. `toggleHiddenFiles` 两条路径（CGEvent 与 defaults 降级）成功后，都从 `UserDefaults(suiteName: "com.apple.finder")` 读 `AppleShowAllFiles` 实际值回写 `SharedConfig.shared.showHiddenFiles`；
2. 扩展 `menu(for:)` 构建该项时读 `SharedConfig.shared.showHiddenFiles`：true → 文案「隐藏隐藏文件」，false → 「显示隐藏文件」；
3. CGEvent 路径发键后 defaults 生效有毫秒级延迟，回写前 `usleep(100_000)` 或直接读之前先同步 `CFPreferencesAppSynchronize`。

**验收**：连续点两次该项，菜单文案在「显示/隐藏隐藏文件」间正确翻转，与 Finder 实际显示状态一致。

### C4. 后台任务失败用户可见

**问题**：压缩/解压/粘贴全部异步「已受理」，失败只写 `serviceLog`，用户零感知（损坏 ZIP、加密 RAR、磁盘满全都静默）。

**改法**：主 App 接入 `UNUserNotificationCenter`（启动时 requestAuthorization，仅 alert+sound）；`performDecompress`/`compressZip` 回调/`performPaste` 失败分支发本地通知，标题含操作类型，body 含文件名与错误摘要。同时保留 serviceLog。

**验收**：对一个损坏的 ZIP 执行解压 → 10 秒内收到系统通知「解压失败」；通知权限被拒绝时功能不受影响（仅无通知）。

### C5. 快捷键设置页补说明 + 冲突检测

**改法**（`SettingsView.swift` ShortcutsTab）：
1. footer 追加说明：「快捷键仅在 Finder 右键菜单已展开时生效，不是全局热键」（中英文案都补）；
2. `finishRecording` 前检查新快捷键是否与其他 actionId 冲突，冲突则弹 alert「已被『xxx』占用」并拒绝保存；
3. 「打开编辑器」「新建文件」两个 shortcutId 接入：扩展 `makeSubmenuItem` 增加可选 `shortcutId` 参数（子菜单父项设 keyEquivalent 在菜单展开时可触发展开子菜单），`FinderSync.swift` 对应两处传入 `shortcut.openEditor`/`shortcut.newFile`，SettingsView actions 列表补这两行。

---

## 批次 D：功能补完（一个 commit）

### D1. 自定义文件模板接入

**现状**：`SharedConfig` 已有 `FileTemplate` 模型与 `addFileTemplate`/`removeFileTemplate`，但无 UI、右键菜单写死 10 种（`FinderSync.swift:367-386`）。

**改法**：
1. 设置界面「功能」Tab 新增「自定义文件模板」Section：列表展示（名称+后缀）、添加（名称/后缀/模板内容三字段表单）、删除；直接读写 `SharedConfig.shared.customFileTemplates`；
2. `buildNewFileMenu`：内置 10 种（tag 0-9）之后追加分隔线 + 自定义模板，tag 用 `1000 + index`；`newFile(_:)` 中 `sender.tag >= 1000` 时从 `SharedConfig.shared.customFileTemplates[tag-1000]` 取 ext/content，注意越界防护；
3. 模板名为用户输入的中文/英文原文，不走本地化。

**验收**：设置里加一个 `.log` 模板（内容含日期占位文本）→ Finder 右键「新建文件」子菜单出现该项 → 点击创建成功且内容一致 → 删除模板后菜单不再显示。

### D2. Services 菜单多语言

**问题**：`FinderRight/Info.plist:56-162` 六条 NSServices 菜单名硬编码中文，英文系统下 Services 子菜单仍显示中文。

**改法**：NSServices 的 `NSMenuItem` 字典支持按语言键覆盖：保留 `default` 为英文，增加 `zh-Hans` 键为中文（如 `<key>default</key><string>FinderRight: Copy Path</string>` + `<key>zh-Hans</key><string>FinderRight：复制路径</string>`）。**先在一台英文语言环境的系统/虚拟机上验证该机制生效**；若实测 macOS 版本不支持语言键，则回退方案：`default` 固定英文（Services 是系统级菜单，英文可接受），提交说明记录实测结论。

---

## 批次 E：工程化（一个 commit）

### E1. 删除 SwiftUI Settings scene（消除双设置窗口）

**问题**：`FinderRightApp.swift:19-22` 的 `Settings { SettingsView() }` 与 AppDelegate 自建 `settingsWindow` 是两个独立窗口实例，⌘, 与菜单栏「设置...」打开的窗口状态各自独立。

**改法**：删除 `Settings` scene（body 留空 Scene 按 SwiftUI 要求可返回 `WindowGroup { EmptyView() }` 隐藏处理——实测若空 WindowGroup 会闪现空窗，改用 `Settings { EmptyView() }`）；AppDelegate 的 `openSettings()` 保持唯一入口，⌘, 在 AppKit 窗口体系下天然映射到菜单栏「设置...」项（`keyEquivalent: ","` 已配置）。**验收时确认 ⌘, 能唤起 AppKit 设置窗口**；若不能，在状态栏菜单 NSMenu 层补 keyEquivalent 即可（已存在）。

### E2. 版本号单一来源

**问题**：1.1.8 硬编码在主 `Info.plist`、扩展 `Info.plist`、`build.sh VERSION` 三处（CFBundleVersion 两处）。

**改法**：`build.sh` 改为用 `/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" FinderRight/Info.plist` 读取版本号；扩展 plist 的版本字段在 sed 替换时与主 plist 对齐。今后 bump 版本只改主 `Info.plist` 两处（ShortVersion + Build）。

### E3. FinderRightKit 单元测试 + CI 脚本

**改法**：
1. `FinderRightKit/Package.swift` 加 `testTarget`；首批用例：
   - `AnyJSON` 编解码往返；
   - `SharedConfig` 读写/默认值/并发压测（B1 的验收用例）——`SharedConfig` 需支持注入测试用文件路径（加一个 `internal init(fileURL:)`，不影响 public API）；
   - `FileTemplate` Codable 往返；
   - 把 `UpdateChecker.compareVersions` **移至 FinderRightKit**（纯函数，主 App import 即可），补版本比较用例（含 `v1.1.8` vs `1.1.8`、`1.10` vs `1.9`、带 `-beta` 后缀）；
2. 新增 `scripts/ci.sh`：`swift build -c release --package-path FinderRightKit` + `swift test --package-path FinderRightKit` + 对主 App 与扩展跑 `swiftc -typecheck`（复用 build.sh 的编译参数），任一步失败非零退出。

**验收**：`./scripts/ci.sh` 本地全绿；故意改坏一处类型能正确报错退出。

---

## 实施顺序与提交策略

| 批次 | 内容 | 建议 commit 数 | 依赖 |
|---|---|---|---|
| A | 数据安全（Lazy Cut / xz / ditto / 更新权限 / SHA256） | 每项 1 个 commit | 无 |
| B | 健壮性（锁 / 缓存 / 清扫 / pw_dir / 路径白名单） | 1-2 个 | 无 |
| C | 性能体验（去阻塞 / activity / 隐藏文件 / 通知 / 快捷键） | 1-2 个 | C3 依赖 A1 不冲突；C4 与 A4 的通知基建可复用 |
| D | 功能补完（模板 / Services 多语言） | 1 个 | 无 |
| E | 工程化（双窗口 / 版本号 / 测试 CI） | 1-2 个 | E3 的 compareVersions 移动要在 A 批合并后做，防冲突 |

每批完成后必须 `./scripts/build.sh` 全量构建通过 + 真机右键冒烟（新建/复制路径/终端/剪切粘贴/压缩/解压/隐藏文件各点一次）再提交。

---

## 复核检查清单（WorkBuddy 复核时逐项核对）

1. `git diff` 逐文件审查，确认无顺手重构、无被删的历史修复注释；
2. A1：全工程搜 `staging`，确认只剩迁移提示逻辑；搜 `moveItem` 确认剪切路径不再调用；
3. A3：`ditto` 参数顺序（`ditto -c -k --sequesterRsrc 源... 目标` 与解压 `-x -k 源 目标` 参数位序不同，易错）；
4. B1：锁实现无递归死锁；B5：白名单不误伤 `~/Library/Mobile Documents`（云盘）与 `/Volumes`；
5. C1：扩展侧无残留主线程 `IPCClient.call` 同步调用（`copyPath` 除外）；
6. C3/E 批新增文案在两个 `en.lproj/Localizable.strings` 同步补齐；
7. `./scripts/build.sh` 从零干净构建（删 build/ 与 .build/out）通过，产物 ad-hoc 签名、扩展沙箱 entitlement 未被覆盖；
8. 真机验证批次验收项，重点：跨卷剪切大文件系统盘无中转、中文 ZIP 双向、⌘, 唤起设置、更新失败有提示。
