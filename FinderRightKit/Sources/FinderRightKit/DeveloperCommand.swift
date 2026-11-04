import Foundation
import Darwin

public struct DeveloperCommand: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var script: String
    public var isEnabled: Bool

    public init(id: String = UUID().uuidString, name: String, script: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.script = script
        self.isEnabled = isEnabled
    }

    public var menuId: String { "command.\(id)" }

    public var isValid: Bool {
        UUID(uuidString: id) != nil
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.rangeOfCharacter(from: .controlCharacters) == nil
            && !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !script.utf8.contains(0)
    }

    public static func context(selection: [URL], directory: URL?) throws -> (items: [URL], directory: URL) {
        let items = selection.isEmpty ? directory.map { [$0] } ?? [] : selection
        guard !items.isEmpty, items.allSatisfy(\.isFileURL) else { throw CocoaError(.fileReadInvalidFileName) }
        for item in items { _ = try FileManager.default.attributesOfItem(atPath: item.path) }
        var isDirectory: ObjCBool = false
        let workingDirectory: URL
        if items.count == 1, FileManager.default.fileExists(atPath: items[0].path, isDirectory: &isDirectory), isDirectory.boolValue {
            workingDirectory = items[0]
        } else {
            let parents = Set(items.map { $0.deletingLastPathComponent().standardizedFileURL })
            guard let parent = parents.count == 1 ? parents.first : directory else { throw CocoaError(.fileReadInvalidFileName) }
            workingDirectory = parent
        }
        guard FileManager.default.fileExists(atPath: workingDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return (items, workingDirectory)
    }
}

/// 用户保存的脚本经 shell 执行，选中路径只通过位置参数传入。
public final class DeveloperCommandRunner {
    public struct Result {
        public let status: Int32
        public let output: String
        public let truncated: Bool
        public let cancelled: Bool
    }

    private let lock = NSLock()
    private var process: Process?
    private var group: pid_t?
    private var cancelled = false
    public static let outputLimit = 128 * 1024

    public init() {}

    public func run(script: String, items: [URL], directory: URL,
                    onOutput: (String, Bool) -> Void = { _, _ in }) throws -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", script, "FinderRight"] + items.map(\.path)
        task.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        lock.lock()
        if cancelled {
            lock.unlock()
            return Result(status: -1, output: "", truncated: false, cancelled: true)
        }
        do {
            try task.run()
            process = task
            // macOS Process 创建独立进程组；只在确认后才向整个组发信号。
            group = getpgid(task.processIdentifier) == task.processIdentifier ? task.processIdentifier : nil
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        var tail = Data()
        var truncated = false
        var lastUpdate: TimeInterval = 0
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            tail.append(data)
            if tail.count > Self.outputLimit {
                tail = Data(tail.suffix(Self.outputLimit))
                while let first = tail.first, first & 0xC0 == 0x80 { tail.removeFirst() }
                truncated = true
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastUpdate >= 0.1 {
                onOutput(String(decoding: tail, as: UTF8.self), truncated)
                lastUpdate = now
            }
        }
        task.waitUntilExit()
        lock.lock()
        process = nil
        group = nil
        let wasCancelled = cancelled
        lock.unlock()
        return Result(status: task.terminationStatus, output: String(decoding: tail, as: UTF8.self),
                      truncated: truncated, cancelled: wasCancelled)
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        guard let task = process else { lock.unlock(); return }
        if let group { kill(-group, SIGTERM) }
        else if task.isRunning { task.terminate() }
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) { [weak self, weak task] in
            guard let self, let task else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.process === task else { return }
            if let group = self.group { kill(-group, SIGKILL) }
            else if task.isRunning { kill(task.processIdentifier, SIGKILL) }
        }
    }
}
