import Foundation
import Network

// Phase 2/4 of the hybrid player: a loopback HTTP/1.1 server that feeds AVPlayer the owned segmenter's
// output. It SYNTHESIZES a complete VOD playlist up front from the `SegmentMap` (every segment, exact
// EXTINF, EXT-X-ENDLIST) — required because tvOS 27 rejects EVENT/growing playlists — and serves the
// `seg-NNNNN.m4s` files JUST-IN-TIME: a request for a segment the remux hasn't produced yet blocks
// (async, no thread held) until the file appears, up to a bounded timeout. Binds 127.0.0.1 only, on a
// random-token path prefix, so nothing off-device can read the stream. GET + HEAD, byte ranges (206).
// The NWListener pattern mirrors RemoteSetupServer.swift. See docs/tvos-hybrid-player-plan.md.

/// One-shot flag; `fire()` returns true exactly once. Lets a @Sendable closure resolve without
/// mutating a captured `var` (a Swift 6 concurrency error).
private nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if fired { return false }; fired = true; return true }
}

/// Per-connection liveness flag, flipped when the connection reaches a terminal state, so a JIT block
/// stops polling as soon as the client abandons the request. Read/written from the concurrent conn
/// queue, hence the lock.
private nonisolated final class ConnLive: @unchecked Sendable {
    private let lock = NSLock()
    private var _alive = true
    var alive: Bool { lock.lock(); defer { lock.unlock() }; return _alive }
    func kill() { lock.lock(); _alive = false; lock.unlock() }
}

nonisolated final class LocalHLSServer: @unchecked Sendable {
    private let rootDir: URL
    /// Per-session path token; every request must be `/{token}/{file}`.
    let token: String
    private let listenerQueue = DispatchQueue(label: "media.nuvio.hls-listener")
    /// Concurrent so a segment request that blocks waiting for the remux can't starve the parallel
    /// requests AVPlayer issues (playlist refetch, init, the next segment). Blocking is done by async
    /// re-scheduling (never a held thread), so no connection stalls another.
    private let connQueue = DispatchQueue(label: "media.nuvio.hls-conn", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var _port: UInt16?

    // Synthesized-VOD configuration.
    private let map: SegmentMap
    /// Master-playlist signaling; mutable so the coordinator can retry with reduced signaling when a
    /// strict AVPlayer rejects the full DV form at the master stage.
    private var _signaling: VideoSignaling
    /// Audio renditions of the master's `aud` group (info-panel W3): every playable source track,
    /// each an audio-only representation produced only while it is the remux's active track.
    private let audioRenditions: [AudioRendition]
    /// The track whose files the remux is producing right now (its stream index).
    private let activeAudio: @Sendable () -> Int
    /// The track AVPlayer's audible media selection currently names (nil = unknown). Only requests
    /// for THIS track may switch the worker — a lingering request for the previous rendition, or
    /// alternate probing, must not flip production back and forth.
    private let selectedAudio: @Sendable () -> Int?
    /// Ask the remux to produce another track's rendition, restarting at the given segment (nil =
    /// where it is). Fired once by the first request for a non-active track's file.
    private let requestAudioTrack: @Sendable (Int, Int?) -> Void
    private let bandwidth: Int
    /// External-subtitle renditions (D5): each is an EXT-X-MEDIA SUBTITLES entry; the VTT payloads
    /// download + convert just-in-time on first request and are cached here for the session.
    private let subtitles: [SubtitleRendition]
    /// Per-rendition AUTOSELECT/DEFAULT (parallel to `subtitles`; empty = legacy flags).
    private let subtitleFlags: [SubtitleRenditionFlags]
    /// Settings → Playback → Strip SDH Subtitles: addon/sidecar files run through the shared
    /// `SubtitleSdhFilter` as they are converted to VTT (SDH stripping, native path — the mpv path
    /// sets `sub-filter-sdh` instead). Sampled at session start; converted VTTs are cached, so a
    /// mid-playback toggle flip applies from the next playback session.
    private let stripSdh: Bool
    /// Converted addon VTT at offset zero, cached per rendition index. Delay variants are shifted
    /// from this base on demand (cheap — a few thousand timing lines).
    private var vttBase = [Int: String]()
    private var vttFailed = Set<Int>()
    /// Subtitle delay in milliseconds, applied to the addon VTT bodies this server renders.
    private var _subtitleDelayMs = 0
    /// Bumped on every delay change; the media playlist names `sub-N-g<gen>.vtt`, so a refetched
    /// playlist always points at a URL AVPlayer has never seen.
    private var _subtitleGeneration = 0
    /// How many interchangeable EXT-X-MEDIA slots each subtitle rendition is published under. >1
    /// lets the coordinator force AVPlayer to load a rendition URI it has never fetched (the
    /// re-timing mechanism); 1 = classic single-entry behaviour. Set before `start()`.
    private var _subtitleSlots = 1
    let masterName = "master.m3u8"
    let mediaName = "media.m3u8"

    // JIT serve tuning.
    /// Max time to block a not-yet-produced segment. CoreMedia KILLS a variant after ~6s of silence on
    /// a media request (-12889 "No response for media file in 6s" → -12880 "can not proceed after
    /// removing variants", fatal for our single variant) — so we must ALWAYS respond inside that
    /// window: hold up to ~5s (worst-case tick lands ≈5.1s, still safely inside on loopback), then 503
    /// (retryable). 5s rather than 4s so an exactly-realtime source whose next segment needs ~4s of
    /// production is served in-block instead of paying a deterministic 503 round-trip per segment.
    /// A reposition needing ~8-10s spans two hold/503/retry cycles; AVPlayer's retries re-enter the
    /// JIT wait with a fresh budget each time.
    private let blockTimeout: TimeInterval = 5
    /// How many segments past the current producing position a request is still worth polling for
    /// (production reaches it within the JIT budget; covers AVPlayer's capped forward buffer).
    /// Anything else — far forward seek OR a backward seek into an unproduced hole — repositions the
    /// remux. Mirrors RemuxSession.repositionMargin.
    private let blockMargin = 6

    /// (producing, pending) window from the remux worker — the JIT poll-vs-reposition decision input.
    private let producingInfo: @Sendable () -> (producing: Int, pending: Int?)
    /// Ask the remux to jump production to a segment (seek-anywhere).
    private let requestReposition: @Sendable (Int) -> Void
    /// Resume offset published as `EXT-X-START` in the media playlists (PLY-A5): AVPlayer starts the
    /// item at the resume segment the remux was repositioned to, instead of fetching segment 1.
    /// nil = start at zero.
    private let startOffsetSec: Double?

    var port: UInt16? { lock.lock(); defer { lock.unlock() }; return _port }

    init(rootDir: URL, map: SegmentMap, signaling: VideoSignaling,
         audioRenditions: [AudioRendition] = [],
         activeAudio: @escaping @Sendable () -> Int = { -1 },
         selectedAudio: @escaping @Sendable () -> Int? = { nil },
         requestAudioTrack: @escaping @Sendable (Int, Int?) -> Void = { _, _ in },
         bandwidth: Int,
         subtitles: [SubtitleRendition] = [],
         subtitleFlags: [SubtitleRenditionFlags] = [],
         stripSdh: Bool = false,
         producingInfo: @escaping @Sendable () -> (producing: Int, pending: Int?),
         requestReposition: @escaping @Sendable (Int) -> Void,
         startOffsetSec: Double? = nil) {
        self.rootDir = rootDir
        self.map = map
        self._signaling = signaling
        self.audioRenditions = audioRenditions
        self.activeAudio = activeAudio
        self.selectedAudio = selectedAudio
        self.requestAudioTrack = requestAudioTrack
        self.bandwidth = bandwidth
        self.subtitles = subtitles
        self.subtitleFlags = subtitleFlags
        self.stripSdh = stripSdh
        self.producingInfo = producingInfo
        self.requestReposition = requestReposition
        self.startOffsetSec = startOffsetSec
        self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Swap the master-playlist signaling (used for the minimal-signaling retry).
    func setSignaling(_ signaling: VideoSignaling) {
        lock.lock(); _signaling = signaling; lock.unlock()
    }

    // MARK: - Subtitle delay (native-engine re-timing)

    /// Publish each subtitle rendition under `slots` interchangeable EXT-X-MEDIA entries. Must be
    /// called before `start()` — the master is rendered from this on every fetch, but AVPlayer only
    /// fetches it once.
    func setSubtitleSlots(_ slots: Int) {
        lock.lock(); _subtitleSlots = max(1, slots); lock.unlock()
    }

    /// Set the subtitle delay in milliseconds and return the generation token that now names the
    /// VTT bodies. Positive = subtitles appear LATER.
    @discardableResult
    func setSubtitleDelay(ms: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard ms != _subtitleDelayMs else { return _subtitleGeneration }
        _subtitleDelayMs = ms
        _subtitleGeneration += 1
        return _subtitleGeneration
    }

    var subtitleDelayMs: Int { lock.lock(); defer { lock.unlock() }; return _subtitleDelayMs }
    var subtitleGeneration: Int { lock.lock(); defer { lock.unlock() }; return _subtitleGeneration }

    /// `sub-<index>-g<generation>.vtt` — the delay-stamped body name a media playlist points at.
    static func delayedVTTName(index: Int, generation: Int) -> String { "sub-\(index)-g\(generation).vtt" }

    /// Parse `sub-<index>.vtt` or `sub-<index>-g<generation>.vtt`.
    static func parseSubtitleVTTName(_ name: String) -> (index: Int, generation: Int)? {
        guard name.hasPrefix("sub-"), name.hasSuffix(".vtt") else { return nil }
        let core = name.dropFirst(4).dropLast(4)
        let parts = core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1, let index = Int(parts[0]) { return (index, 0) }
        guard parts.count == 2, let index = Int(parts[0]),
              parts[1].hasPrefix("g"), let generation = Int(parts[1].dropFirst()) else { return nil }
        return (index, generation)
    }

    /// `sub-<index>.m3u8` (slot 0) or `sub-<index>-s<slot>.m3u8`.
    static func parseSubtitlePlaylistName(_ name: String) -> (index: Int, slot: Int)? {
        guard name.hasPrefix("sub-"), name.hasSuffix(".m3u8") else { return nil }
        let core = name.dropFirst(4).dropLast(5)
        let parts = core.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1, let index = Int(parts[0]) { return (index, 0) }
        guard parts.count == 2, let index = Int(parts[0]),
              parts[1].hasPrefix("s"), let slot = Int(parts[1].dropFirst()) else { return nil }
        return (index, slot)
    }

    /// Slot `k`'s playlist name for a rendition whose slot-0 name is `sub-<index>.m3u8`.
    static func slotPlaylistName(index: Int, slot: Int) -> String {
        slot == 0 ? "sub-\(index).m3u8" : "sub-\(index)-s\(slot).m3u8"
    }

    /// Duplicate every SUBTITLES EXT-X-MEDIA line of a rendered master into `slots` entries. Slot 0
    /// keeps the original NAME and flags; the extra slots are never auto-selected and carry a
    /// slot-suffixed NAME (AVPlayer keys options by NAME, so they must stay unique). The panel and
    /// the coordinator strip the suffix again; the SYSTEM subtitle popover shows them, which is the
    /// known cosmetic cost of this mechanism.
    private static func expandSubtitleSlots(_ master: String, slots: Int) -> String {
        guard slots > 1 else { return master }
        var out: [String] = []
        for line in master.components(separatedBy: "\n") {
            guard line.hasPrefix("#EXT-X-MEDIA:TYPE=SUBTITLES"),
                  let uriRange = line.range(of: "URI=\""),
                  let uriEnd = line.range(of: "\"", range: uriRange.upperBound..<line.endIndex),
                  let parsed = parseSubtitlePlaylistName(String(line[uriRange.upperBound..<uriEnd.lowerBound])),
                  let nameRange = line.range(of: "NAME=\""),
                  let nameEnd = line.range(of: "\"", range: nameRange.upperBound..<line.endIndex) else {
                out.append(line)
                continue
            }
            out.append(line)
            let name = String(line[nameRange.upperBound..<nameEnd.lowerBound])
            for slot in 1..<slots {
                var twin = line
                twin.replaceSubrange(uriRange.upperBound..<uriEnd.lowerBound,
                                     with: slotPlaylistName(index: parsed.index, slot: slot))
                // Recompute the NAME range on the mutated string before substituting.
                if let r = twin.range(of: "NAME=\""), let e = twin.range(of: "\"", range: r.upperBound..<twin.endIndex) {
                    twin.replaceSubrange(r.upperBound..<e.lowerBound, with: "\(name)\(slotNameSuffix)\(slot)")
                }
                twin = twin.replacingOccurrences(of: "DEFAULT=YES", with: "DEFAULT=NO")
                    .replacingOccurrences(of: "AUTOSELECT=YES", with: "AUTOSELECT=NO")
                out.append(twin)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Separator between a rendition NAME and its slot number in the master's twin entries.
    static let slotNameSuffix = " \u{2007}#"

    /// The master playlist exactly as a client would receive it right now (for failure diagnostics).
    func renderedMasterPlaylist() -> String? { renderedPlaylist(named: masterName) }

    /// A synthesized playlist exactly as a client would receive it right now (for failure diagnostics).
    func renderedPlaylist(named name: String) -> String? {
        switch name {
        case masterName:
            lock.lock(); let signaling = _signaling; let slots = _subtitleSlots; lock.unlock()
            let master = map.masterPlaylist(signaling: signaling, audioRenditions: audioRenditions,
                                            bandwidth: bandwidth, mediaName: mediaName, subtitles: subtitles,
                                            subtitleFlags: subtitleFlags)
            return Self.expandSubtitleSlots(master, slots: slots)
        case mediaName:
            return map.mediaPlaylist(startOffsetSec: startOffsetSec)
        default:
            // aud-T.m3u8 — an audio rendition: same segment grid as the video playlist, its own
            // init map and segment names.
            if let audio = audioRenditions.first(where: { $0.playlistName == name }) {
                return map.mediaPlaylist(initName: audio.initName, segmentPrefix: audio.segmentPrefix,
                                         startOffsetSec: startOffsetSec)
            }
            // sub-N-sK.m3u8 — a delay slot's twin of sub-N.m3u8; same content, same rendition.
            let slotted = Self.parseSubtitlePlaylistName(name)
            guard let rendition = subtitles.first(where: {
                $0.playlistName == name || (!$0.isEmbedded && $0.index == slotted?.index)
            }) else { return nil }
            // esub-K.m3u8 — embedded track: one WebVTT file per video segment (same boundaries and
            // EXTINFs as media.m3u8, no init map), produced by the remux worker as it goes.
            if case .embedded(let sink) = rendition.source {
                return map.embeddedSubtitlePlaylist { SubtitleRendition.embeddedSegmentName(sink: sink, segment: $0) }
            }
            // sub-N.m3u8 / sub-N-sK.m3u8 — addon file: a one-segment VOD playlist covering the whole
            // timeline (cue times are playlist times; no X-TIMESTAMP-MAP needed at origin zero).
            // The body name carries the current delay GENERATION, so a freshly fetched playlist
            // always names a URL AVPlayer has not cached.
            let total = map.totalDurationSec
            lock.lock(); let generation = _subtitleGeneration; lock.unlock()
            let body = generation == 0
                ? rendition.fileName
                : Self.delayedVTTName(index: rendition.index, generation: generation)
            return [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-TARGETDURATION:\(Int(total.rounded(.up)))",
                "#EXT-X-PLAYLIST-TYPE:VOD",
                String(format: "#EXTINF:%.3f,", total),
                body,
                "#EXT-X-ENDLIST",
            ].joined(separator: "\n") + "\n"
        }
    }

    /// Start listening on loopback and return the URL of the master playlist, or nil if no port could
    /// be bound. `completion` runs on the main queue.
    func start(masterName: String, completion: @escaping (URL?) -> Void) {
        lock.lock()
        guard listener == nil else {
            let existing = _port.map { url(port: $0, path: self.masterName) }
            lock.unlock()
            DispatchQueue.main.async { completion(existing) }
            return
        }
        lock.unlock()
        attemptStart(portOffset: 0, completion: completion)
    }

    func stop() {
        lock.lock()
        let active = listener
        listener = nil
        _port = nil
        lock.unlock()
        active?.cancel()
    }

    /// `http://127.0.0.1:{port}/{token}/{path}`
    func url(port: UInt16, path: String) -> URL {
        URL(string: "http://127.0.0.1:\(port)/\(token)/\(path)")!
    }

    // MARK: - Listener

    private func attemptStart(portOffset: UInt16, completion: @escaping (URL?) -> Void) {
        guard portOffset < 20, let nwPort = NWEndpoint.Port(rawValue: 8190 + portOffset) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // Loopback-only bind: nothing outside the device can reach the remuxed stream.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        let candidate: NWListener
        do {
            candidate = try NWListener(using: params)
        } catch {
            attemptStart(portOffset: portOffset + 1, completion: completion)
            return
        }

        lock.lock(); listener = candidate; lock.unlock()

        // Fires exactly once (ready OR failed), guarded so the @Sendable listener callback can't
        // race a second resolution — Swift 6 forbids mutating a captured `var` here.
        let resolved = OnceFlag()
        candidate.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard resolved.fire() else { return }
                let boundPort = 8190 + portOffset
                self.lock.lock(); self._port = boundPort; self.lock.unlock()
                DispatchQueue.main.async { completion(self.url(port: boundPort, path: self.masterName)) }
            case .failed, .cancelled:
                guard resolved.fire() else { return }
                candidate.cancel()
                self.lock.lock()
                let isCurrent = self.listener === candidate
                if isCurrent { self.listener = nil }
                self.lock.unlock()
                // Only a genuine bind failure re-attempts the next port. A deliberate stop() sets
                // listener=nil and cancels us — rebinding then would resurrect a stopped server.
                guard isCurrent else { return }
                self.attemptStart(portOffset: portOffset + 1, completion: completion)
            default:
                break
            }
        }
        candidate.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            // Per-connection liveness: a JIT block that outlives an abandoned request (AVPlayer cancels
            // a prefetch, or the item is torn down) should stop polling immediately, not run its full
            // timeout. The connection's terminal states flip this.
            let live = ConnLive()
            connection.stateUpdateHandler = { state in
                switch state {
                case .cancelled, .failed: live.kill()
                default: break
                }
            }
            connection.start(queue: self.connQueue)
            self.receive(connection: connection, buffer: Data(), live: live)
        }
        candidate.start(queue: listenerQueue)
    }

    // MARK: - Request handling (GET / HEAD)

    private static let maxHeaderBytes = 32 * 1024

    private func receive(connection: NWConnection, buffer: Data, live: ConnLive) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > Self.maxHeaderBytes { connection.cancel(); return }

            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel() } else { self.receive(connection: connection, buffer: buffer, live: live) }
                return
            }
            guard let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
                self.send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad request".utf8), on: connection)
                return
            }
            self.handle(head: head, on: connection, live: live)
        }
    }

    private func handle(head: String, on connection: NWConnection, live: ConnLive) {
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ").map(String.init) ?? []
        let method = requestLine.first?.uppercased() ?? ""
        guard requestLine.count >= 2, method == "GET" || method == "HEAD" else {
            send(status: "405 Method Not Allowed", contentType: "text/plain", body: Data("GET/HEAD only".utf8), on: connection)
            return
        }
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "range" {
                rangeHeader = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let path = requestLine[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? requestLine[1]
        serveFile(path: path, rangeHeader: rangeHeader, isHead: method == "HEAD", on: connection, live: live)
    }

    private func serveFile(path: String, rangeHeader: String?, isHead: Bool, on connection: NWConnection, live: ConnLive) {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard comps.count == 2, comps[0] == token else {
            send(status: "403 Forbidden", contentType: "text/plain", body: Data("Forbidden".utf8), on: connection)
            return
        }
        let name = comps[1]
        guard !name.isEmpty, !name.contains(".."), !name.contains("/") else {
            send(status: "400 Bad Request", contentType: "text/plain", body: Data("Bad path".utf8), on: connection)
            return
        }

        // Synthesized VOD playlists — generated from the SegmentMap, never files on disk. Complete and
        // ENDLIST-terminated from the first fetch so tvOS 27 treats the stream as VOD.
        if name.hasSuffix(".m3u8") {
            guard let text = renderedPlaylist(named: name) else {
                send(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8), on: connection, requestPath: name)
                return
            }
            send(status: "200 OK", contentType: Self.contentType(for: name), body: Data(text.utf8), on: connection,
                 extraHeaders: ["Accept-Ranges": "bytes"], requestPath: name, isHead: isHead)
            return
        }

        // sub-N.vtt — external subtitle, downloaded + converted on first request. (esub-K-NNNNN.vtt,
        // an embedded track's per-segment file, is produced by the remux like a video segment and
        // falls through to the JIT path below.)
        if name.hasSuffix(".vtt"), SubtitleRendition.parseEmbeddedSegmentName(name) == nil {
            serveSubtitle(name: name, rangeHeader: rangeHeader, isHead: isHead, on: connection)
            return
        }

        // init.mp4 / seg-NNNNN.m4s / esub-K-NNNNN.vtt / aud-T-init.mp4 / aud-T-NNNNN.m4s — produced
        // just-in-time by the remux; block until present. A file of a NON-active audio track makes
        // the remux switch tracks (info-panel W3) — AVPlayer only requests a rendition's files once
        // the viewer picked it, so the request IS the switch signal (W0 spike).
        // Only the SELECTED track (AVPlayer's audible media selection, relayed by the coordinator)
        // may switch production; a stale request for another rendition just waits out the JIT
        // window (and 503s), so overlapping old/new requests can't ping-pong the worker.
        if let audio = RemuxAudioTrack.parseFileName(name), audio.track != activeAudio(),
           selectedAudio() == audio.track,
           !FileManager.default.fileExists(atPath: rootDir.appendingPathComponent(name).path) {
            requestAudioTrack(audio.track, audio.segment)
            serveSegmentJIT(name: name, rangeHeader: rangeHeader, isHead: isHead, on: connection,
                            deadline: Date().addingTimeInterval(blockTimeout), mode: .repositioned, live: live)
            return
        }
        serveSegmentJIT(name: name, rangeHeader: rangeHeader, isHead: isHead, on: connection,
                        deadline: Date().addingTimeInterval(blockTimeout), mode: nil, live: live)
    }

    /// Serve a subtitle rendition: cached VTT if present, else download the addon file, convert
    /// SRT→WebVTT and cache. Failures 404 — a missing subtitle track must never disturb playback
    /// (AVPlayer keeps playing; the menu entry just doesn't render cues).
    private func serveSubtitle(name: String, rangeHeader: String?, isHead: Bool, on connection: NWConnection) {
        guard let index = Self.parseSubtitleVTTName(name)?.index,
              let rendition = subtitles.first(where: { !$0.isEmbedded && $0.index == index }),
              let sourceURL = rendition.sourceURL else {
            send(status: "404 Not Found", contentType: "text/plain", body: Data("Not found".utf8),
                 on: connection, requestPath: name)
            return
        }
        lock.lock()
        let cached = vttBase[rendition.index]
        let failed = vttFailed.contains(rendition.index)
        // ALWAYS the current delay, whatever generation the requesting playlist named: AVPlayer
        // caches a rendition's media playlist for the life of the item but re-fetches the VTT body
        // on every (re)selection, so the body request is the one place the new timing can land.
        // (Measured on the simulator — see the B3 report.)
        let offsetMs = _subtitleDelayMs
        lock.unlock()
        if let cached {
            let shifted = offsetMs == 0 ? cached : SubtitleVTT.shift(cached, offsetMs: offsetMs)
            serveBytes(Data(shifted.utf8), name: name, rangeHeader: rangeHeader, isHead: isHead, on: connection)
            return
        }
        if failed {
            send(status: "404 Not Found", contentType: "text/plain", body: Data("Unavailable".utf8),
                 on: connection, requestPath: name)
            return
        }

        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { connection.cancel(); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let vtt = (200..<300).contains(status) ? data.flatMap { SubtitleVTT.webVTT(from: $0, stripSdh: self.stripSdh) } : nil
            if let vtt {
                // Re-read the delay AFTER the (up to 10 s) download: the user may have adjusted
                // it while the fetch was in flight, and the captured offsetMs would serve the
                // freshly selected subtitle with stale timing (Codex, final branch review).
                self.lock.lock()
                self.vttBase[rendition.index] = vtt
                let currentOffsetMs = self._subtitleDelayMs
                self.lock.unlock()
                let shifted = currentOffsetMs == 0 ? vtt : SubtitleVTT.shift(vtt, offsetMs: currentOffsetMs)
                let body = Data(shifted.utf8)
                print("[HLS] subtitle \(rendition.index) ready (\(body.count)b, \(rendition.name), delay \(currentOffsetMs)ms)")
                self.serveBytes(body, name: name, rangeHeader: rangeHeader, isHead: isHead, on: connection)
            } else {
                self.lock.lock(); self.vttFailed.insert(rendition.index); self.lock.unlock()
                print("[HLS] subtitle \(rendition.index) failed (http \(status), \(sourceURL.host ?? "?"))")
                self.send(status: "404 Not Found", contentType: "text/plain", body: Data("Unavailable".utf8),
                          on: connection, requestPath: name)
            }
        }.resume()
    }

    /// How a JIT request decided to wait, fixed on FIRST evaluation. A `.poll` request (in-window when
    /// it arrived) must NEVER fire a reposition later — a stale pre-seek poll seeing the window move
    /// would otherwise yank production back and ping-pong against the new seek target (observed live:
    /// seg-2's poll repositioning 21→2→21). Only a request that was OUT of window on arrival
    /// repositions, exactly once.
    private enum JITMode { case poll, repositioned }

    /// Serve a media file if it exists; otherwise wait (async re-scheduling, no thread held) up to
    /// `deadline`, then 503 — ALWAYS answering inside CoreMedia's ~6s no-response window. A request
    /// outside the producing window on arrival — far forward seek OR backward seek into an unproduced
    /// hole — repositions the remux once and waits; a `.poll` request whose window moves away fast-503s
    /// (a newer seek won). Past the last segment → 404; abandoned connection → stop immediately.
    private func serveSegmentJIT(name: String, rangeHeader: String?, isHead: Bool,
                                 on connection: NWConnection, deadline: Date,
                                 mode: JITMode?, live: ConnLive) {
        guard live.alive else { connection.cancel(); return }   // client gave up mid-block
        let fileURL = rootDir.appendingPathComponent(name)
        if let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) {
            serveBytes(data, name: name, rangeHeader: rangeHeader, isHead: isHead, on: connection)
            return
        }

        var mode = mode
        if let idx = Self.segmentIndex(name) {
            if idx < 1 || idx > map.count {
                send(status: "404 Not Found", contentType: "text/plain", body: Data("Out of range".utf8),
                     on: connection, requestPath: name)
                return
            }
            let (producing, pending) = producingInfo()
            let effective = pending ?? producing
            let inWindow = idx >= effective && idx <= effective + blockMargin
            switch (mode, inWindow) {
            case (nil, true):
                mode = .poll
            case (nil, false):
                requestReposition(idx)
                mode = .repositioned
            case (.poll, false), (.repositioned, false):
                // The window moved away from this request (a newer seek won) — pending == idx implies
                // inWindow (effective == idx), so reaching this arm already means production is headed
                // elsewhere. Fail fast: if AVPlayer still wants this segment its retry arrives as a
                // fresh request and re-decides (including a fresh reposition).
                send(status: "503 Service Unavailable", contentType: "text/plain",
                     body: Data("Superseded".utf8), on: connection,
                     extraHeaders: ["Retry-After": "1"], requestPath: name)
                return
            default:
                break
            }
        }

        if Date() >= deadline {
            send(status: "503 Service Unavailable", contentType: "text/plain", body: Data("Remux timeout".utf8),
                 on: connection, extraHeaders: ["Retry-After": "1"], requestPath: name)
            return
        }
        connQueue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.serveSegmentJIT(name: name, rangeHeader: rangeHeader, isHead: isHead,
                                  on: connection, deadline: deadline, mode: mode, live: live)
        }
    }

    private func serveBytes(_ data: Data, name: String, rangeHeader: String?, isHead: Bool, on connection: NWConnection) {
        let ctype = Self.contentType(for: name)
        if let rangeHeader, let (start, end) = Self.parseRange(rangeHeader, total: data.count) {
            send(status: "206 Partial Content", contentType: ctype, body: data.subdata(in: start..<(end + 1)),
                 on: connection, extraHeaders: [
                    "Content-Range": "bytes \(start)-\(end)/\(data.count)",
                    "Accept-Ranges": "bytes",
                 ], requestPath: name, isHead: isHead)
        } else {
            send(status: "200 OK", contentType: ctype, body: data, on: connection,
                 extraHeaders: ["Accept-Ranges": "bytes"], requestPath: name, isHead: isHead)
        }
    }

    /// Parse the 1-based segment index from `seg-NNNNN.m4s`, `esub-K-NNNNN.vtt` or `aud-T-NNNNN.m4s`,
    /// or nil for init segments / anything else.
    static func segmentIndex(_ name: String) -> Int? {
        if let embedded = SubtitleRendition.parseEmbeddedSegmentName(name) { return embedded.segment }
        if let audio = RemuxAudioTrack.parseFileName(name) { return audio.segment }
        guard name.hasPrefix("seg-"), name.hasSuffix(".m4s") else { return nil }
        return Int(name.dropFirst(4).dropLast(4))
    }

    // MARK: - Response

    private func send(status: String, contentType: String, body: Data, on connection: NWConnection,
                      extraHeaders: [String: String] = [:], requestPath: String? = nil, isHead: Bool = false) {
        #if DEBUG
        // Request log: shows exactly what AVPlayer fetched (and where it stopped) during device runs.
        if let requestPath { print("[HLS] \(status.prefix(3)) \(isHead ? "HEAD " : "")\(requestPath) (\(body.count)b)") }
        #endif
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        // Send the header and body as two ordered sends (NWConnection preserves order) rather than
        // concatenating — that keeps the (memory-mapped) segment body from being copied into a second
        // full-size buffer, which on concurrent large-segment serves is a real transient-memory spike.
        let headData = Data(head.utf8)
        if isHead || body.isEmpty {
            connection.send(content: headData, completion: .contentProcessed { _ in connection.cancel() })
        } else {
            connection.send(content: headData, completion: .contentProcessed { _ in })
            connection.send(content: body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func contentType(for name: String) -> String {
        if name.hasSuffix(".m3u8") { return "application/vnd.apple.mpegurl" }
        if name.hasSuffix(".mp4") { return "video/mp4" }
        if name.hasSuffix(".m4s") { return "video/iso.segment" }
        if name.hasSuffix(".vtt") { return "text/vtt" }
        return "application/octet-stream"
    }

    /// Parse a single `bytes=start-end` / `bytes=start-` / `bytes=-suffix` range against `total`.
    private static func parseRange(_ header: String, total: Int) -> (Int, Int)? {
        guard total > 0, let eq = header.firstIndex(of: "="),
              header[..<eq].trimmingCharacters(in: .whitespaces).lowercased() == "bytes" else { return nil }
        let spec = header[header.index(after: eq)...].split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        let start: Int, end: Int
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
            start = max(0, total - suffix); end = total - 1
        } else {
            guard let s = Int(parts[0]) else { return nil }
            start = s
            end = parts[1].isEmpty ? total - 1 : min(Int(parts[1]) ?? (total - 1), total - 1)
        }
        guard start >= 0, start <= end, start < total else { return nil }
        return (start, end)
    }
}
