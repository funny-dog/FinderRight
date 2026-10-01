# 剪切角标归属权自动抢回 设计

日期：2026-10-02
状态：待审阅

## 1. 背景与根因

剪切角标「时好时坏」不是代码回归，而是 Finder Sync 的系统行为：

- 同一目录被多个 Finder Sync 扩展注册（含祖先目录覆盖，如注册 `/`）时，Finder 只把
  `requestBadgeIdentifier` 交给**最先注册**的扩展，即使它根本不用角标；其他扩展只收到
  `beginObserving` 与菜单回调，`setBadgeIdentifier` 不会显示。
- 各扩展随 Finder 启动并发注册，先后不确定，于是同一二进制有的会话 0 次角标回调、有的 200+ 次。
- 本机实测冲突者：Keka（精确注册 `~/Desktop` 等）、Pearcleaner（注册 `/`）、WeType。

已在真机确定性验证（2026-10-02 02:58，见扩展日志）：

1. Finder **不重启**，把竞争扩展 `pluginkit -e ignore` 后，归属立即转给本扩展；
2. 转移瞬间 Finder **主动**对当前可见项重新请求角标，无需用户切换目录；
3. 竞争扩展 `-e use` 恢复后，本扩展**保持**归属。

## 2. 目标与非目标

目标：无论用户装了哪些 Finder Sync 扩展，剪切角标都能可靠显示，且尽量少打扰其他扩展。

非目标：
- 不处理 File Provider 域（iCloud「桌面与文稿」、CloudStorage）——任何 Finder Sync 扩展都拿不到。
- 不识别「谁真正冲突」——其他扩展注册了哪些目录对我们不可见，只能观察结果。

## 3. 已确认的产品决策

| 决策 | 结论 |
|---|---|
| 触发方式 | 默认自动；设置中可关闭 |
| 重启范围 | 除本扩展外**所有已启用（`+`）**的 Finder Sync 扩展。接受副作用：本扩展取得归属的目录内，其他扩展（如网盘同步状态）的角标不再显示——设置开关即为出口 |
| 检测时机 | 扩展进程级「一次体检」：首次观察到目录后探测；剪切时兜底 |

## 4. 何时会丢失归属

取得归属后，只要本扩展不重新注册就一直保有全部注册目录的归属。会导致丢失的只有：

| 事件 | 应对 |
|---|---|
| Finder 重启（全体重新竞争） | 新扩展进程 → 体检 |
| 本扩展进程重启（更新、被杀、`pluginkit -a`） | 新扩展进程 → 体检 |
| 本扩展重设 `directoryURLs`（现状：插拔外接卷时） | **消除**：改为静态注册 `/Volumes`（见 §5.3） |
| 主 App 重启 | 不影响扩展进程，无需处理 |

因此「每个扩展进程最多被受理一次抢回」即可覆盖全部场景，用户频繁进出目录不会触发任何动作。

## 5. 设计

### 5.1 结构

```
扩展（沙箱，被动观察 + 判定）              主 App（非沙箱，执行）
┌─────────────────────────────┐  IPC   ┌──────────────────────────────────┐
│ BadgeOwnershipProbe (Kit)   │ ─────▶ │ BadgeOwnershipManager            │
│  记录收到 requestBadge 的目录 │reclaim │  核实目录有可见项 → 限流 →        │
│  判定丢失、每进程只申请一次   │Badge-  │  枚举启用扩展 → 写恢复标记 →      │
│  申请后核验是否抢回          │Owner-  │  ignore → 等待 → use → 核验 → 删标记│
└─────────────────────────────┘ ship   └──────────────────────────────────┘
```

纯逻辑全部放进 FinderRightKit 以便单测；扩展与主 App 只做系统调用与胶水。

### 5.2 扩展侧：`BadgeOwnershipProbe`

Kit 内的纯状态机（不依赖 FinderSync / AppKit，时钟通过参数注入）：

- `recordBadgeRequest(for url)`：把 `url` 的父目录（规范化路径）加入「已确认归属目录」集合。
- `isOwned(directory:)`：目录是否在已确认集合内。
- `canRequestReclaim(directory:)`：目录未确认、本进程尚无**被受理**的抢回、已尝试次数 < 2。
- `noteReclaimAttempt()` / `noteReclaimAccepted()`：记录一次尝试 / 主 App 已受理。
  被受理后本进程不再申请；被拒绝（限流、无法判定等）只消耗一次尝试，留出剪切兜底的机会。

`FinderSync` 中的接入点：

1. `requestBadgeIdentifier(for:)`：调用 `recordBadgeRequest`。
2. `beginObserving(at: D)`：本进程**首次**观察目录时（只探测一次），1.5 秒后检查：
   - 已确认 → 结束；
   - 未确认，且 `canRequestReclaim(D)`、**设置开启**、**主 App 正在运行**
     （`NSRunningApplication` 查 `com.finderright.app`）→ 发起抢回，原因 `probe`。
   - 主 App 未运行时不发（IPC 会唤醒主 App，不应因被动探测拉起用户主动退出的 App），
     留给剪切时兜底。
   - 1.5 秒依据：日志中 `requestBadge` 与 `beginObserving` 总在同一秒内到达。
3. `cutFiles`：若被剪切项父目录满足 `canRequestReclaim`、且设置开启 → 发起抢回，原因 `cut`
   （剪切本身就会唤醒主 App，无需检查运行状态）。
4. 发起抢回：`noteReclaimAttempt()`，IPC 发送
   `reclaimBadgeOwnership { directory: D, extPid, reason }`。主 App 立即返回受理结果；
   受理则 `noteReclaimAccepted()`，并在 3 秒后核验 `isOwned(D)`：成功记
   `badgeReclaim verified`；失败记 `badgeReclaim still lost`（不再重试——剩余冲突来自
   File Provider 域或无法处理的情况）。
5. 抢回成功后，Finder 会对可见项重新回调 `requestBadgeIdentifier`，现有逻辑据剪切队列
   （含内存乐观队列）给出角标，无需额外推送。

### 5.3 消除自身重新注册：静态注册 `/Volumes`

`buildMonitoredDirectories()` 改为固定集合：`~`、`~/Desktop`、`~/Downloads`、`~/Documents`、
`/Volumes`。删除卷挂载 / 卸载监听与 `updateMonitoredDirectories()`，此后 `directoryURLs`
在进程生命周期内只设置一次。

- `/Volumes` 覆盖之后挂载的任何外接卷；沙箱已有 `/Volumes/` 读写例外。
- 仍不包含 `/`（启动卷 `Macintosh HD` 在 Finder 中解析为 `/`，不在 `/Volumes` 下）。
- 需真机验证：`/Volumes/E` 下右键菜单与角标正常；运行中插入新卷后菜单可用。

### 5.4 主 App 侧：`BadgeOwnershipManager`

IPC 路由新增 `reclaimBadgeOwnership`，归入只读 action（不写用户文件，只校验路径存在）。
处理分两段：

**同步受理（在 IPC 队列上，毫秒级）**——依次检查，任一不满足即返回 `success=false` + 原因：

1. 设置开关开启（`SharedConfig.badgeOwnershipReclaim`）；
2. 目录内存在可见项（`contentsOfDirectory` 过滤以 `.` 开头的项；读失败视为无法判定，拒绝）
   ——防止空目录 / 纯隐藏目录误判为丢失；
3. 限流（`BadgeReclaimRateLimiter`，Kit 纯逻辑）：同一 `extPid` 只受理一次；
   两次执行间隔 ≥ 20 秒；滚动 1 小时内最多 5 次（防打开 / 存储面板实例反复触发）。

通过后返回 `success=true`，把执行派发到独立串行队列 `com.finderright.app.badge-reclaim`
（**不得**在 IPC 队列上 sleep，避免重演粘贴阻塞 IPC 的问题）。

**异步执行**：

1. `pluginkit -m -p com.apple.FinderSync` → `FinderSyncElectionParser`（Kit）解析出状态为 `+`
   的 bundle id（去重），排除 `com.finderright.app.sync`。列表为空则结束。
2. 写恢复标记 `badge-reclaim-restore.json`（`BadgeReclaimRestoreStore`，Kit，原子写，
   内容为待恢复 id 列表与时间戳）。**先落盘再动手。**
3. 逐个 `pluginkit -e ignore -i <id>`。
4. 等待 2 秒（与真机验证一致）。
5. 逐个 `pluginkit -e use -i <id>`。
6. 再次 `pluginkit -m -p com.apple.FinderSync` 核验这些 id 均为 `+`；未恢复的重试一次 `use`，
   仍失败则记错误日志并**保留**恢复标记（下次启动继续恢复）；全部恢复则删除标记。
7. 日志记录：受理原因、被重启的 id 列表、各步耗时、核验结果。

**崩溃恢复**：主 App 启动时（`IPCWatcher` 启动处，与 `recoverInflightCutQueue` 并列）若存在
恢复标记，对其中每个 id 执行 `-e use` 并核验，成功后删除标记。确保任何时刻崩溃都不会让
用户的其他扩展停留在禁用状态。

### 5.5 设置

- `SharedConfig` 新增键 `badgeOwnershipReclaim`（Bool，默认 `true`）。扩展与主 App 都读：
  扩展用于跳过无谓 IPC，主 App 作为最终裁决。
- 设置 →「功能」页新增 Section「剪切角标」，内含开关「自动解决角标冲突」，说明文字：
  > 其他访达扩展（如 Keka、Pearcleaner）可能占用角标显示权，导致剪切角标不显示。
  > 开启后，FinderRight 会在需要时短暂重启这些扩展以取回显示权（每次访达启动至多一次）。
  > 注意：这可能使网盘等扩展的同步状态图标在 FinderRight 监控的目录中不再显示。
- 补齐 `en.lproj` 文案。

### 5.6 日志（排查用）

扩展：`badgeProbe dir=… owned|lost`、`badgeReclaim request reason=probe|cut dir=…`、
`badgeReclaim accepted|rejected msg=…`、`badgeReclaim verified|still lost dir=…`。
主 App：`serviceLog` 记录受理 / 拒绝原因、重启列表、恢复核验结果、崩溃恢复结果。

## 6. 错误处理汇总

| 场景 | 行为 |
|---|---|
| 主 App 未运行（探测时） | 不发请求，留给剪切兜底 |
| 设置关闭 | 扩展不发；主 App 也拒绝 |
| 目录为空 / 全是隐藏项 / 无法读取 | 主 App 拒绝，扩展不重试 |
| 限流命中 | 主 App 拒绝 |
| 没有其他启用扩展 | 正常结束（丢失原因只可能是 File Provider 等） |
| `pluginkit` 执行失败 | 记日志；恢复阶段保证 `use` 尽力执行，失败保留标记 |
| 主 App 在 ignore 与 use 之间崩溃 | 下次启动按恢复标记恢复 |
| 抢回后仍未拿到归属 | 记 `still lost`，本进程不再尝试 |
| 被限流 / 无法判定拒绝 | 只消耗一次尝试（每进程上限 2），剪切时仍可兜底 |
| 用户隐藏了桌面图标导致探测误判 | 至多一次多余的重启，受限流约束，可接受 |

## 7. 测试

**单元测试（FinderRightKit 测试 runner）**

- `FinderSyncElectionParser`：解析真实 `pluginkit -m` 输出样本（含 `+`/`-`/空格状态、同 id
  多版本、版本号括号、空输出）；排除指定 id。
- `BadgeReclaimRestoreStore`：写入 / 读取 / 清除、损坏文件视为空、幂等清除。
- `BadgeReclaimRateLimiter`：同 extPid 拒绝、最小间隔、滚动小时上限（注入时钟）。
- `BadgeOwnershipProbe`：记录与查询、父目录规范化（NFC、`standardizingPath`）、
  被受理后 `canRequestReclaim` 恒为 false、被拒绝只消耗一次尝试、尝试满 2 次后为 false。

**真机验证（确定性，不依赖随机输赢）**

1. 强制丢失：`pluginkit -e ignore -i com.finderright.app.sync && sleep 2 && pluginkit -e use -i com.finderright.app.sync`
   → 新扩展进程最后注册，必然丢失重叠目录。
2. 期望日志链：`badgeProbe lost` → 主 App 重启其他扩展 → `requestBadgeIdentifier` 突发 →
   `badgeReclaim verified`；且之后 `pluginkit -m` 显示所有原 `+` 扩展仍为 `+`。
3. 关闭设置后重复 1：不应发生任何重启。
4. 崩溃恢复：执行中途杀主 App（或手工放置恢复标记后启动）→ 扩展被恢复为启用。
5. `/Volumes/E` 菜单与角标正常；运行中插入新卷后菜单可用。
6. 剪切兜底：主 App 未运行时触发丢失 → 剪切时抢回，角标约 2~3 秒后出现。

## 8. 涉及文件

| 文件 | 变更 |
|---|---|
| `FinderRightKit/Sources/FinderRightKit/BadgeOwnership/BadgeOwnershipProbe.swift` | 新增 |
| `FinderRightKit/Sources/FinderRightKit/BadgeOwnership/FinderSyncElection.swift` | 新增：解析器、恢复标记存储、限流器 |
| `FinderRightKit/Sources/FinderRightKit/Services/SharedConfig.swift` | 新增设置键 |
| `FinderRightKit/Tests/FinderRightKitTests/FinderRightKitTests.swift` | 新增用例 |
| `FinderRight/Services/BadgeOwnershipManager.swift` | 新增：受理、执行、崩溃恢复 |
| `FinderRight/Services/FinderRightService.swift` | 路由 `reclaimBadgeOwnership` |
| `FinderRight/Services/XPCListenerHost.swift` | 启动时调用崩溃恢复 |
| `FinderRight/Views/SettingsView.swift` + `en.lproj` | 设置开关与文案 |
| `FinderRightSync/FinderSync.swift` | 接入探测、剪切兜底、静态注册 `/Volumes`、删除卷监听 |
