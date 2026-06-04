<div align="center">

# FinderRight

**增强 macOS Finder 右键菜单的轻量工具 · A lightweight tool that supercharges the macOS Finder right-click menu**

[English](#english) · [中文](#中文)

![platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![license](https://img.shields.io/badge/license-MIT-green)

</div>

---

## 中文

FinderRight 是一个纯本地、无后台服务、开源免费的 macOS 工具，为 Finder 右键菜单添加开发者常用的快捷操作。

### ✨ 功能

- 📄 **新建文件** —— 一键新建 txt / Markdown / Python / Shell / JSON / Swift / JS 等十种文件
- 📋 **复制路径** —— 复制选中文件/文件夹的完整路径
- 💻 **打开终端** —— 在当前目录打开终端（支持 Terminal / iTerm2 / Warp）
- ✏️ **打开编辑器** —— 用 VS Code / Cursor / Sublime / Xcode 等打开
- ✂️ **剪切 / 粘贴** —— Finder 原生没有的"剪切文件"
- 📦 **压缩 / 解压** —— 压缩为 ZIP；选中压缩包可解压到当前目录
- 👁 **切换隐藏文件** —— 即时显示/隐藏隐藏文件，**不重启 Finder、窗口不闪烁**（需辅助功能权限）
- ⌨️ **自定义快捷键** —— 给每个菜单项绑定快捷键
- 🌗 **中英文双语** —— 跟随系统语言自动切换

### 📥 安装

1. 下载 **[FinderRight.dmg](https://github.com/funny-dog/FinderRight/releases/latest/download/FinderRight.dmg)** —— 此链接始终指向最新 Release
2. 打开 DMG，把 `FinderRight.app` 拖到 `Applications`
3. **首次打开**（应用未经 Apple 公证，需手动放行）：
   ```bash
   xattr -dr com.apple.quarantine /Applications/FinderRight.app
   ```
   然后双击打开；或右键 → 打开 → 在弹窗中选择"打开"。
4. 启动后按引导：
   - **启用 Finder 扩展**：系统设置 → 隐私与安全性 → 扩展 → 访达扩展 → 勾选 FinderRight
   - **授予完全磁盘访问**（在受保护目录使用所有功能）
   - **授予辅助功能**（让"切换隐藏文件"不闪烁）

> ⚠️ 当前为 adhoc 签名版本。若未来提供 Developer ID 公证版，可省去第 3 步。

### 🛠 从源码构建

需要 Xcode 16+ 和 [xcodegen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme FinderRight -configuration Release \
  -derivedDataPath build/release build
```

### 🏗 架构

- **主 App**（未沙箱）：菜单栏 + 设置界面，借用 TCC 权限执行实际文件操作
- **Finder 扩展**（沙箱）：负责右键菜单
- **IPC**：扩展通过"文件 + URL scheme"唤醒主 App 执行操作，无需 App Group / 付费开发者账号

### ☁️ iCloud / Google Drive 等云盘

iCloud Drive、Google Drive、OneDrive、Dropbox 等云盘在 macOS 上是 **File Provider 域**，系统只允许其自身扩展提供右键菜单，第三方 Finder 扩展无法在其中显示菜单（**与完全磁盘访问无关**）。因此在这些云盘文件夹里，FinderRight 的操作改为出现在 **右键 →「服务」子菜单**（选中文件后可用：复制路径 / 打开终端 / 打开编辑器 / 剪切 / 压缩 / 解压）。「新建文件」和空白处「粘贴」因没有选中项，无法走此路径。

### 📄 许可证

[MIT](LICENSE)

---

## English

FinderRight is a fully local, server-free, open-source macOS tool that adds developer-friendly actions to the Finder right-click menu.

### ✨ Features

- 📄 **New File** — create txt / Markdown / Python / Shell / JSON / Swift / JS and more with one click
- 📋 **Copy Path** — copy the full path of selected files/folders
- 💻 **Open in Terminal** — open the current folder in Terminal / iTerm2 / Warp
- ✏️ **Open in Editor** — open with VS Code / Cursor / Sublime / Xcode, etc.
- ✂️ **Cut / Paste** — the "cut file" that Finder lacks natively
- 📦 **Compress / Extract** — compress to ZIP; extract archives in place
- 👁 **Toggle Hidden Files** — instantly show/hide hidden files **without restarting Finder or flickering** (needs Accessibility)
- ⌨️ **Custom Shortcuts** — bind a keyboard shortcut to any menu item
- 🌗 **Bilingual** — follows your system language (English / 简体中文)

### 📥 Installation

1. Download **[FinderRight.dmg](https://github.com/funny-dog/FinderRight/releases/latest/download/FinderRight.dmg)** — this link always points to the latest release
2. Open the DMG and drag `FinderRight.app` into `Applications`
3. **First launch** (the app is not notarized by Apple, so Gatekeeper must be bypassed):
   ```bash
   xattr -dr com.apple.quarantine /Applications/FinderRight.app
   ```
   Then double-click to open, or right-click → Open → choose "Open" in the dialog.
4. Follow the onboarding:
   - **Enable the Finder extension**: System Settings → Privacy & Security → Extensions → Finder Extensions → check FinderRight
   - **Grant Full Disk Access** (to use all features in protected folders)
   - **Grant Accessibility** (so "Toggle Hidden Files" doesn't flicker)

> ⚠️ This is an ad-hoc signed build. A Developer ID notarized build would remove step 3.

### 🛠 Build from Source

Requires Xcode 16+ and [xcodegen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme FinderRight -configuration Release \
  -derivedDataPath build/release build
```

### 🏗 Architecture

- **Main app** (non-sandboxed): menu bar + settings UI, runs the actual file operations using its TCC permissions
- **Finder extension** (sandboxed): provides the right-click menu
- **IPC**: the extension wakes the main app via a file + URL scheme to perform actions — no App Group or paid developer account required

### ☁️ iCloud / Google Drive and other cloud folders

iCloud Drive, Google Drive, OneDrive, Dropbox and similar cloud storage are **File Provider domains** on macOS; the system only lets their own extension provide the right-click menu, so third-party Finder extensions can't show a menu there (**unrelated to Full Disk Access**). Inside these cloud folders, FinderRight's actions appear under **right-click → Services** instead (available with a file selected: Copy Path / Open in Terminal / Open in Editor / Cut / Compress / Extract). "New File" and pasting into empty space can't use this path since they have no selection.

### 📄 License

[MIT](LICENSE)
