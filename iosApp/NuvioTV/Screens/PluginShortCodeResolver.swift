import Foundation
import SharedCore

/// Turns a plugin repository short code ("cspr", "0094") into the repository address its cutt.ly
/// link redirects to (Android TV parity: `PluginManager.resolveShortCode`). The redirect is read,
/// not followed, so nothing is downloaded from the destination here; the shared repository fetches
/// the manifest afterwards like for any typed URL. When the shortener answers without a redirect
/// the address the request ended at is used instead.
///
/// The rules around the address (what counts as a code, what a redirect may point to) live in the
/// shared `PluginRepositoryInput`.
enum PluginShortCodeResolver {
    static let timeoutSeconds: TimeInterval = 10

    /// The repository address for `code`, or nil when the code names nothing (or the lookup failed).
    static func resolve(code: String) async -> String? {
        let linkString = PluginRepositoryInput.shared.shortCodeUrl(code: code)
        guard let link = URL(string: linkString) else { return nil }

        let catcher = RedirectCatcher()
        let session = URLSession(configuration: .ephemeral, delegate: catcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: link, timeoutInterval: timeoutSeconds)
        request.setValue("NuvioTV/1.0", forHTTPHeaderField: "User-Agent")

        var endedAt: String?
        do {
            let (_, response) = try await session.data(for: request)
            endedAt = response.url?.absoluteString
        } catch {
            // A refused redirect can surface as an error on some systems: the Location is already caught.
        }

        let redirect: String? = PluginRepositoryInput.shared.repositoryUrlFromRedirect(location: catcher.location)
        if let redirect { return redirect }
        guard let endedAt, endedAt != linkString else { return nil }
        let fallback: String? = PluginRepositoryInput.shared.repositoryUrlFromRedirect(location: endedAt)
        return fallback
    }

    /// Records the first redirect's destination and refuses to follow it.
    private nonisolated final class RedirectCatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var captured: String?

        var location: String? {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            lock.lock()
            if captured == nil { captured = request.url?.absoluteString }
            lock.unlock()
            completionHandler(nil)
        }
    }
}
