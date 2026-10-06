import Foundation
import Network

/// A tiny loopback HTTP/1.1 stub that plays a self-hosted Nuvio backend for the UI tests:
/// serves `GET /.well-known/nuvio` (the discovery document) and answers everything else with
/// a short 404 JSON body. The tvOS simulator shares the Mac's loopback interface, so the app
/// under test reaches it at `http://127.0.0.1:<port>` from inside the sim.
///
/// Deliberately minimal (no keep-alive, one request per connection): it exists to exercise the
/// app's discovery → review UI and the server-switch plumbing, not to emulate Supabase. After a
/// switch the app's Supabase client will hit this stub for auth/REST and get 404s — every one of
/// those paths is already designed to fail soft (session restore → signed out, guest mode works
/// fully offline), which is exactly the surface the scratch-device test verifies.
final class DiscoveryStubServer {
    struct Document {
        var version: Int = 1
        var service: String = "nuvio"
        var selfHosted: Bool = true
        /// Defaults to this stub's own origin once started (the usual self-host layout: the
        /// discovery document lives on the backend host).
        var backendUrl: String? = nil
        var publishableKey: String = "stub-publishable-key"
        var emailPasswordAuth: Bool = true
        var tvLogin: Bool = false

        func json(origin: String) -> String {
            """
            {"version":\(version),"service":"\(service)","self_hosted":\(selfHosted),\
            "backend_url":"\(backendUrl ?? origin)","publishable_key":"\(publishableKey)",\
            "capabilities":{"email_password_auth":\(emailPasswordAuth),"tv_login":\(tvLogin)}}
            """
        }
    }

    private(set) var port: UInt16 = 0
    var origin: String { "http://127.0.0.1:\(port)" }
    /// Every request line the stub saw (method + path), for assertions.
    private(set) var requestLog: [String] = []

    private let document: Document
    private let lock = NSLock()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "nuvio.uitests.discovery-stub")

    init(document: Document = Document()) {
        self.document = document
    }

    /// Binds an ephemeral loopback port; returns once the listener is ready (or throws).
    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        let ready = DispatchSemaphore(value: 0)
        var readyError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                readyError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            throw NSError(domain: "DiscoveryStubServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        if let readyError { throw readyError }
        guard let bound = listener.port?.rawValue else {
            throw NSError(domain: "DiscoveryStubServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "listener has no port"])
        }
        self.listener = listener
        self.port = bound
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { connection.cancel(); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let requestLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            let parts = requestLine.split(separator: " ")
            let method = parts.count > 0 ? String(parts[0]) : ""
            let rawPath = parts.count > 1 ? String(parts[1]) : "/"
            let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath
            self.lock.lock()
            self.requestLog.append("\(method) \(path)")
            self.lock.unlock()

            let body: String
            let status: String
            if method == "GET", path == "/.well-known/nuvio" {
                status = "200 OK"
                body = self.document.json(origin: self.origin)
            } else {
                status = "404 Not Found"
                body = "{\"error\":\"stub: no such route\"}"
            }
            let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
