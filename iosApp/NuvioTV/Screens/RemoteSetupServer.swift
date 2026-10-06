import Foundation
import Network
import Security

/// A tiny HTTP/1.1 server (Network.framework `NWListener`) that lets the user configure the app
/// from a phone/laptop browser on the same network — the tvOS analog of Android TV's
/// `AddonConfigServer` (NanoHTTPD). Massive text-entry relief vs the tvOS keyboard.
///
/// Endpoints (all JSON unless noted):
/// - `GET  /`               → the embedded config web page (see `RemoteSetupWebPage`)
/// - `GET  /api/state`      → current addons / home rows / key presence snapshot
/// - `POST /api/apply`      → proposes a change; returns `{id, status: "pending_confirmation"}`.
///                            Nothing is applied until the user confirms ON THE TV (alert in
///                            Settings) — same trust model as Android.
/// - `GET  /api/status/{id}`→ `{status: pending|confirmed|rejected|not_found}` (browser polls)
///
/// Threading: the listener + connections run on a private queue. The state snapshot and the
/// pending-change table are guarded by a lock; `onChangeProposed` is delivered on the main queue.
/// The server holds no SharedCore references — `RemoteSetupViewModel` feeds it data.
final class RemoteSetupServer {

    // MARK: - Wire models

    /// What the web page proposes. All fields optional so old/partial pages stay compatible.
    struct Proposal: Decodable {
        struct AddonEntry: Decodable {
            let url: String
            let enabled: Bool?
        }

        /// Full desired addon list, in order. Missing = leave addons untouched.
        let addons: [AddonEntry]?
        /// Full desired Home-row key order. Missing = leave order untouched.
        let rowOrder: [String]?
        /// Keys of rows that should be disabled (everything else in `rowOrder` is enabled).
        let disabledRowKeys: [String]?
        /// New API keys; only sent when the user typed one (never echoes saved keys).
        let tmdbKey: String?
        let mdblistKey: String?
        /// Stream badge pack JSON URLs to import (staged additions only; removal happens on TV).
        let badgeUrls: [String]?
    }

    enum ChangeStatus: String {
        case pending
        case confirmed
        case rejected
    }

    final class PendingChange {
        let id: String
        let proposal: Proposal
        var status: ChangeStatus = .pending
        let createdAt = Date()

        init(proposal: Proposal) {
            self.id = UUID().uuidString
            self.proposal = proposal
        }
    }

    // MARK: - Public surface

    /// Fired (on main) when a browser POSTs a proposal. The host UI shows a confirm alert and
    /// then calls `confirm(id:)` or `reject(id:)`.
    var onChangeProposed: ((PendingChange) -> Void)?

    private(set) var port: UInt16?

    /// Per-session pairing token (HI-001). Included in the QR/display URL as `?t=…`; every route
    /// rejects requests that don't present it, so a LAN port-scanner can't read the config
    /// (addon manifest URLs may embed debrid API keys). Regenerated on every `start()`.
    var sessionToken: String? {
        lock.lock(); defer { lock.unlock() }
        return token
    }

    /// Starts listening; tries ports 8080…8089. `completion` (main queue) gets the bound port,
    /// or nil if every port failed.
    func start(completion: @escaping (UInt16?) -> Void) {
        lock.lock()
        guard listener == nil else {
            let current = port
            lock.unlock()
            DispatchQueue.main.async { completion(current) }
            return
        }
        generation += 1
        token = Self.makeToken()
        let gen = generation
        lock.unlock()
        attemptStart(portOffset: 0, generation: gen, completion: completion)
    }

    func stop() {
        lock.lock()
        // Invalidate in-flight start attempts (HI-002): a candidate listener that reaches `.ready`
        // after this point must cancel itself instead of resurrecting the server.
        generation += 1
        let active = listener
        listener = nil
        port = nil
        token = nil
        pending.removeAll()
        pendingOrder.removeAll()
        lastProposalAt = nil
        lock.unlock()
        active?.cancel()
    }

    /// Replaces the JSON served at `/api/state`. Called from the main actor whenever repos emit.
    func updateState(_ json: Data) {
        lock.lock()
        stateJSON = json
        lock.unlock()
    }

    func confirm(id: String) {
        setStatus(id: id, status: .confirmed)
    }

    func reject(id: String) {
        setStatus(id: id, status: .rejected)
    }

    // MARK: - Internals

    private let queue = DispatchQueue(label: "nuvio.remote-setup-server")
    private var listener: NWListener?
    private let lock = NSLock()
    private var stateJSON = Data("{}".utf8)
    private var pending: [String: PendingChange] = [:]
    /// Insertion order of `pending` ids, oldest first, so the table stays bounded (ME-003).
    private var pendingOrder: [String] = []
    private var lastProposalAt: Date?
    private var token: String?
    /// Bumped by `start()` and `stop()`; callbacks from a superseded attempt see a stale value
    /// and bail (HI-002).
    private var generation = 0

    /// Bytes a single connection may buffer before being dropped (headers + body).
    private static let maxRequestBytes = 256 * 1024
    /// Largest accepted request body; proposal JSON is tiny, so this is generous (ME-001/ME-003).
    private static let maxBodyBytes = 128 * 1024

    /// 10 chars from a 32-symbol confusable-free alphabet (~50 bits) — high enough entropy for a
    /// transient LAN session while staying typeable from the on-screen URL.
    private static func makeToken() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 10)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return UUID().uuidString }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    private func setStatus(id: String, status: ChangeStatus) {
        lock.lock()
        pending[id]?.status = status
        lock.unlock()
    }

    private func attemptStart(portOffset: UInt16, generation: Int, completion: @escaping (UInt16?) -> Void) {
        guard portOffset < 10, let nwPort = NWEndpoint.Port(rawValue: 8080 + portOffset) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let candidate: NWListener
        do {
            candidate = try NWListener(using: .tcp, on: nwPort)
        } catch {
            attemptStart(portOffset: portOffset + 1, generation: generation, completion: completion)
            return
        }

        // Retain the candidate immediately (HI-002): if the user stops before it reaches `.ready`,
        // `stop()` can cancel it rather than leaving an orphan that later resurrects the server.
        lock.lock()
        guard generation == self.generation else {
            lock.unlock()
            candidate.cancel()
            return
        }
        listener = candidate
        lock.unlock()

        var resolved = false
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard !resolved else { return }
                resolved = true
                self.lock.lock()
                guard generation == self.generation else {
                    self.lock.unlock()
                    candidate.cancel()
                    return
                }
                self.port = 8080 + portOffset
                self.lock.unlock()
                DispatchQueue.main.async { completion(8080 + portOffset) }
            case .failed, .cancelled:
                guard !resolved else { return }
                resolved = true
                candidate.cancel()
                self.lock.lock()
                let superseded = generation != self.generation
                if !superseded, self.listener === candidate { self.listener = nil }
                self.lock.unlock()
                if !superseded {
                    self.attemptStart(portOffset: portOffset + 1, generation: generation, completion: completion)
                }
            default:
                break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }
        candidate.start(queue: queue)
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection: connection, buffer: Data())
    }

    private func receive(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > Self.maxRequestBytes {
                connection.cancel()
                return
            }
            switch HttpRequest.parse(buffer, maxBodyBytes: Self.maxBodyBytes) {
            case .request(let request):
                self.respond(to: request, on: connection)
            case .invalid:
                // Malformed framing (bad/negative/duplicate Content-Length, non-UTF8 head, …)
                // gets a clean 400 instead of a crash or a hung read (ME-001).
                self.send(
                    HttpResponse(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8)),
                    on: connection
                )
            case .incomplete:
                if isComplete {
                    connection.cancel()
                } else {
                    self.receive(connection: connection, buffer: buffer)
                }
            }
        }
    }

    private func send(_ response: HttpResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func respond(to request: HttpRequest, on connection: NWConnection) {
        // Every route — including the landing page — requires the session's pairing token,
        // presented either as the `?t=` query param (QR/typed URL) or the `X-Setup-Token`
        // header (the page's own API calls). Everything else gets an opaque 403 (HI-001).
        lock.lock()
        let expected = token
        lock.unlock()
        let presented = request.query["t"] ?? request.headers["x-setup-token"]
        guard let expected, let presented, presented == expected else {
            send(
                HttpResponse(status: "403 Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8)),
                on: connection
            )
            return
        }

        let response: HttpResponse
        switch (request.method, request.path) {
        case ("GET", "/"):
            response = HttpResponse(
                status: "200 OK",
                contentType: "text/html; charset=utf-8",
                body: Data(RemoteSetupWebPage.html.utf8)
            )
        case ("GET", "/api/state"):
            lock.lock()
            let body = stateJSON
            lock.unlock()
            response = HttpResponse(status: "200 OK", contentType: "application/json", body: body)
        case ("POST", "/api/apply"):
            response = handleApply(body: request.body)
        case ("GET", let path) where path.hasPrefix("/api/status/"):
            let id = String(path.dropFirst("/api/status/".count))
            lock.lock()
            let status = pending[id]?.status.rawValue ?? "not_found"
            lock.unlock()
            response = HttpResponse.json(["status": status])
        default:
            response = HttpResponse(
                status: "404 Not Found",
                contentType: "text/plain",
                body: Data("Not found".utf8)
            )
        }

        send(response, on: connection)
    }

    private func handleApply(body: Data) -> HttpResponse {
        guard let proposal = try? JSONDecoder().decode(Proposal.self, from: body) else {
            return HttpResponse.json(["error": "Invalid request body"], status: "400 Bad Request")
        }
        let change = PendingChange(proposal: proposal)
        let now = Date()
        lock.lock()
        // Simple rate limit: one proposal per second. Stops a misbehaving peer from replacing the
        // on-TV confirmation alert in a loop (ME-003).
        if let last = lastProposalAt, now.timeIntervalSince(last) < 1.0 {
            lock.unlock()
            return HttpResponse.json(["error": "Too many requests"], status: "429 Too Many Requests")
        }
        lastProposalAt = now
        // A new proposal supersedes any stale pending one (mirrors Android).
        for other in pending.values where other.status == .pending {
            other.status = .rejected
        }
        pending[change.id] = change
        pendingOrder.append(change.id)
        // Keep a small bounded history — enough for the browser's status polling of the current
        // and recently superseded proposals, without growing for the session's lifetime (ME-003).
        while pendingOrder.count > 8 {
            pending.removeValue(forKey: pendingOrder.removeFirst())
        }
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onChangeProposed?(change)
        }
        return HttpResponse.json(["status": "pending_confirmation", "id": change.id])
    }
}

// MARK: - Minimal HTTP plumbing

private enum HttpParseResult {
    /// Not enough bytes yet — caller keeps receiving.
    case incomplete
    /// Structurally malformed — caller responds 400 and closes.
    case invalid
    case request(HttpRequest)
}

private struct HttpRequest {
    let method: String
    let path: String
    /// Percent-decoded query parameters (the pairing token arrives as `?t=…`).
    let query: [String: String]
    /// Header fields, keys lowercased.
    let headers: [String: String]
    let body: Data

    static func parse(_ buffer: Data, maxBodyBytes: Int) -> HttpParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // No end-of-headers within a generous window → header flood, not a slow client.
            return buffer.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestParts = lines.first?.components(separatedBy: " ") ?? []
        guard requestParts.count >= 2 else { return .invalid }

        var headers: [String: String] = [:]
        var contentLengths: [String] = []
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if key == "content-length" { contentLengths.append(value) }
            headers[key] = value
        }

        // Exactly one well-formed, nonnegative, bounded Content-Length (or none → 0). Negative
        // values previously produced an inverted body range and crashed the app (ME-001);
        // duplicates/conflicts are request smuggling by another name.
        var contentLength = 0
        if !contentLengths.isEmpty {
            guard Set(contentLengths).count == 1,
                  let parsed = Int(contentLengths[0]),
                  parsed >= 0, parsed <= maxBodyBytes
            else { return .invalid }
            contentLength = parsed
        }

        let bodyStart = headerEnd.upperBound
        let available = buffer.count - (bodyStart - buffer.startIndex)
        if available < contentLength { return .incomplete }

        let target = requestParts[1]
        let pathAndQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(kv[0]).removingPercentEncoding, !key.isEmpty else { continue }
                let value = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }

        return .request(HttpRequest(
            method: requestParts[0].uppercased(),
            path: String(pathAndQuery[0]),
            query: query,
            headers: headers,
            body: buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
        ))
    }
}

private struct HttpResponse {
    let status: String
    let contentType: String
    let body: Data

    static func json(_ object: [String: String], status: String = "200 OK") -> HttpResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HttpResponse(status: status, contentType: "application/json", body: data)
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

// MARK: - Device IP

enum DeviceIpAddress {
    /// First non-loopback IPv4 address, preferring Wi-Fi/Ethernet interfaces (en0/en1).
    static func current() -> String? {
        var addresses: [(name: String, ip: String)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            let name = String(cString: current.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 {
                let ip = String(cString: host)
                if ip != "127.0.0.1" {
                    addresses.append((name, ip))
                }
            }
        }
        let preferred = addresses.first { $0.name.hasPrefix("en") }
        return (preferred ?? addresses.first)?.ip
    }
}
