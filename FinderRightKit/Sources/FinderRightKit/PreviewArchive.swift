import Foundation
@_implementationOnly import CArchive

public enum PreviewArchiveError: String, LocalizedError, Equatable {
    case invalidArchive = "Invalid or damaged archive"
    case unsupportedFormat = "Archive format or compression is not supported"
    case encryptedArchive = "The archive is encrypted and cannot be previewed"
    case invalidPath = "The archive contains an unsafe or excessively deep path"
    case tooLarge = "The archive directory is too large to preview"
    case timeout = "Archive preview timed out"

    public var errorDescription: String? { rawValue }
}

public enum PreviewArchive {
    public static func read(
        _ url: URL,
        limit: Int = 10000,
        timeout: TimeInterval = 5.0,
        maxPhysicalBytes: Int64 = 500 * 1024 * 1024,
        maxTotalPathBytes: Int = 10 * 1024 * 1024,
        maxScannedEntries: Int = 100_000
    ) throws -> PreviewListing {
        guard timeout.isFinite, (0...60).contains(timeout), maxPhysicalBytes >= 0,
              maxTotalPathBytes >= 0, maxScannedEntries >= 0 else { throw PreviewArchiveError.tooLarge }
        guard url.isFileURL else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard !isDir.boolValue else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            if err == EACCES || err == EPERM {
                throw CocoaError(.fileReadNoPermission)
            } else if err == ENOENT {
                throw CocoaError(.fileReadNoSuchFile)
            } else {
                throw CocoaError(.fileReadUnknown)
            }
        }
        defer { Darwin.close(fd) }
        var fileInfo = stat()
        guard fstat(fd, &fileInfo) == 0, fileInfo.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let context = ArchiveStreamContext(
            fd: fd,
            timeoutSeconds: timeout,
            maxPhysicalBytes: maxPhysicalBytes
        )

        guard let archive = archive_read_new() else {
            throw PreviewArchiveError.invalidArchive
        }
        defer { archive_read_free(archive) }

        archive_read_support_format_tar(archive)
        archive_read_support_format_7zip(archive)
        archive_read_support_format_rar(archive)
        archive_read_support_format_rar5(archive)
        // deb（ar）、rpm（cpio 负载）、iso、pkg（xar）；只列出顶层成员，不再解开内层包。
        archive_read_support_format_ar(archive)
        archive_read_support_format_cpio(archive)
        archive_read_support_format_iso9660(archive)
        archive_read_support_format_xar(archive)

        // ARCHIVE_WARN 可能表示借助外部程序；预览只允许进程内解码。
        guard archive_read_support_filter_none(archive) == ARCHIVE_OK,
              archive_read_support_filter_gzip(archive) == ARCHIVE_OK,
              archive_read_support_filter_xz(archive) == ARCHIVE_OK,
              archive_read_support_filter_bzip2(archive) == ARCHIVE_OK,
              archive_read_support_filter_rpm(archive) == ARCHIVE_OK else {
            throw PreviewArchiveError.unsupportedFormat
        }

        archive_read_set_seek_callback(archive, archiveSeekCallback)

        let unmanagedContext = Unmanaged.passUnretained(context)
        let openResult = archive_read_open2(
            archive,
            unmanagedContext.toOpaque(),
            archiveOpenCallback,
            archiveReadCallback,
            archiveSkipCallback,
            archiveCloseCallback
        )

        if openResult != ARCHIVE_OK {
            if context.timedOut { throw PreviewArchiveError.timeout }
            if context.byteLimitExceeded { throw PreviewArchiveError.tooLarge }
            let errorString = archive_error_string(archive).map { String(cString: $0) } ?? ""
            if archive_read_has_encrypted_entries(archive) > 0 ||
                errorString.localizedCaseInsensitiveContains("encrypt") ||
                errorString.localizedCaseInsensitiveContains("password") {
                throw PreviewArchiveError.encryptedArchive
            }
            if errorString.localizedCaseInsensitiveContains("unrecognized") {
                throw PreviewArchiveError.unsupportedFormat
            }
            throw PreviewArchiveError.invalidArchive
        }

        var entries: [PreviewEntry] = []
        var truncated = false
        var scannedCount = 0
        var totalPathBytes = 0
        let maxDecompressedBytes: Int64 = 1024 * 1024 * 1024 // 1GB

        while true {
            if context.isTimedOut() {
                throw PreviewArchiveError.timeout
            }

            var entryPointer: OpaquePointer?
            let nextHeaderResult = archive_read_next_header(archive, &entryPointer)

            if context.timedOut { throw PreviewArchiveError.timeout }
            if context.byteLimitExceeded || archive_filter_bytes(archive, 0) > maxDecompressedBytes {
                throw PreviewArchiveError.tooLarge
            }
            if nextHeaderResult == ARCHIVE_EOF { break }

            if nextHeaderResult != ARCHIVE_OK && nextHeaderResult != ARCHIVE_WARN {
                if context.timedOut { throw PreviewArchiveError.timeout }
                if context.byteLimitExceeded { throw PreviewArchiveError.tooLarge }
                let errorString = archive_error_string(archive).map { String(cString: $0) } ?? ""
                if archive_read_has_encrypted_entries(archive) > 0 ||
                    errorString.localizedCaseInsensitiveContains("encrypt") ||
                    errorString.localizedCaseInsensitiveContains("password") {
                    throw PreviewArchiveError.encryptedArchive
                }
                if errorString.localizedCaseInsensitiveContains("unrecognized") {
                    throw PreviewArchiveError.unsupportedFormat
                }
                throw PreviewArchiveError.invalidArchive
            }

            guard let entry = entryPointer else { break }

            if archive_entry_is_encrypted(entry) != 0 || archive_read_has_encrypted_entries(archive) > 0 {
                throw PreviewArchiveError.encryptedArchive
            }

            scannedCount += 1
            if scannedCount > maxScannedEntries {
                truncated = true
                break
            }

            let rawPathCStr = archive_entry_pathname_utf8(entry) ?? archive_entry_pathname(entry)
            guard let validCStr = rawPathCStr else {
                throw PreviewArchiveError.invalidArchive
            }
            guard var pathString = String(validatingCString: validCStr) else {
                throw PreviewArchiveError.invalidPath
            }

            // 允许普通 tar 常见 ./ 前缀及单独根 ./ 条目（不展示）
            if pathString == "." || pathString == "./" {
                continue
            }
            if pathString.hasPrefix("./") {
                pathString = String(pathString.dropFirst(2))
                if pathString.isEmpty || pathString == "." || pathString == "./" {
                    continue
                }
            }

            // 安全路径校验：拒绝绝对路径、空组件、..、\、NUL、盘符、超深或过长路径
            guard !pathString.hasPrefix("/"),
                  !pathString.contains("\0"),
                  !pathString.contains("\\"),
                  !(pathString.count >= 2 && pathString[pathString.index(after: pathString.startIndex)] == ":"),
                  pathString.count <= 1024 else {
                throw PreviewArchiveError.invalidPath
            }

            let components = pathString.split(separator: "/", omittingEmptySubsequences: false)
            let parts = pathString.hasSuffix("/") ? components.dropLast() : components[...]

            guard !parts.isEmpty,
                  parts.count <= 32,
                  !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.count > 255 }) else {
                throw PreviewArchiveError.invalidPath
            }

            if parts.contains(where: PreviewContents.isClutter) {
                continue
            }

            totalPathBytes += pathString.utf8.count
            if totalPathBytes > maxTotalPathBytes {
                throw PreviewArchiveError.tooLarge
            }

            if entries.count >= max(0, limit) {
                truncated = true
                break
            }

            let fileType = archive_entry_filetype(entry)
            let isSymbolicLink = (fileType == AE_IFLNK)
            let isDirectory = !isSymbolicLink && (fileType == AE_IFDIR || pathString.hasSuffix("/"))

            let size: Int64?
            if isDirectory || isSymbolicLink {
                size = nil
            } else if archive_entry_size_is_set(entry) != 0 {
                let bytes = archive_entry_size(entry)
                guard bytes >= 0 else { throw PreviewArchiveError.invalidArchive }
                size = bytes
            } else {
                size = nil
            }

            let modificationDate: Date?
            if archive_entry_mtime_is_set(entry) != 0 {
                let sec = TimeInterval(archive_entry_mtime(entry))
                let nsec = TimeInterval(archive_entry_mtime_nsec(entry)) / 1_000_000_000
                modificationDate = Date(timeIntervalSince1970: sec + nsec)
            } else {
                modificationDate = nil
            }

            entries.append(PreviewEntry(
                path: pathString,
                isDirectory: isDirectory,
                isSymbolicLink: isSymbolicLink,
                size: size,
                modificationDate: modificationDate
            ))
        }

        return PreviewListing(entries: entries, truncated: truncated)
    }
}

private final class ArchiveStreamContext {
    let fd: Int32
    let startInstant: DispatchTime
    let timeoutNanoseconds: UInt64
    let maxPhysicalBytes: Int64

    let bufferSize = 65536
    let buffer: UnsafeMutableRawPointer
    var totalBytesRead: Int64 = 0
    var timedOut: Bool = false
    var byteLimitExceeded: Bool = false

    init(fd: Int32, timeoutSeconds: TimeInterval, maxPhysicalBytes: Int64) {
        self.fd = fd
        self.startInstant = DispatchTime.now()
        self.timeoutNanoseconds = timeoutSeconds > 0 ? UInt64(timeoutSeconds * 1_000_000_000) : 0
        self.maxPhysicalBytes = maxPhysicalBytes
        self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    deinit {
        buffer.deallocate()
    }

    func isTimedOut() -> Bool {
        if timedOut { return true }
        if timeoutNanoseconds == 0 {
            timedOut = true
            return true
        }
        let now = DispatchTime.now()
        if now.uptimeNanoseconds >= startInstant.uptimeNanoseconds + timeoutNanoseconds {
            timedOut = true
            return true
        }
        return false
    }
}

private let archiveOpenCallback: archive_open_callback = { _, _ in
    return 0
}

private let archiveReadCallback: archive_read_callback = { archive, clientData, bufferPointer in
    guard let clientData = clientData, let bufferPointer = bufferPointer else { return -1 }
    let ctx = Unmanaged<ArchiveStreamContext>.fromOpaque(clientData).takeUnretainedValue()

    if ctx.isTimedOut() {
        ctx.timedOut = true
        return -1
    }

    if ctx.totalBytesRead >= ctx.maxPhysicalBytes || archive.map({ archive_filter_bytes($0, 0) > 1024 * 1024 * 1024 }) == true {
        ctx.byteLimitExceeded = true
        return -1
    }

    let remainingQuota = Int(ctx.maxPhysicalBytes - ctx.totalBytesRead)
    let toRead = min(ctx.bufferSize, remainingQuota)
    let bytesRead = Darwin.read(ctx.fd, ctx.buffer, toRead)

    if bytesRead > 0 {
        ctx.totalBytesRead += Int64(bytesRead)
        bufferPointer.pointee = UnsafeRawPointer(ctx.buffer)
        return bytesRead
    } else if bytesRead == 0 {
        return 0
    } else {
        return -1
    }
}

private let archiveSkipCallback: archive_skip_callback = { _, clientData, request in
    guard let clientData = clientData else { return 0 }
    let ctx = Unmanaged<ArchiveStreamContext>.fromOpaque(clientData).takeUnretainedValue()

    if ctx.isTimedOut() {
        ctx.timedOut = true
        return 0
    }

    let oldPos = Darwin.lseek(ctx.fd, 0, SEEK_CUR)
    guard oldPos >= 0 else { return 0 }
    let newPos = Darwin.lseek(ctx.fd, off_t(request), SEEK_CUR)
    guard newPos >= 0 else { return 0 }
    return Int64(newPos - oldPos)
}

private let archiveSeekCallback: archive_seek_callback = { _, clientData, request, whence in
    guard let clientData = clientData else { return -1 }
    let ctx = Unmanaged<ArchiveStreamContext>.fromOpaque(clientData).takeUnretainedValue()

    if ctx.isTimedOut() {
        ctx.timedOut = true
        return -1
    }

    let pos = Darwin.lseek(ctx.fd, off_t(request), whence)
    return Int64(pos)
}

private let archiveCloseCallback: archive_close_callback = { _, _ in
    return 0
}
