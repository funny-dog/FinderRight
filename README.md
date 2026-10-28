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
- ✂️ **剪切 / 粘贴** —— 补上 Finder 缺失的剪切，⌘X / ⌘V 直接用，粘贴时才真正移动；设置「功能 → 剪切 / 粘贴」可查看待剪切项目并逐项移除
- 💻 **打开终端 / 编辑器** —— 可自定义终端 / 编辑器
- 📋 **复制路径 / 文件名 / 文件内容** —— 支持设置各种格式的路径 / 文件名可选择是否带后缀
- 📂 **打开路径** —— 粘贴一个路径，直接在 Finder 中定位或打开
- 📁 **移动到 / 复制到** —— 一键把选中项送到常用目录，可按最近使用排序
- 🔗 **复制哈希 / 创建符号链接**（默认关闭）—— 复制 SHA-256 / SHA-1 / MD5（多选与 shasum 格式一致）；在原位置创建终端可识别的符号链接
- 🖼️ **图片快速转换 / 缩放** —— 转换为 PNG / JPEG / HEIC，或按长边等比缩放至 2560px / 1920px / 1280px / 800px；仅在选中项全为图片时显示，支持批量与撤销。WebP 仅支持作为源格式转换为其他格式，不支持直接缩放输出；超过 4,000 万像素的图片需先缩放再转换；原图不会被修改，多帧图片会跳过并说明原因。
- 📦 **压缩 / 解压** —— 默认关闭：ZIP 使用 UTF-8 文件名，Windows 上中文名不乱码，通常不含 `__MACOSX`、`.DS_Store` 和 AppleDouble `._*` 元数据（应用包或特殊路径等情况退回系统方式），支持输入密码解压加密 ZIP。需要保留 Mac 元数据时请用访达自带「压缩」。
- 👀 **扩展空格预览** —— 系统自带的快速查看（空格快捷键）增强，支持大多数格式，包括文件夹和压缩包等等，markdown支持渲染
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
- **自动更新**：默认关闭；开启后每 6 小时检查一次，在文件操作空闲时安装并自动重启。更新同时请求官网与 GitHub，优先采用可安装的新版本；“已是最新”或缺少校验信息的响应会等待另一渠道，检查失败可立即重试。下载卡住会切换备用源，全程校验 SHA-256 与签名证书，校验失败不安装。
- **混用 Homebrew 与应用内更新**：应用内更新不会同步 Homebrew 的版本记录，可能导致重复安装；Cask 声明了 `auto_updates true`，普通 `brew upgrade` 会跳过它。

</details>

### 🩺 常见问题

| 症状 | 处理 |
| --- | --- |
| 右键完全没有 FinderRight 菜单 | 在「设置 → 权限与扩展 → 右键菜单排查」中一键启用访达扩展并重启访达。 |
| 升级后菜单或角标还是旧的 | 重启访达：`killall Finder`。 |
| 云盘、`/Applications` 等目录没有菜单 | 系统限制，改用 **右键 → 服务** 子菜单（见下方说明）。 |
| 菜单里没有压缩 / 解压、复制哈希、创建符号链接 | 默认关闭，在「设置 → 功能」中开启。 |
| 快捷键按了没反应 | 授予「辅助功能」权限；多数快捷键需要先选中文件。 |
| 剪切后没有剪刀角标 | 可能被其他扩展（如 Keka）占用，不影响粘贴；可在「设置 → 功能」开启「自动解决角标冲突」。 |
| 操作后看不到结果 | 在「设置 → 操作历史」查看结果或失败原因。 |
| 打开终端没有切到当前目录 | Ghostty / Alacritty / Kitty 已在运行时无法指定目录，属于终端自身限制。 |
| 升级后权限开关是开的却不生效 | 从 1.2.0 及更早版本升级需重新授权一次（见「升级」）。 |
| 选中文件夹或 ZIP 按空格仍是系统预览 | 在「设置 → 功能 → 快速查看」打开「预览增强」，再重新打开快速查看。 |
| 按空格看 `.md` 不是 FinderRight 的排版 | 在同一处打开「Markdown 渲染」；若提示检测到其他应用的 Markdown 预览，关闭其中一个。 |

<details>
<summary>云盘与「服务」菜单</summary>

iCloud Drive、Google Drive、OneDrive、Dropbox 等云盘是 macOS 的 File Provider 域，目录归云盘自己的扩展管理，第三方 Finder 扩展的右键菜单不会出现，完全磁盘访问也改变不了（见 [Keka #1327 中转述的 Apple DTS 答复](https://github.com/aonez/Keka/issues/1327)）。`/Applications`、`/Users/Shared` 等未注册目录同理。

在这些位置，FinderRight 的操作改由 **右键 → 服务** 提供：复制路径 / 复制文件名 / 复制文件内容 / 复制 SHA-256 / 创建符号链接 / 转换为 PNG / 转换为 JPEG / 转换为 HEIC / 打开路径 / 新建文件 / 移动到 / 复制到 / 打开终端 / 打开编辑器 / 剪切 / 粘贴到此文件夹 / 压缩 / 解压。

- 粘贴：剪切后在目标目录空白处选「服务 → FinderRight：粘贴到此文件夹」；若空白处没有「服务」，可回到上一级右键目标文件夹。它移动的是 FinderRight 的剪切队列，而不是系统剪贴板。
- 新建文件、移动到 / 复制到会先弹确认框；取消不会操作文件。
- 「服务」菜单标题跟随系统语言，不随 FinderRight 的界面语言切换。

</details>

<details>
<summary>快速查看的范围与限制</summary>

- 文件夹与 ZIP / TAR / TAR.GZ / TAR.BZ2 / TAR.XZ / 7z / RAR 使用只读目录列表，可展开子目录、点击列标题排序；不预览包内文件内容，不向磁盘解压。
- apk / ipa / jar / war / whl 按 ZIP 列出内容；rpm 列出负载中的文件（zstd 压缩的负载不支持）；iso 列出光盘目录；deb 与 pkg 只列出顶层成员（如 `data.tar.xz`、`Payload`），不再展开内层包。
- YAML / YML / TOML / INI 与按内容识别的文本、配置和源码支持 UTF-8 与带 BOM 的 UTF-16；超过 1 MiB 时只读取开头，在最后一个完整换行处截断并提示（没有换行时保留完整字符的前缀），仍支持语法高亮。
- `.gitignore`、`.env` 等点文件，`Dockerfile` 等无扩展名文件，`.conf` / `.config` / `.cfg` 等配置文件，系统不认识的源码（`.go` / `.rs` / `.tsx` / `.vue` / `.scss` / `.sql` / `.proto` / `.tf` 等）、`.jsonl` / `.lock` 等结构化文本，以及 `.srt` / `.vtt` / `.tex` / `.org` 等字幕与标记文档，都按内容识别：是文本则显示内容；Swift、Go、Rust、JS/TS、Python、Shell、JSON、YAML、TOML 支持轻量语法高亮，未知语言保持纯文本，不是文本（如 `.DS_Store`、可执行程序）则保留系统默认预览。TypeScript 的 `.ts` 被系统固定识别为视频，无法接管。
- Markdown（`.md`）渲染标题、列表、任务列表、表格、引用与代码块，已标明上述语言的围栏代码块也支持着色；着色跟随浅深色外观，单段超过 1 MiB 时降级为纯文本；最多 1 MiB；表格保留列对齐，保留脚注引用标记与定义正文（不提供脚注跳转）；开头的 YAML 元信息以原文显示；图片只显示替代文字，HTML 按原文显示，链接悬停可查看目标、右键可复制地址，但不可点击跳转，不加载任何外部资源。它是独立的预览扩展，可在设置里单独关闭；若 MarkEdit 等应用也提供 Markdown 预览，设置页会提示只保留一个。
- 文档预览在后台生成显示内容，减少 Notebook 与 SQLite 等复杂内容准备时的主线程阻塞。
- Jupyter Notebook（v4）最多读取 5 MiB、展示 200 个单元；渲染 Markdown、显示代码与已保存的文字输出，不执行代码、不加载外部资源，不显示图片与 HTML 输出。
- SQLite（`.sqlite` / `.sqlite3`）只读展示最多 20 张普通表的列名、类型和每表前 50 条记录，单元格最多展示 512 字节；跳过视图、虚拟表和生成列。使用主文件快照，不包含尚未合并到主文件的 WAL 数据。
- 包含隐藏项；不展开符号链接或 `.app` 等文件包，不递归统计目录大小。
- 每层文件夹最多 2,000 项，压缩包最多 10,000 条记录，超出会提示内容不完整；其他压缩格式还受扫描资源上限约束。
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
- ✂️ **Cut / Paste** — the cut that Finder lacks; use ⌘X / ⌘V, files only move when you paste; view and remove individual queued items in Settings → Features → Cut / Paste
- 💻 **Open in Terminal / Editor** — customize your terminal and editor
- 📋 **Copy Path / File Name / File Content** — choose from various path formats and whether file names include extensions
- 📂 **Go to Folder** — paste a path to reveal or open it in Finder
- 📁 **Move To / Copy To** — send the selection to a favorite folder in one click, optionally sorted by recent use
- 🔗 **Copy Hash / Make Symbolic Link** (off by default) — copy SHA-256 / SHA-1 / MD5 (multiple files use the shasum format); create symbolic links that Terminal understands, next to the originals
- 🖼️ **Image Convert / Scale** — convert to PNG / JPEG / HEIC, or scale proportionally by long edge to 2560px / 1920px / 1280px / 800px; shown only when all selected items are images, with batch support and undo. WebP is supported as a read/conversion source only and cannot be directly scaled to WebP; images over 40 million pixels must be scaled down before converting. Originals remain unchanged; multi-frame images are skipped with a reason.
- 📦 **Compress / Extract** — Off by default: ZIPs use UTF-8 filenames for Chinese names on Windows, usually omit `__MACOSX`, `.DS_Store` and AppleDouble `._*` metadata (app bundles and special paths fall back to the system method), and encrypted ZIPs prompt for a password. Use Finder’s Compress when you need to retain Mac metadata.
- 👀 **Extended Quick Look previews** — enhance the built-in Quick Look (Space bar) with support for most formats, including folders and archives, plus rendered Markdown
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
- **Auto-update**: off by default; when on, it checks every 6 hours and installs while file operations are idle, then restarts. It queries the website and GitHub and accepts an installable new version immediately. An up-to-date result or one missing verification information waits for the other source; failed checks can be retried immediately. Downloads switch to the alternate source if they stall, and SHA-256 and the signing certificate are always verified before installation.
- **Mixing Homebrew and in-app updates**: in-app updates don't update Homebrew's version record, which may cause reinstalls; the cask declares `auto_updates true`, so a plain `brew upgrade` skips it.

</details>

### 🩺 Troubleshooting

| Symptom | Fix |
| --- | --- |
| No FinderRight items in the right-click menu | Use Settings → Permissions & Extensions → Troubleshooting to enable the Finder extension and relaunch Finder. |
| Menu or badges look old after upgrading | Relaunch Finder: `killall Finder`. |
| No menu in cloud folders, `/Applications`, etc. | A system limitation; use **right-click → Services** instead (see below). |
| No Compress / Extract, Copy Hash or Make Symbolic Link in the menu | Off by default; turn them on in Settings → Features. |
| Shortcuts do nothing | Grant Accessibility; most shortcuts need a selected item. |
| No scissors badge after cutting | Another extension (such as Keka) may hold the badge; paste still works. Turn on "Resolve Badge Conflicts Automatically" in Settings → Features. |
| No visible result after an action | Check Settings → Operation History for the result or failure reason. |
| Open in Terminal doesn't switch folders | Ghostty / Alacritty / Kitty can't take a working directory while already running. |
| Permissions look on but don't work after upgrading | Upgrading from 1.2.0 or earlier requires re-granting once (see "Upgrading"). |
| Space on a folder or ZIP still shows the system preview | Turn on "Enhanced previews" in Settings → Features → Quick Look, then reopen Quick Look. |
| Space on a `.md` file doesn't show FinderRight's formatting | Turn on "Markdown rendering" in the same place; if it reports another app’s Markdown preview, turn one of them off. |

<details>
<summary>Cloud folders and the Services menu</summary>

iCloud Drive, Google Drive, OneDrive, Dropbox and similar services are File Provider domains on macOS, owned by the provider's own extension, so third-party Finder extension menus don't appear there, and Full Disk Access doesn't change that (see [the Apple DTS reply quoted in Keka #1327](https://github.com/aonez/Keka/issues/1327)). Unregistered folders such as `/Applications` and `/Users/Shared` behave the same way.

In these places FinderRight's actions are available under **right-click → Services**: Copy Path / Copy File Name / Copy File Content / Copy SHA-256 / Create Symbolic Link / Convert to PNG / Convert to JPEG / Convert to HEIC / Go to Folder / New File / Move To / Copy To / Open in Terminal / Open in Editor / Cut / Paste into This Folder / Compress / Extract.

- Paste: after cutting, right-click empty space in the destination and choose "Services → FinderRight: Paste into This Folder"; if Services is missing there, right-click the destination folder from its parent. It moves FinderRight's cut queue, not the system clipboard.
- New File and Move To / Copy To show a confirmation dialog first; cancelling does nothing.
- Service titles follow the system language, not FinderRight's language setting.

</details>

<details>
<summary>Quick Look scope and limits</summary>

- Folders and ZIP / TAR / TAR.GZ / TAR.BZ2 / TAR.XZ / 7z / RAR archives use read-only, expandable and sortable listings; no archived file-content preview or extraction to disk.
- apk / ipa / jar / war / whl are listed as ZIP; rpm lists its payload files (zstd-compressed payloads aren't supported); iso lists the disc directory; deb and pkg list only top-level members (such as `data.tar.xz` or `Payload`) without opening nested archives.
- YAML / YML / TOML / INI and content-detected text, configuration and source files use UTF-8 or BOM-marked UTF-16. Files over 1 MiB show only the bounded prefix through its last complete newline, with a notice and syntax highlighting; without a newline, the prefix ends at a complete character.
- Dotfiles such as `.gitignore` and `.env`, extensionless files such as `Dockerfile`, config files such as `.conf` / `.config` / `.cfg`, source code macOS doesn't recognize (`.go` / `.rs` / `.tsx` / `.vue` / `.scss` / `.sql` / `.proto` / `.tf` and more), structured text such as `.jsonl` / `.lock`, and subtitles or markup such as `.srt` / `.vtt` / `.tex` / `.org` are detected by content: text is displayed with lightweight syntax highlighting for Swift, Go, Rust, JS/TS, Python, Shell, JSON, YAML and TOML; unknown languages stay plain text, while non-text files (such as `.DS_Store` or executables) keep the system's default preview. TypeScript `.ts` files can't be taken over because macOS always treats them as video.
- Markdown (`.md`) renders headings, lists, task lists, tables, quotes and code blocks, up to 1 MiB; table column alignment is preserved, and footnote markers and definition text are preserved without jump navigation; leading YAML front matter is shown as-is; images show only their alt text, HTML is shown as plain text, hover over links to see their targets or right-click to copy their addresses; links don't open, and no external resources are loaded. It's a separate preview extension you can turn off in Settings; if another app such as MarkEdit also previews Markdown, Settings suggests keeping only one. Fenced code blocks tagged with the supported languages are also highlighted. Colors follow light/dark appearance; individual blocks over 1 MiB remain plain text.
- Document preview content is generated in the background to reduce main-thread blocking while preparing complex Notebook and SQLite previews.
- Jupyter Notebook v4 reads up to 5 MiB and displays up to 200 cells, with rendered Markdown, code and saved text outputs. Code is never executed, external resources are never loaded, and image/HTML outputs are omitted.
- SQLite (`.sqlite` / `.sqlite3`) displays names and types of columns and up to 50 rows from each of 20 ordinary tables, with a 512-byte cell display limit. Views, virtual tables and generated columns are skipped. Read-only previews use the main database file snapshot and omit uncheckpointed WAL changes.
- Includes hidden items; doesn't follow symbolic links, browse app packages, or compute folder sizes.
- Up to 2,000 items per folder and 10,000 archive records, with a notice when truncated; other archive formats also have scan resource limits.
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
