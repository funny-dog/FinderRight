import Foundation

@main
struct MonitoredVolumeCheck {
    static func main() {
        for path in ["/Volumes/QuarkCloudDrive", "/Volumes/QuarkCloudDrive 1", "/Volumes/ReadOnlyDisk"] {
            assert(!FinderSync.shouldMonitorVolume(at: URL(fileURLWithPath: path), isReadOnly: true),
                   "只读卷不应注册为 FinderSync 根目录：\(path)")
        }
        for path in ["/Volumes/E", "/Volumes/NAS", "/Users/test/OrbStack"] {
            assert(FinderSync.shouldMonitorVolume(at: URL(fileURLWithPath: path), isReadOnly: false),
                   "可写外接盘与网络卷应保留右键菜单：\(path)")
        }
        for path in ["/", "/System/Volumes/Data", "/private/var"] {
            assert(!FinderSync.shouldMonitorVolume(at: URL(fileURLWithPath: path), isReadOnly: false),
                   "启动卷与系统目录仍应排除：\(path)")
        }
        print("PASS: 只读安装镜像排除、可写外接盘与网络卷保留、系统目录排除")
    }
}
