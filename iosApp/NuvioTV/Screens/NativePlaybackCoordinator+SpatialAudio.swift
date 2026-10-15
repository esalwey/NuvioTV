import AVFoundation
import Foundation
import SpatialAudioPlayback

// Spatial audio on the native engine: TrueHD Atmos and DTS:X tracks play as Dolby Atmos (APAC 7.1.4).
//
// The flow, in order:
//   1. `pollForFirstSegment`, as soon as the remux publishes its segment map, calls `beginSpatialStart`.
//      For the track the viewer starts on (the remux's selected track) it opens the source with
//      SpatialAudioBridge's Matroska reader and converts the first segment, in parallel with the
//      remux's own first segment. Success means the converter can render the track (it verifies Atmos /
//      DTS:X only when it decodes); a plain TrueHD or DTS-HD MA track, a non-Matroska file or a
//      server without range requests throws, and the track keeps its standard audio.
//   2. `beginPlayback` waits for that answer (at most `spatialStartWaitSec`), then renders the master
//      once: a converted track is an APAC rendition (`apac.31.03`, 12 channels) served by
//      `LocalHLSServer` from the `SpatialRendition`, on its own 3.2 s grid; every other track is
//      what it always was. Other tracks announced as Atmos / DTS:X get a rendition that converts on
//      its first request.
//   3. `attachAtmosActivator` keeps Apple TV's HDMI output in Dolby Atmos (SpatialAudioPlayback's
//      silent Atmos stream) while the selected audio is an APAC rendition. Without it the receiver
//      stays on PCM: APAC alone never switched it (SpatialAudioBridge docs, atmos-output.md).
//   4. When a rendition fails for good, or converts slower than real time, `reloadWithoutSpatialAudio`
//      serves that track the standard way (the remux produces it as it always did) and reloads the
//      item at the same position with the viewer's audio pick restored.
// The remux keeps producing the viewer's selected audio track whatever happens here, TrueHD included,
// so the standard rendition of a spatial track is always ready to take over: that duplicate decode
// is the status quo cost of the TrueHD / DTS track (a few percent of one core) and the reason a
// spatial failure never needs more than a reload.

extension NativePlaybackCoordinator {

    /// How long startup waits for the APAC check of the first track before it plays the standard audio.
    /// The library measured 1.8 to 2.4 s to open a file and convert its first segment on Apple TV 4K.
    static let spatialStartWaitSec: TimeInterval = 12
    /// A conversion is judged on a run of at least this many segments (the first two carry the start-up)...
    static let spatialMinimumSegments = 8
    /// ...and is too slow below this many seconds of audio per second of work (SpatialAudioBridge: below
    /// about 1.2 playback stalls; the strikes below keep one slow burst after a seek from counting).
    static let spatialMinimumSpeed = 1.2

    // MARK: - Names and renditions

    /// The Audio menu name of a track: a converted one is named for what it plays as.
    func audioDisplayName(for track: RemuxAudioTrack) -> String {
        Self.audioTrackDisplayName(track, spatial: spatialKinds[track.streamIndex])
    }

    /// The master's audio renditions: every playable track, the one the remux starts on DEFAULT. A
    /// converted track is an APAC rendition (12 channels, `apac.31.03`); everything else as ever.
    func makeAudioRenditions(remux: RemuxSession) -> [AudioRendition] {
        var audioNames = Set<String>()
        return remux.audioTracks.filter(\.playable).map { track -> AudioRendition in
            // NAME must be unique within the group (two untitled tracks with the same language,
            // codec and layout otherwise collide) — suffix duplicates.
            let base = audioDisplayName(for: track)
            var name = base, n = 2
            while !audioNames.insert(name).inserted { name = "\(base) \(n)"; n += 1 }
            let spatial = spatialKinds[track.streamIndex] != nil
            // LANGUAGE in BCP 47 form (LANG-07): "fre" → "fr", so AVPlayer's criteria and the
            // system Audio popover read it.
            return AudioRendition(streamIndex: track.streamIndex, name: name,
                                  // With the variant the title states (LANG-10): a "fre" track
                                  // titled "VFQ" is "fr-CA", so the criteria tell the dubs apart.
                                  language: TrackLabelFormatter.trackLanguageTag(language: track.language,
                                                                                 title: track.title) ?? track.language,
                                  channels: spatial ? SpatialAudioPolicy.apacChannelCount : track.channels,
                                  codecToken: spatial ? SpatialAudioPolicy.apacCodecToken : track.codecToken,
                                  isDefault: track.selected,
                                  isSpatial: spatial)
        }
    }

    /// The renditions the server converts on demand: the session's, for the tracks that play as APAC.
    func spatialRenditionsForServer() -> [Int: SpatialRendition] {
        guard let session = spatialSession else { return [:] }
        return session.allRenditions.filter { spatialKinds[$0.key] != nil }
    }

    // MARK: - Start

    /// Starts the conversion check of the track the viewer starts on, or else of the first track
    /// announced as Atmos / DTS:X. No-op when Spatial Audio is off, the device cannot output Atmos, or
    /// no track is TrueHD / lossless-capable DTS.
    func beginSpatialStart(remux: RemuxSession, map: SegmentMap) {
        guard spatialOutcome == .idle else { return }
        guard SpatialAudioPolicy.isEnabled else {
            spatialOutcome = .unavailable
            return
        }
        let tracks = remux.audioTracks
        guard let initial = SpatialAudioPolicy.startTrack(in: tracks),
              let originSec = remux.timelineOriginSec else {
            spatialOutcome = .unavailable
            return
        }
        spatialOutcome = .pending
        spatialStartedAt = Date()
        let url = context.url
        let headers = context.requestHeaders
        // The video segment the item opens on (AVPlayer asks the audio for the same stretch): the one
        // holding the resume point, else the first.
        let resumeSec = plannedResumeSec ?? explicitStartSec ?? 0
        var startSec = 0.0
        for segment in map.segments {
            if startSec + segment.durationSec > resumeSec { break }
            startSec += segment.durationSec
        }
        let began = Date()
        spatialStartTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Off the main thread, all of it: the Matroska header and cue reads, the decode and the APAC
            // encode of the first segment. (The audio session was prepared when the remux started.)
            var started: SpatialAudioSession?
            var failure: String?
            do {
                started = try await SpatialAudioSession.start(
                    url: url, headers: headers, tracks: tracks, initialStream: initial.streamIndex,
                    map: map, originSec: originSec, startSec: startSec)
            } catch {
                failure = String(describing: error)
            }
            let session = started
            let reason = failure
            let elapsed = Date().timeIntervalSince(began)
            if Task.isCancelled {
                await session?.stop()
                return
            }
            await MainActor.run {
                self?.finishSpatialStart(session, failure: reason, startupSec: elapsed, initial: initial)
            }
        }
    }

    /// The check of the first track answered.
    func finishSpatialStart(_ session: SpatialAudioSession?, failure: String?, startupSec: Double,
                            initial: RemuxAudioTrack) {
        spatialStartTask = nil
        guard spatialOutcome == .pending, phase == .preparing else {
            // Playback ended, or gave up waiting, while the conversion ran.
            if let session { Task { await session.stop() } }
            return
        }
        guard let session else {
            spatialOutcome = .unavailable
            print("[NativePlayer] spatial audio not used for stream \(initial.streamIndex) (\(initial.codec)): \(failure ?? "unknown")")
            return
        }
        spatialSession = session
        let renditions = session.allRenditions
        spatialKinds = renditions.mapValues { $0.kind }
        spatialOutcome = .ready
        NativePlaybackMetrics.shared.noteSpatialStart(renditions: renditions.count, startupSec: startupSec)
        session.setFailureHandler { [weak self] stream, reason in
            Task { @MainActor [weak self] in self?.abandonSpatialAudio(stream: stream, reason: reason) }
        }
        print("[NativePlayer] spatial audio ready in \(String(format: "%.1f", startupSec))s: "
              + renditions.keys.sorted().map { "stream \($0) \(spatialKinds[$0]?.sourceName ?? "?")" }.joined(separator: ", "))
    }

    /// Whether `beginPlayback` still has to wait for the APAC check. Gives up (standard audio) once the
    /// wait is over: a slow link must not hold the viewer on the loading screen for the sake of the audio format.
    func spatialStartIsPending() -> Bool {
        guard spatialOutcome == .pending else { return false }
        if Date().timeIntervalSince(spatialStartedAt ?? Date()) < Self.spatialStartWaitSec { return true }
        print("[NativePlayer] spatial audio check still running after \(Int(Self.spatialStartWaitSec)) s — standard audio")
        spatialOutcome = .unavailable
        spatialStartTask?.cancel()
        spatialStartTask = nil
        return false
    }

    // MARK: - Dolby Atmos output

    /// Keeps the Atmos output on while the audio that plays is an APAC rendition (SpatialAudioPlayback's
    /// silent Atmos stream, looped beside the item). A no-op without spatial renditions.
    func attachAtmosActivator(to player: AVPlayer) {
        guard !spatialKinds.isEmpty else { return }
        let activator = atmosActivator ?? AtmosOutputActivator()
        atmosActivator = activator
        // The activator re-evaluates when the item or its audio selection changes and when playback
        // starts or pauses; the silent stream is unloaded whenever an item plays other audio, since
        // leaving it loaded made direct Dolby Digital Plus playback stutter.
        activator.attach(to: player) { [weak self] item in
            self?.isSpatialAudioSelected(in: item) ?? false
        }
    }

    /// Whether the audio the item plays is an APAC rendition. Reads the item's audible selection when
    /// the group has loaded, else assumes the master's default (what AVPlayer opens on).
    func isSpatialAudioSelected(in item: AVPlayerItem) -> Bool {
        guard !spatialKinds.isEmpty else { return false }
        guard let group = audibleGroup,
              let option = item.currentMediaSelection.selectedMediaOption(in: group),
              let stream = Self.renditionStream(for: option, byName: audioRenditionsByName,
                                                tracks: remux?.audioTracks ?? []) else {
            return defaultAudioIsSpatial
        }
        return spatialKinds[stream] != nil
    }

    /// The avformat stream index of the audio the viewer hears: AVPlayer's selection when it has
    /// loaded, else the one relayed to the server.
    func currentAudioStreamIndex() -> Int? {
        if let option = currentAudioOption,
           let stream = Self.renditionStream(for: option, byName: audioRenditionsByName,
                                             tracks: remux?.audioTracks ?? []) {
            return stream
        }
        return selectedAudioBox.value
    }

    // MARK: - Stream Info

    /// The "Audio format" row: what reaches the TV for the audio that plays now.
    func deliveredAudioDescription() -> String? {
        guard let tracks = remux?.audioTracks, !tracks.isEmpty else { return nil }
        let stream = currentAudioStreamIndex()
        guard let track = tracks.first(where: { $0.streamIndex == stream }) ?? tracks.first(where: \.selected) else {
            return nil
        }
        if let kind = spatialKinds[track.streamIndex] {
            return SpatialAudioPolicy.deliveredDescription(for: kind)
        }
        return AudioTranscoder.deliveredFormatDescription(codec: track.codec, channels: track.channels,
                                                          transcodes: track.transcodes,
                                                          lossless: track.losslessOutput)
    }

    // MARK: - Health and fallback

    /// Called on the 3 s playback tick: a conversion that cannot keep up with real time stalls playback
    /// (and would never recover), so after three slow checks in a row the track plays the standard way.
    func checkSpatialAudioHealth() {
        if !spatialKinds.isEmpty { spatialSession?.notePosition(lastPositionSec) }
        guard !spatialKinds.isEmpty, let stream = currentAudioStreamIndex(), spatialKinds[stream] != nil,
              let progress = NativePlaybackMetrics.shared.spatialSpeed else {
            spatialSlowStrikes = 0
            return
        }
        if progress.segments >= Self.spatialMinimumSegments, progress.speed < Self.spatialMinimumSpeed {
            spatialSlowStrikes += 1
        } else {
            spatialSlowStrikes = 0
        }
        if spatialSlowStrikes >= 3 {
            abandonSpatialAudio(stream: stream,
                                reason: String(format: "conversion too slow (%.2fx realtime)", progress.speed))
        }
    }

    /// A spatial rendition failed for good (the converter rejected metadata partway, the source dropped,
    /// the encoder stopped) or cannot keep up: serve that track the standard way from now on.
    func abandonSpatialAudio(stream: Int, reason: String) {
        guard spatialKinds[stream] != nil else { return }
        print("[NativePlayer] spatial audio abandoned for stream \(stream): \(reason)")
        reloadWithoutSpatialAudio(streams: [stream], reason: reason)
    }

    /// Plays `streams` the standard way: the master and the rendition playlists follow, the conversion
    /// stops, and a playing item is replaced by a fresh one at the same position (AVPlayer keeps the
    /// playlists, and the APAC init segment, of the item it has loaded). Returns true when an item was
    /// reloaded. The remux has been producing the viewer's selected track all along (see the header).
    @discardableResult
    func reloadWithoutSpatialAudio(streams: [Int], reason: String) -> Bool {
        let dropped = streams.filter { spatialKinds[$0] != nil }
        guard !dropped.isEmpty else { return false }
        NativePlaybackMetrics.shared.noteSpatialFallback("stream \(dropped.map(String.init).joined(separator: ",")): \(reason)")
        // The viewer's current pick, to put back on the new item.
        let selected = currentAudioStreamIndex()
        for stream in dropped { spatialKinds[stream] = nil }
        spatialSlowStrikes = 0
        if let remux {
            let renditions = makeAudioRenditions(remux: remux)
            audioRenditionsByName = Dictionary(uniqueKeysWithValues: renditions.map { ($0.name, $0.streamIndex) })
            server?.setAudio(renditions: renditions, spatial: spatialRenditionsForServer())
            defaultAudioIsSpatial = remux.audioTracks.first(where: \.selected).map { spatialKinds[$0.streamIndex] != nil } ?? false
            rebuildAudioTracks()
        }
        if let session = spatialSession {
            Task { for stream in dropped { await session.remove(stream: stream) } }
        }
        guard phase == .playing, let player, let servedURL else { return false }
        // Reload: a new URL (the server ignores the query), so AVPlayer fetches the master again.
        itemReloads += 1
        let position = CMTimeGetSeconds(player.currentTime())
        // A viewer who had paused stays paused on the new item.
        let wasPaused = hasStartedPlaying && player.timeControlStatus == .paused
        if position.isFinite, position > 1 {
            // Playback had started: resume where it was. An item that never became ready keeps the
            // resume point it was planned with. The media playlists open the new item there
            // (EXT-X-START), so the remux repositions once instead of once for the old resume point
            // and again for the seek.
            explicitStartSec = position
            plannedResumeSec = nil
            server?.setStartOffset(position)
        }
        resumePausedAfterReload = wasPaused
        pendingAudioRestoreStream = selected
        observeTask?.cancel()
        let url = URL(string: servedURL.absoluteString + "?s=\(itemReloads)") ?? servedURL
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 24
        prepareItem(item)
        playerItem = item
        legibleGroup = nil
        audibleGroup = nil            // per-item groups; the new item gets its own observers
        didRelayInitialAudio = false
        print("[NativePlayer] reloading the item without spatial audio (\(reason))"
              + (explicitStartSec.map { String(format: " at %.1fs", $0) } ?? ""))
        player.replaceCurrentItem(with: item)
        observeMediaSelection(item: item, player: player)
        observePlayback(player: player, item: item)
        return true
    }

    /// Selects the viewer's audio again on a reloaded item (AVPlayer opens it on its own pick).
    func restorePendingAudioSelection(item: AVPlayerItem, group: AVMediaSelectionGroup) {
        guard let stream = pendingAudioRestoreStream else { return }
        pendingAudioRestoreStream = nil
        let tracks = remux?.audioTracks ?? []
        guard let option = group.options.first(where: {
            Self.renditionStream(for: $0, byName: audioRenditionsByName, tracks: tracks) == stream
        }), item.currentMediaSelection.selectedMediaOption(in: group) != option else { return }
        item.select(option, in: group)
        selectionVersion &+= 1
        print("[NativePlayer] audio: restored stream \(stream) after the reload")
    }

    // MARK: - Teardown

    /// Ends the silent Atmos stream and the conversion with the playback they served.
    func tearDownSpatialAudio() {
        spatialStartTask?.cancel()
        spatialStartTask = nil
        atmosActivator?.detach()
        atmosActivator = nil
        let session = spatialSession
        spatialSession = nil
        spatialKinds = [:]
        spatialOutcome = .idle
        if let session { Task { await session.stop() } }
    }
}
