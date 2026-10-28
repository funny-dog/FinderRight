import AppKit
import FinderRightKit
import ImageIO

// 使用内存记录隔离历史与提示；不启动 App、不打开窗口、不操作用户配置。
enum ClipboardToast {
    enum Style { case success, failure, partial }
    static var last: (message: String, style: Style)?
    static func show(message: String, style: Style) { last = (message, style) }
}
struct OperationRecord {
    enum Kind { case convertImage, scaleImage }
    let kind: Kind
    let subject: String
    let failure: String?
    let note: String?
    let results: [URL]
    let location: URL?
    init(kind: Kind, subject: String, failure: String? = nil, results: [URL] = [], location: URL? = nil, note: String? = nil) {
        self.kind = kind; self.subject = subject; self.failure = failure; self.results = results; self.location = location; self.note = note
    }
}
final class RecentOperations {
    static let shared = RecentOperations()
    var records: [OperationRecord] = []
    func record(_ record: OperationRecord) { records.append(record) }
}
func serviceLog(_ message: String) {}
final class FinderRightService {
    static let archiveQueue = DispatchQueue(label: "test.image")
    static let backgroundJobs = BackgroundJobs()
    var undo: UndoRecord?
    func isPathAllowed(_ path: String, role: PathAccessPolicy.Role) -> Bool {
        if role == .source, URL(fileURLWithPath: path).lastPathComponent == "denied.png" { return false }
        if role == .destination, URL(fileURLWithPath: path).lastPathComponent == "denied-output" { return false }
        return true
    }
    static func subject(forPaths paths: [String]) -> String { "\(paths.count)" }
    func registerUndo(_ kind: UndoRecord.Kind, name: String, items: [(URL, URL?)], displayCount: Int? = nil) {
        undo = UndoRecord(kind: kind, name: name, items: items.map {
            UndoRecord.Item(current: $0.0, original: $0.1, fingerprint: FileFingerprint.capture($0.0)!)
        }, cutQueueBefore: nil, finderSnapshot: nil, displayCount: displayCount)
    }
}
enum ImageTransformer {
    static func process(sourceURL: URL, operation: ImageTransformOperation, outputDirectory: URL?) throws -> URL {
        try FinderRightKit.ImageTransformer.process(sourceURL: sourceURL, operation: operation, outputDirectory: outputDirectory,
            registry: ScratchDirectoryRegistry(registryDirectory: sourceURL.deletingLastPathComponent()))
    }
}
@main
struct ImageServiceChecks {
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--sandbox-image-candidate" {
            let url = URL(fileURLWithPath: CommandLine.arguments[2])
            precondition(ImageMenuState.canInspectSelection([url]))
            precondition(!ImageMenuState.evaluate(urls: [url]).isAllImages, "Sandbox still readable: \(url.path) resolved=\(url.resolvingSymlinksInPath().path)")
            print("Image candidate remains detectable without sandbox file-read-data")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finderright-image-service-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ file: URL, width: Int = 40, height: Int = 20) throws {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, context.makeImage()!, nil)
            precondition(CGImageDestinationFinalize(dest))
        }
        let first = root.appendingPathComponent("first.png"), last = root.appendingPathComponent("last.png")
        let denied = root.appendingPathComponent("denied.png"), corrupt = root.appendingPathComponent("corrupt.png")
        let missing = root.appendingPathComponent("missing.png")
        let outputDenied = root.appendingPathComponent("denied-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDenied, withIntermediateDirectories: true)
        let blocked = outputDenied.appendingPathComponent("blocked.png")
        for file in [first, last, denied, blocked] { try fixture(file) }
        try Data("not an image".utf8).write(to: corrupt)
        let original = try Data(contentsOf: first)
        let service = FinderRightService()
        // 沙箱按真实路径匹配，Foundation 的 URL 仍可能保留 /var 别名。
        let canonical = realpath(first.path, nil)!
        defer { free(canonical) }
        let profile = "(version 1)(allow default)(deny file-read-data (literal \"\(String(cString: canonical))\"))"
        let sandbox = try ProcessRunner.run(executableURL: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: [
            "-p", profile, CommandLine.arguments[0], "--sandbox-image-candidate", first.path
        ])
        precondition(sandbox.status == 0, sandbox.stderr)
        func inspect(_ files: [URL]) throws -> ImageMenuState {
            let response = service.inspectImages(IPCRequest(id: UUID().uuidString, action: "inspectImages", payload: [
                "items": .stringArray(files.map(\.path))
            ]))
            precondition(response.success)
            return try JSONDecoder().decode(ImageMenuState.self, from: Data(response.message!.utf8))
        }
        let valid = try inspect([first, last])
        precondition(valid.isAllImages && valid.allArePNG)
        let invalid = try inspect([first, corrupt])
        precondition(!invalid.isAllImages)
        precondition(!service.inspectImages(IPCRequest(id: UUID().uuidString, action: "inspectImages", payload: [
            "items": .stringArray([denied.path])
        ])).success)
        precondition(RecentOperations.shared.records.isEmpty && service.undo == nil)
        print("Image menu inspection: sandbox candidate, host validation, corrupt-file rejection and path policy passed")
        let request = IPCRequest(id: UUID().uuidString, action: "convertImage", payload: [
            "items": .stringArray([first, missing, corrupt, denied, blocked, last].map(\.path)), "format": .string("jpeg")
        ])
        let invalidScale = IPCRequest(id: UUID().uuidString, action: "scaleImage", payload: [
            "items": .stringArray([first.path]), "maxPixel": .int(Int.max)
        ])
        precondition(!service.scaleImage(invalidScale).success)
        precondition(service.convertImage(request).success)
        precondition(FinderRightService.backgroundJobs.waitUntilIdle(timeout: 10))
        precondition(RecentOperations.shared.records.count == 1)
        let record = RecentOperations.shared.records[0]
        precondition(record.results.count == 2 && record.failure != nil)
        for name in ["missing.png", "corrupt.png", "denied.png", "blocked.png"] {
            precondition(record.failure!.contains(name), "Missing per-file failure: \(name)")
        }
        let undo = service.undo!
        precondition(undo.items.count == 2 && undo.kind == .convertImage && !undo.restoresByMoving)
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let outcome = UndoExecutor.run(undo) { file in
            try FileManager.default.moveItem(at: file, to: trash.appendingPathComponent(file.lastPathComponent))
        }
        precondition(outcome.undone.count == 2 && outcome.skipped.isEmpty)
        precondition(record.results.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let afterUndo = try Data(contentsOf: first)
        precondition(afterUndo == original)
        precondition(FileManager.default.fileExists(atPath: last.path))
        let previousUndo = service.undo
        precondition(service.scaleImage(IPCRequest(id: UUID().uuidString, action: "scaleImage", payload: [
            "items": .stringArray([first.path, last.path]), "maxPixel": .int(800)
        ])).success)
        precondition(FinderRightService.backgroundJobs.waitUntilIdle(timeout: 10))
        let allSkipped = RecentOperations.shared.records.last!
        precondition(allSkipped.failure == nil && allSkipped.results.isEmpty)
        precondition(allSkipped.note!.contains("first.png") && allSkipped.note!.contains("last.png"))
        precondition(service.undo == previousUndo)
        precondition(ClipboardToast.last!.style == .success && ClipboardToast.last!.message.contains("无需缩放"))

        let large = root.appendingPathComponent("large.png")
        try fixture(large, width: 1200, height: 600)
        precondition(service.scaleImage(IPCRequest(id: UUID().uuidString, action: "scaleImage", payload: [
            "items": .stringArray([large.path, first.path]), "maxPixel": .int(800)
        ])).success)
        precondition(FinderRightService.backgroundJobs.waitUntilIdle(timeout: 10))
        let mixed = RecentOperations.shared.records.last!
        precondition(mixed.failure == nil && mixed.results.count == 1 && mixed.note!.contains("first.png"))
        precondition(service.undo!.items.count == 1 && service.undo!.kind == .scaleImage)
        precondition(ClipboardToast.last!.style == .success)

        precondition(service.scaleImage(IPCRequest(id: UUID().uuidString, action: "scaleImage", payload: [
            "items": .stringArray([corrupt.path, first.path]), "maxPixel": .int(800)
        ])).success)
        precondition(FinderRightService.backgroundJobs.waitUntilIdle(timeout: 10))
        let realFailure = RecentOperations.shared.records.last!
        precondition(realFailure.failure!.contains("corrupt.png") && !realFailure.failure!.contains("first.png"))
        precondition(realFailure.note!.contains("first.png"))
        print("Image scaling: all-small and mixed batches skip normally; real errors stay failures; undo only tracks outputs")
        print("Image service batch: continues after failures, checks both path roles, records every failure, one undo preserves sources")
    }
}
