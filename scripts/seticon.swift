// 给文件设置自定义图标，等价于在 Finder 的「显示简介」里粘贴图标。
// build.sh 用它让下载下来的 DMG 显示应用图标，而不是默认的空白磁盘图标。
//
// 注意：这会写入文件的资源分支（com.apple.ResourceFork）。该工具只在本机
// 构建时调用，CI 不构建 DMG，因此不依赖图形会话的稳定性。

import Cocoa

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: seticon <target-file> <icon-file>\n".data(using: .utf8)!)
    exit(2)
}
let target = args[1]
let iconPath = args[2]

guard FileManager.default.fileExists(atPath: target) else {
    FileHandle.standardError.write("target not found: \(target)\n".data(using: .utf8)!)
    exit(3)
}
guard let image = NSImage(contentsOfFile: iconPath), image.size.width > 0 else {
    FileHandle.standardError.write("cannot read icon: \(iconPath)\n".data(using: .utf8)!)
    exit(4)
}
guard NSWorkspace.shared.setIcon(image, forFile: target, options: []) else {
    FileHandle.standardError.write("setIcon failed\n".data(using: .utf8)!)
    exit(5)
}
exit(0)
