import AppKit
import FinderRightKit
import ImageIO

// 使用内存记录隔离历史与提示；不启动 App、不打开窗口、不操作用户配置。
enum ClipboardToast {
    enum Style { case success, failure, partial }
    static func show(message: String, style: Style) {}
}
struct OperationRecord {
    enum Kind { case convertImage, scaleImage }
    let kind: Kind
    let subject: String
    let failure: String?
    let results: [URL]
    let location: URL?
    init(kind: Kind, subject: String, failure: String? = nil, results: [URL] = [], location: URL? = nil) {
        self.kind = kind; self.subject = subject; self.failure = failure; self.results = results; self.location = location
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
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("finderright-image-service-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func fixture(_ file: URL) throws {
            let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
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
        print("Image service batch: continues after failures, checks both path roles, records every failure, one undo preserves sources")
    }
}
