import Foundation

/// Downloads the add-on subtitles of an mpv session OUTSIDE the libmpv core.
///
/// `sub-add <http url>` opens and probes the remote file inside the core, which stays busy for the
/// whole download: with forty add-on subtitles at 0.3 to 1 s each, the core (and so the picture, the
/// sound and every command queued behind it) hitched for 10 to 30 s right after the file loaded. Here
/// the files come down through `URLSession`, a few at a time, most wanted first, into the session's
/// own temp folder; mpv is then handed the local path, which `sub-add` takes in milliseconds. The
/// requests carry none of the stream's headers, so a stream's credentials never reach a subtitle host.
nonisolated final class MPVSubtitleFetcher: @unchecked Sendable {
    /// Downloads in flight at once.
    static let maxConcurrent = 3
    /// A subtitle file is a few hundred KB at most; anything bigger is not one.
    static let maxBytes = 6 * 1024 * 1024

    private struct Job {
        let remote: URL
        let priority: Int
        let completion: (URL?) -> Void
    }

    private let lock = NSLock()
    private var pending: [Job] = []
    private var running = 0
    private var closed = false
    private let session: URLSession
    private let directory: URL

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = Self.maxConcurrent
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpv-subs-\(UUID().uuidString)", isDirectory: true)
    }

    /// Queues `remote`. A lower `priority` goes first; equal priorities keep their order. `completion`
    /// runs on a background queue with the local file, or nil when the download failed.
    func enqueue(_ remote: URL, priority: Int, completion: @escaping (URL?) -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            completion(nil)
            return
        }
        let job = Job(remote: remote, priority: priority, completion: completion)
        let index = pending.firstIndex { $0.priority > priority } ?? pending.endIndex
        pending.insert(job, at: index)
        lock.unlock()
        startNext()
    }

    /// The session is over: queued downloads are dropped, running ones cancelled, the files removed.
    func close() {
        lock.lock()
        closed = true
        let dropped = pending
        pending.removeAll()
        lock.unlock()
        session.invalidateAndCancel()
        for job in dropped { job.completion(nil) }
        try? FileManager.default.removeItem(at: directory)
    }

    private func startNext() {
        lock.lock()
        guard !closed, running < Self.maxConcurrent, !pending.isEmpty else {
            lock.unlock()
            return
        }
        let job = pending.removeFirst()
        running += 1
        lock.unlock()

        let task = session.dataTask(with: job.remote) { [weak self] data, response, error in
            let local = self?.store(data, response: response, error: error, remote: job.remote)
            job.completion(local)
            guard let self else { return }
            self.lock.lock()
            self.running -= 1
            self.lock.unlock()
            self.startNext()
        }
        task.resume()
    }

    private func store(_ data: Data?, response: URLResponse?, error: Error?, remote: URL) -> URL? {
        guard error == nil, let data, !data.isEmpty, data.count <= Self.maxBytes else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        lock.lock()
        let isClosed = closed
        lock.unlock()
        guard !isClosed else { return nil }
        let rawExtension = remote.pathExtension.lowercased()
        let valid = !rawExtension.isEmpty && rawExtension.count <= 5 && rawExtension.allSatisfy { $0.isLetter || $0.isNumber }
        let local = directory.appendingPathComponent("\(UUID().uuidString).\(valid ? rawExtension : "srt")")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: local, options: .atomic)
            return local
        } catch {
            return nil
        }
    }
}
