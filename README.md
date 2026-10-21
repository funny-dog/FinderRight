<div align="center">

# FinderRight

**给 Finder 加上右键新建文件、打开终端和剪切粘贴。**

**Create files, open a terminal, and cut & paste from Finder’s right-click menu.**

免费开源 · 文件操作在本地完成 / Free & open source · File operations stay on your Mac

[English](#english) · [中文](#中文) · [参与贡献 / Contributing](CONTRIBUTING.md) · [安全说明 / Security](SECURITY.md)

![platform](https://img.shields.io/badge/platform-macOS%2013%2B%20(Apple%20Silicon)-blue)
![license](https://img.shields.io/badge/license-MIT-green)

<br/>

<img src="docs/images/demo.gif" alt="FinderRight demo: new file, cut & paste, open terminal from the Finder right-click menu" width="800" />

觉得好用欢迎 [⭐ Star](https://github.com/funny-dog/FinderRight) 和反馈 / If it helps, a [⭐ Star](https://github.com/funny-dog/FinderRight) or feedback is appreciated.

</div>

---

## 中文

### ✨ 功能

- 📄 **新建文件** —— txt / Markdown / Python / JSON 等常用文本，空白 Word / Excel / PowerPoint，以及自定义模板
- ✂️ **剪切 / 粘贴** —— 补上 Finder 缺失的剪切，⌘X / ⌘V 直接用，粘贴时才真正移动
- 💻 **打开终端 / 编辑器** —— 在当前目录打开 Ghostty / iTerm2 / Warp 或 VS Code / Cursor / Zed 等
- 📋 **复制路径 / 文件名 / 文件内容** —— 路径支持 `~`、终端转义、文件 URL 等格式；文本文件可直接复制全文
- 📂 **打开路径** —— 粘贴一个路径，直接在 Finder 中定位或打开
- 📁 **移动到 / 复制到** —— 一键把选中项送到常用目录
- 📦 **压缩 / 解压** —— 压缩为 ZIP，解压 ZIP / 7z / RAR（默认关闭，可在设置中开启）
- 👀 **空格预览文件夹 / ZIP** —— 选中后按空格，查看可展开、可排序的内容列表，ZIP 无需解压
- 👁 **切换隐藏文件** —— 即时生效，不重启 Finder
- ↩️ **撤销** —— ⌘Z 撤销上一次移动、剪切、新建、压缩等操作
- 🕘 **操作历史** —— 按日期查看每次操作的结果与失败原因，可搜索、筛选、在访达中定位
- ☁️ **云盘里也能用** —— iCloud / Google Drive 等目录通过右键「服务」菜单使用
- ⌨️ **自定义快捷键与菜单顺序**，🌗 **中英双语**，🔄 **应用内自动更新**

### 📸 截图

<p align="center">
  <img src="docs/images/menu-new-file.png" alt="FinderRight 右键菜单" height="360" />
  &emsp;
  <img src="docs/images/settings-shortcuts.png" alt="FinderRight 快捷键设置" height="360" />
</p>

### 📥 安装

要求 **macOS 13+、Apple Silicon**（暂不支持 Intel）。

#### 方式一：Homebrew（推荐）

```bash
brew install --cask funny-dog/tap/finderright
```

> Homebrew 安装会删除隔离属性、跳过 Gatekeeper 首次检查；若希望保留系统检查，请用 DMG 安装。Tap 由本项目维护，并非 Homebrew 官方仓库。

#### 方式二：DMG 手动安装

下载 [FinderRight.dmg](https://finderright.erhuerhu.dpdns.org/download/FinderRight.dmg)（中国大陆自动转到 [Gitee](https://gitee.com/no_ink_no_book/FinderRight/releases)），拖入 `Applications`。当前版本为自签名、未经 Apple 公证，首次打开被拦截时，到 **系统设置 → 隐私与安全性 → 仍要打开**，或执行：

```bash
xattr -dr com.apple.quarantine /Applications/FinderRight.app
```

#### 备用访问

如果主站访问不畅，可以试试[独立展示站](https://finderright-bhnr38evqjb.qoder.zone/)。它只托管展示页面，不含安装包；下载仍请使用上方 DMG 链接或 [Gitee 发行版](https://gitee.com/no_ink_no_book/FinderRight/releases)。

#### 首次启动

按引导完成：启用访达扩展、授予完全磁盘访问、授予辅助功能。

### 🔄 升级

在「设置 → 关于」检查更新，或在「设置 → 通用」开启自动更新；Homebrew 用户也可以 `brew upgrade --cask --greedy funny-dog/tap/finderright`。**升级后请重启访达**，否则右键菜单可能还是旧版：

```bash
killall Finder
```

<details>
<summary>从 1.2.0 及更早版本升级、自动更新细节</summary>

- **从 1.2.0 及更早版本首次升级**：旧版是 ad-hoc 签名，系统会视为不同的程序，即使开关显示已开启也需重新授权一次。最省事的做法：
  ```bash
  tccutil reset SystemPolicyAllFiles com.finderright.app
  tccutil reset Accessibility com.finderright.app
  ```
  然后重新打开 FinderRight 按引导授权。1.3.0 起使用固定证书，后续升级会保留授权。
- **自动更新**：默认关闭；开启后每 6 小时检查一次，在文件操作空闲时安装并自动重启。更新同时请求官网与 GitHub，下载卡住会切换备用源，全程校验 SHA-256 与签名证书，校验失败不安装。
- **混用 Homebrew 与应用内更新**：应用内更新不会同步 Homebrew 的版本记录，可能导致重复安装；Cask 声明了 `auto_updates true`，普通 `brew upgrade` 会跳过它。

</details>

### 🩺 常见问题

| 症状 | 处理 |
| --- | --- |
| 右键完全没有 FinderRight 菜单 | 在「设置 → 权限与扩展 → 右键菜单排查」中一键启用访达扩展并重启访达。 |
| 升级后菜单或角标还是旧的 | 重启访达：`killall Finder`。 |
| 云盘、`/Applications` 等目录没有菜单 | 系统限制，改用 **右键 → 服务** 子菜单（见下方说明）。 |
| 菜单里没有压缩 / 解压 | 默认关闭，在「设置 → 功能」中开启。 |
| 快捷键按了没反应 | 授予「辅助功能」权限；多数快捷键需要先选中文件。 |
| 剪切后没有剪刀角标 | 可能被其他扩展（如 Keka）占用，不影响粘贴；可在「设置 → 功能」开启「自动解决角标冲突」。 |
| 操作后看不到结果 | 在「设置 → 操作历史」查看结果或失败原因。 |
| 打开终端没有切到当前目录 | Ghostty / Alacritty / Kitty 已在运行时无法指定目录，属于终端自身限制。 |
| 升级后权限开关是开的却不生效 | 从 1.2.0 及更早版本升级需重新授权一次（见「升级」）。 |
| 选中文件夹或 ZIP 按空格仍是系统预览 | 在「设置 → 权限与扩展 → 扩展」打开「文件夹与 ZIP 预览」，再重新打开快速查看。 |

<details>
<summary>云盘与「服务」菜单</summary>

iCloud Drive、Google Drive、OneDrive、Dropbox 等云盘是 macOS 的 File Provider 域，目录归云盘自己的扩展管理，第三方 Finder 扩展的右键菜单不会出现，完全磁盘访问也改变不了（见 [Keka #1327 中转述的 Apple DTS 答复](https://github.com/aonez/Keka/issues/1327)）。`/Applications`、`/Users/Shared` 等未注册目录同理。

在这些位置，FinderRight 的操作改由 **右键 → 服务** 提供：复制路径 / 复制文件名 / 复制文件内容 / 打开路径 / 新建文件 / 移动到 / 复制到 / 打开终端 / 打开编辑器 / 剪切 / 粘贴到此文件夹 / 压缩 / 解压。

- 粘贴：剪切后在目标目录空白处选「服务 → FinderRight：粘贴到此文件夹」；若空白处没有「服务」，可回到上一级右键目标文件夹。它移动的是 FinderRight 的剪切队列，而不是系统剪贴板。
- 新建文件、移动到 / 复制到会先弹确认框；取消不会操作文件。
- 「服务」菜单标题跟随系统语言，不随 FinderRight 的界面语言切换。

</details>

<details>
<summary>快速查看的范围与限制</summary>

- 只读列表，可展开子目录、点击列标题排序；不预览包内文件内容，不解压。
- 包含隐藏项；不展开符号链接或 `.app` 等文件包，不递归统计目录大小。
- 每层文件夹最多 2,000 项，ZIP 最多 10,000 条记录，超出会提示内容不完整。
- 不支持 ZIP64、分卷 ZIP；加密 ZIP 可显示条目但不解密。
- 预览扩展有独立的沙箱权限，主 App 的完全磁盘访问不会自动授予它。

</details>

<details>
<summary>其他已知行为</summary>

- **加密 / 分卷压缩包**：加密 ZIP 会弹密码框；加密的 7z / RAR 和分卷包无法解压，会提示失败并自动清理临时文件。
- **撤销**：只支持单级撤销，与访达自己的撤销按先后顺序共存；文件被改过或原位置有同名项时跳过，删除一律进废纸篓。
- **操作历史**：仅保存在本机，默认保留最近 100 条（可选 0 / 50 / 500）；清空历史不影响文件和撤销。
- **剪切状态**：粘贴过程中主 App 崩溃，未移动的项目会在下次启动时恢复回剪切队列。
- **语言**：右键菜单即时切换，剪切角标文案需重启访达后生效。

</details>

<details>
<summary>完全卸载</summary>

```bash
killall FinderRight 2>/dev/null || true
rm -rf /Applications/FinderRight.app
rm -rf ~/Library/Application\ Support/FinderRight
rm -f ~/Library/Preferences/com.finderright.app.plist
tccutil reset All com.finderright.app 2>/dev/null || true
killall Finder
```

</details>

### 🛠 从源码构建

只需 Command Line Tools，无需 Xcode：

```bash
bash scripts/setup-signing.sh  # 仅首次：生成自签名证书（请备份私钥）
bash scripts/ci.sh             # 编译 + 单元测试 + 类型检查
bash scripts/build.sh          # 产出 .app 与 DMG / ZIP
```

也可以用 [xcodegen](https://github.com/yonaskolb/XcodeGen) 生成 Xcode 工程（`xcodegen generate`）。项目由主 App（未沙箱，执行文件操作）、Finder 扩展（沙箱，提供右键菜单）和 Quick Look 扩展组成，扩展通过「文件 + URL scheme」唤醒主 App，无需 App Group 或付费开发者账号。官网源码见 [`website/`](website/)。

### 📄 许可证

[MIT](LICENSE)

---

## English

### ✨ Features

- 📄 **New File** — common text files (txt / Markdown / Python / JSON…), blank Word / Excel / PowerPoint, and your own templates
- ✂️ **Cut / Paste** — the cut that Finder lacks; use ⌘X / ⌘V, files only move when you paste
- 💻 **Open in Terminal / Editor** — open the current folder in Ghostty / iTerm2 / Warp or VS Code / Cursor / Zed, etc.
- 📋 **Copy Path / File Name / File Content** — paths as `~`, shell-escaped or file URLs; copy a text file's full content directly
- 📂 **Go to Folder** — paste a path to reveal or open it in Finder
- 📁 **Move To / Copy To** — send the selection to a favorite folder in one click
- 📦 **Compress / Extract** — compress to ZIP, extract ZIP / 7z / RAR (off by default, enable in Settings)
- 👀 **Space to preview folders / ZIPs** — press Space for an expandable, sortable contents list, no extraction needed
- 👁 **Toggle Hidden Files** — instant, no Finder restart
- ↩️ **Undo** — ⌘Z undoes the last move, cut, new file, compress and more
- 🕘 **Operation History** — review each action's result or failure reason by date; search, filter and reveal in Finder
- ☁️ **Works in cloud folders** — use it in iCloud / Google Drive via the right-click Services menu
- ⌨️ **Custom shortcuts and menu order**, 🌗 **English & Chinese**, 🔄 **in-app auto-update**

### 📸 Screenshots

<p align="center">
  <img src="docs/images/menu-new-file.png" alt="FinderRight right-click menu" height="360" />
  &emsp;
  <img src="docs/images/settings-shortcuts.png" alt="FinderRight Settings — Keyboard Shortcuts" height="360" />
</p>

> The screenshots show the Chinese interface; FinderRight is also fully available in English.

### 📥 Installation

Requires **macOS 13+ on Apple Silicon** (Intel is not supported).

#### Method 1: Homebrew (recommended)

```bash
brew install --cask funny-dog/tap/finderright
```

> Homebrew removes the quarantine attribute and skips the Gatekeeper first-launch check; use the DMG if you want to keep it. The tap is maintained by this project, not Homebrew's official repository.

#### Method 2: DMG

Download [FinderRight.dmg](https://finderright.erhuerhu.dpdns.org/download/FinderRight.dmg) and drag it into `Applications`. The app is self-signed and not notarized by Apple; if the first launch is blocked, go to **System Settings → Privacy & Security → Open Anyway**, or run:

```bash
xattr -dr com.apple.quarantine /Applications/FinderRight.app
```

#### Alternate access

If the main site is slow or unreachable, try the [standalone mirror](https://finderright-bhnr38evqjb.qoder.zone/). It hosts the showcase page only, not installers; use the DMG link above or [Gitee releases](https://gitee.com/no_ink_no_book/FinderRight/releases) for downloads.

#### First launch

Follow the onboarding: enable the Finder extension, grant Full Disk Access, and grant Accessibility.

### 🔄 Upgrading

Check for updates in Settings → About, or turn on automatic updates in Settings → General; Homebrew users can also run `brew upgrade --cask --greedy funny-dog/tap/finderright`. **Restart Finder after upgrading**, or the context menu may stay on the old version:

```bash
killall Finder
```

<details>
<summary>Upgrading from 1.2.0 or earlier, auto-update details</summary>

- **First upgrade from 1.2.0 or earlier**: older builds were ad-hoc signed, so macOS treats the new one as a different app; re-grant permissions once even if the toggles look on. The easiest way:
  ```bash
  tccutil reset SystemPolicyAllFiles com.finderright.app
  tccutil reset Accessibility com.finderright.app
  ```
  Then reopen FinderRight and follow the onboarding. Since 1.3.0 a fixed certificate is used, so later upgrades keep permissions.
- **Auto-update**: off by default; when on, it checks every 6 hours and installs while file operations are idle, then restarts. It queries the website and GitHub, switches to the alternate source if a download stalls, and always verifies SHA-256 and the signing certificate before installing.
- **Mixing Homebrew and in-app updates**: in-app updates don't update Homebrew's version record, which may cause reinstalls; the cask declares `auto_updates true`, so a plain `brew upgrade` skips it.

</details>

### 🩺 Troubleshooting

| Symptom | Fix |
| --- | --- |
| No FinderRight items in the right-click menu | Use Settings → Permissions & Extensions → Troubleshooting to enable the Finder extension and relaunch Finder. |
| Menu or badges look old after upgrading | Relaunch Finder: `killall Finder`. |
| No menu in cloud folders, `/Applications`, etc. | A system limitation; use **right-click → Services** instead (see below). |
| No Compress / Extract in the menu | Off by default; turn it on in Settings → Features. |
| Shortcuts do nothing | Grant Accessibility; most shortcuts need a selected item. |
| No scissors badge after cutting | Another extension (such as Keka) may hold the badge; paste still works. Turn on "Resolve Badge Conflicts Automatically" in Settings → Features. |
| No visible result after an action | Check Settings → Operation History for the result or failure reason. |
| Open in Terminal doesn't switch folders | Ghostty / Alacritty / Kitty can't take a working directory while already running. |
| Permissions look on but don't work after upgrading | Upgrading from 1.2.0 or earlier requires re-granting once (see "Upgrading"). |
| Space on a folder or ZIP still shows the system preview | Turn on "Folder and ZIP previews" in Settings → Permissions & Extensions → Extensions, then reopen Quick Look. |

<details>
<summary>Cloud folders and the Services menu</summary>

iCloud Drive, Google Drive, OneDrive, Dropbox and similar services are File Provider domains on macOS, owned by the provider's own extension, so third-party Finder extension menus don't appear there, and Full Disk Access doesn't change that (see [the Apple DTS reply quoted in Keka #1327](https://github.com/aonez/Keka/issues/1327)). Unregistered folders such as `/Applications` and `/Users/Shared` behave the same way.

In these places FinderRight's actions are available under **right-click → Services**: Copy Path / Copy File Name / Copy File Content / Go to Folder / New File / Move To / Copy To / Open in Terminal / Open in Editor / Cut / Paste into This Folder / Compress / Extract.

- Paste: after cutting, right-click empty space in the destination and choose "Services → FinderRight: Paste into This Folder"; if Services is missing there, right-click the destination folder from its parent. It moves FinderRight's cut queue, not the system clipboard.
- New File and Move To / Copy To show a confirmation dialog first; cancelling does nothing.
- Service titles follow the system language, not FinderRight's language setting.

</details>

<details>
<summary>Quick Look scope and limits</summary>

- Read-only list with expandable folders and sortable columns; no file-content preview or extraction.
- Includes hidden items; doesn't follow symbolic links, browse app packages, or compute folder sizes.
- Up to 2,000 items per folder and 10,000 ZIP records, with a notice when truncated.
- ZIP64 and split ZIPs aren't supported; encrypted ZIPs list entries but aren't decrypted.
- The preview extension has its own sandbox permissions; the main app's Full Disk Access doesn't extend to it.

</details>

<details>
<summary>Other known behavior</summary>

- **Encrypted / multi-volume archives**: encrypted ZIPs prompt for a password; encrypted 7z / RAR and split archives fail with a message, and temporary files are cleaned up.
- **Undo**: single-level only, interleaved with Finder's own undo; items that changed or whose original location is taken are skipped, and deletions always go to the Trash.
- **Operation history**: stored only on this Mac, keeping the latest 100 entries by default (0 / 50 / 500 also available); clearing it doesn't affect files or undo.
- **Cut state**: if the main app crashes mid-paste, unmoved items return to the cut queue on next launch.
- **Language**: the context menu switches immediately; the cut badge label updates after Finder restarts.

</details>

<details>
<summary>Complete uninstall</summary>

```bash
killall FinderRight 2>/dev/null || true
rm -rf /Applications/FinderRight.app
rm -rf ~/Library/Application\ Support/FinderRight
rm -f ~/Library/Preferences/com.finderright.app.plist
tccutil reset All com.finderright.app 2>/dev/null || true
killall Finder
```

</details>

### 🛠 Build from Source

Command Line Tools only, no Xcode required:

```bash
bash scripts/setup-signing.sh  # first time only: create the self-signed certificate (back up the private key)
bash scripts/ci.sh             # build + unit tests + type checks
bash scripts/build.sh          # produces the .app plus DMG / ZIP
```

You can also generate an Xcode project with [xcodegen](https://github.com/yonaskolb/XcodeGen) (`xcodegen generate`). The project consists of the main app (non-sandboxed, performs file operations), a Finder extension (sandboxed, provides the menu) and a Quick Look extension; the extensions wake the main app via a file + URL scheme, with no App Group or paid developer account required. Website source lives in [`website/`](website/).

### 📄 License

[MIT](LICENSE)
