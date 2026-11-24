import Foundation
import AppKit
import FinderRightKit

// MARK: - 下载进度与回调代理

final class UpdateDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private let onFirstData: (() -> Void)?
    private let onFinish: (Result<URL, Error>) -> Void
    private let schedule: (TimeInterval, DispatchWorkItem) -> Void
    private var tracker: DownloadTimeoutTracker
    private var timeout: DispatchWorkItem?
    private var hasReceivedValidData = false

    init(onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<URL, Error>) -> Void,
         schedule: @escaping (TimeInterval, DispatchWorkItem) -> Void = { interval, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: work)
         },
         onFirstData: (() -> Void)? = nil) {
        self.tracker = DownloadTimeoutTracker(firstByteTimeout: 15, stallTimeout: 10)
        self.onProgress = onProgress
        self.onFirstData = onFirstData
        self.onFinish = onFinish
        self.schedule = schedule
        super.init()
    }

    func watch(_ task: URLSessionDownloadTask, firstByteTimeout: TimeInterval, stallTimeout: TimeInterval) {
        self.tracker = DownloadTimeoutTracker(firstByteTimeout: firstByteTimeout, stallTimeout: stallTimeout)
        scheduleTimeout(for: task, after: tracker.initialTimeout())
    }

    func cancel() {
        guard tracker.handleFinished() else { return }
        timeout?.cancel()
        timeout = nil
    }

    private func scheduleTimeout(for task: URLSessionDownloadTask, after interval: TimeInterval) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self, weak task] in
            guard let self, !self.tracker.isCompleted else { return }
            task?.cancel()
            self.finish(.failure(URLError(.timedOut)))
        }
        timeout = work
        schedule(interval, work)
    }

    private func finish(_ result: Result<URL, Error>) {
        guard tracker.handleFinished() else { return }
        timeout?.cancel()
        timeout = nil
        onFinish(result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            downloadTask.cancel()
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        guard let decision = tracker.handleDataWritten(bytesWritten: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpected: totalBytesExpectedToWrite) else { return }
        if !hasReceivedValidData && (bytesWritten > 0 || totalBytesWritten > 0) {
            hasReceivedValidData = true
            onFirstData?()
        }
        if let resetInterval = decision.resetTimeoutInterval {
            scheduleTimeout(for: downloadTask, after: resetInterval)
        }
        if let progress = decision.progress {
            onProgress(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard !tracker.isCompleted else { return }
        guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let destination = tempDir.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
