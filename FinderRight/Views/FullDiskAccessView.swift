import SwiftUI
import AppKit

/// 完全磁盘访问（FDA）状态检测和引导界面
struct FullDiskAccessView: View {

    @FRState private var hasFDA: Bool = FullDiskAccessChecker.check()
    @FRState private var lastCheckedAt: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: hasFDA ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundColor(hasFDA ? .green : .orange)
                    .font(.title)
                VStack(alignment: .leading) {
                    Text("完全磁盘访问")
                        .font(.headline)
                    Text(LocalizedStringKey(hasFDA ? "已授权" : "未授权 — 在 ~/Pictures、~/Documents 等受保护目录将无法工作"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if !hasFDA {
                Text("FinderRight 需要「完全磁盘访问」权限，才能在系统保护目录（Documents、Desktop、Downloads、Pictures、Movies、Music）执行右键菜单功能。")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("打开系统设置授权…") {
                        openFullDiskAccessSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("重新检测") {
                        hasFDA = FullDiskAccessChecker.check()
                        lastCheckedAt = Date()
                    }
                }

                DisclosureGroup("授权步骤说明") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 点击上方按钮，会自动跳转到「完全磁盘访问」列表")
                        Text("2. 点击列表底部 +，添加 FinderRight.app")
                        Text("3. 打开 FinderRight 旁边的开关")
                        Text("4. 回到此处点击「重新检测」")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
                }
                .font(.caption)
            }
        }
        .padding()
        .frame(maxWidth: 480, alignment: .leading)
        .onAppear {
            hasFDA = FullDiskAccessChecker.check()
        }
        // 从系统设置授权后切回本 App 时自动刷新，不必再手动点「重新检测」
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasFDA = FullDiskAccessChecker.check()
        }
    }

    private func openFullDiskAccessSettings() {
        // 通过 x-apple.systempreferences URL scheme 直接打开 FDA 设置面板
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - FDA 检测器

/// 检测主 App 当前是否拥有完全磁盘访问权限。
///
/// 没有官方 API 能直接查询 FDA 状态。我们用"侦测一个受保护位置"的方式：
///   - 尝试读 ~/Library/Application Support/com.apple.TCC （这是只有 FDA 才能读的位置）
///   - 或退而求其次：尝试列 ~/Library/Mail（FDA 保护）
enum FullDiskAccessChecker {

    /// 同步检测当前进程是否有 FDA
    static func check() -> Bool {
        let fm = FileManager.default
        let home = ("~" as NSString).expandingTildeInPath

        // 候选探测路径，从最可靠到次可靠
        let probes = [
            "\(home)/Library/Application Support/com.apple.TCC",
            "\(home)/Library/Safari",
            "\(home)/Library/Mail"
        ]
        for path in probes where fm.fileExists(atPath: path) {
            if (try? fm.contentsOfDirectory(atPath: path)) != nil {
                return true
            }
        }
        return false
    }
}

// #Preview {
//     FullDiskAccessView()
// }
