import AppKit
import Combine
import FinderRightKit

/// 每个目录单独在后台读取状态与图标，慢挂载点不阻塞设置页或其他目录。
final class FavoriteDirectoryStatus: ObservableObject {
    struct Entry {
        let available: Bool?
        let icon: NSImage?
    }

    @Published private(set) var entries: [String: Entry] = [:]
    private var pending: [String: UUID] = [:]
    private let check: (String) -> Bool?
    private let icon: (String) -> NSImage?

    init(check: @escaping (String) -> Bool? = FavoriteDirectoryAvailability.isAvailable,
         icon: @escaping (String) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0) }) {
        self.check = check
        self.icon = icon
    }

    func refresh(_ paths: [String]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let paths = Set(paths)
        entries = entries.filter { paths.contains($0.key) }
        pending = pending.filter { paths.contains($0.key) }
        for path in paths where pending[path] == nil {
            let token = UUID()
            pending[path] = token
            let check = check, icon = icon
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let available = check(path)
                let image = available == true ? icon(path) : nil
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.pending[path] == token else { return }
                    self.entries[path] = Entry(available: available, icon: image)
                    self.pending.removeValue(forKey: path)
                }
            }
        }
    }
}
