import Foundation
import FinderRightKit

/// ZIP 的虚拟目录与本地目录共用列表节点；本地目录的 children 在展开后加载。
final class PreviewNode {
    let path: String
    let name: String
    var entry: PreviewEntry?
    var children: [PreviewNode] = []
    var loaded: Bool
    var loading = false

    var isDirectory: Bool { entry.map { $0.isDirectory && !$0.isSymbolicLink } ?? true }

    init(path: String, entry: PreviewEntry? = nil, loaded: Bool = false) {
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.entry = entry
        self.loaded = loaded
    }

    static func archiveTree(_ entries: [PreviewEntry]) throws -> [PreviewNode] {
        var nodes: [String: PreviewNode] = [:]
        var roots: [PreviewNode] = []
        for entry in entries {
            let components = entry.path.split(separator: "/").map(String.init)
            var path = ""
            var parent: PreviewNode?
            for (index, component) in components.enumerated() {
                path = path.isEmpty ? component : path + "/" + component
                let last = index == components.count - 1
                let node: PreviewNode
                if let existing = nodes[path] {
                    guard existing.isDirectory || last else { throw CocoaError(.fileReadCorruptFile) }
                    if last {
                        guard (entry.isDirectory && !entry.isSymbolicLink) || existing.children.isEmpty else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        existing.entry = entry
                    }
                    node = existing
                } else {
                    // shortcut: 最多展示 20000 个实际及隐式节点，更大目录需求出现后再做分页。
                    guard nodes.count < 20_000 else { throw CocoaError(.fileReadTooLarge) }
                    node = PreviewNode(path: path, entry: last ? entry : nil, loaded: true)
                    nodes[path] = node
                    if let parent { parent.children.append(node) } else { roots.append(node) }
                }
                parent = node
            }
        }
        return roots
    }
}
