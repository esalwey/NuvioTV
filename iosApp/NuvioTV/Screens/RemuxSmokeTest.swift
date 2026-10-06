#if DEBUG
import AVFoundation
import Foundation
import SharedCore

// DEBUG-only headless harness for the native playback path. When the UserDefaults key
// `debug.remuxSmokeURL` holds a source URL, it drives a real `NativePlaybackCoordinator` (the exact
// orchestration the dispatcher's native branch runs) and logs when it reaches `playing` with the
// AVPlayer item ready — validating remux → progressive serve → AVPlayer end to end without any UI.
// See docs/tvos-hybrid-player-plan.md.
//
// Trigger (simulator):
//   xcrun simctl spawn <dev> defaults write com.nuvio.media.NuvioTV debug.remuxSmokeURL -string '<url>'
//   xcrun simctl launch --console-pty <dev> com.nuvio.media.NuvioTV
nonisolated enum RemuxSmokeTest {
    @MainActor private static var coordinator: NativePlaybackCoordinator?

    static func runIfRequested() {
        startProbeLoopIfRequested()
        guard let raw = UserDefaults.standard.string(forKey: "debug.remuxSmokeURL"),
              let url = URL(string: raw) else { return }
        Task { @MainActor in
            // debug.remuxSmokeDelaySec: hold the harness so app bootstrap (addon init/refresh)
            // completes first — needed when the run should exercise the addon-subtitle fetch.
            let delaySec = UserDefaults.standard.double(forKey: "debug.remuxSmokeDelaySec")
            if delaySec > 0 {
                print("[RemuxSmoke] delaying start by \(delaySec)s")
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            }
            // A real-videoId run exercises the addon-subtitle fetch; headless, nothing reaches the
            // Home screen, so kick the addon bootstrap the UI would normally have done by now.
            if UserDefaults.standard.string(forKey: "debug.remuxSmokeVideoId") != nil {
                AddonRepository.shared.initialize()
            }
            print("[RemuxSmoke] start — \(raw)")
            // Log what the probe + router would decide for this source (the harness itself drives
            // the coordinator directly, bypassing PlayerScreen's routing) — surfaces DV profile,
            // P7 MEL/FEL classification and the chosen engine for the file under test.
            Task.detached(priority: .utility) {
                let probe = MediaProbe.probe(url: url, timeoutSec: 8)
                let decision = PlayerEngineRouter.route(probe: probe, nativeDVEnabled: true)
                let dv = probe?.dolbyVision.map {
                    "P\($0.profile) elKind=\($0.elKind?.rawValue ?? "-") el=\($0.elPresent) compat=\($0.compatId)"
                } ?? "none"
                print("[RemuxSmoke] probe: DV=\(dv) videoStreams=\(probe?.videoStreamCount ?? -1)"
                      + " → router: \(decision.engine.rawValue) (\(decision.reason))")
            }
            // Unique videoId per launch so a stored watch position from a previous smoke run can't
            // trigger a surprise resume-seek mid-test.
            // debug.remuxSmokeSubURL: inject an external subtitle (D5) so the sim run exercises the
            // WebVTT rendition path — master EXT-X-MEDIA, sub playlist, JIT download + conversion.
            let smokeSubs: [SubtitleFile] = UserDefaults.standard.string(forKey: "debug.remuxSmokeSubURL")
                .map { [SubtitleFile(url: $0, language: "en", name: "Smoke Sub")] } ?? []
            // debug.remuxSmokeVideoId / debug.remuxSmokeType: use a real catalog id ("tt0111161",
            // "movie") so the run exercises the addon-subtitle fetch against installed addons.
            let smokeVideoId = UserDefaults.standard.string(forKey: "debug.remuxSmokeVideoId")
                ?? "smoke-\(Int(Date().timeIntervalSince1970))"
            let smokeType = UserDefaults.standard.string(forKey: "debug.remuxSmokeType") ?? "movie"
            let context = PlaybackContext(
                url: url, title: "Smoke Test", contentType: smokeType,
                parentMetaId: "smoke", videoId: smokeVideoId,
                season: nil, episode: nil, poster: nil, background: nil,
                providerName: nil, providerAddonId: nil,
                streamTitle: nil, streamSubtitle: nil, externalSubtitles: smokeSubs
            )
            let coordinator = NativePlaybackCoordinator(context: context)
            self.coordinator = coordinator
            coordinator.start()
            observe(coordinator, attempt: 0)
            scheduleAudioSwitchIfRequested(coordinator)
        }
    }

    /// debug.remuxSmokeAudioSwitchSec=N (float): N seconds after playback is up (re-armed while
    /// still preparing), log the audible media-selection options and switch to the first alternate
    /// (info-panel W3: an AVPlayer rendition switch — the remux flips its produced track when the
    /// new rendition's files are requested; no item rebuild). Logs whether the selection stuck,
    /// position continuity, and the remux's active track.
    @MainActor
    private static func scheduleAudioSwitchIfRequested(_ coordinator: NativePlaybackCoordinator, retries: Int = 40) {
        let delay = UserDefaults.standard.double(forKey: "debug.remuxSmokeAudioSwitchSec")
        guard delay > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak coordinator] in
            guard let coordinator else { return }
            guard coordinator.phase == .playing, coordinator.lastPositionSec > 0.5,
                  let player = coordinator.player, let item = player.currentItem else {
                if retries > 0 {          // still preparing/buffering — try again shortly
                    scheduleAudioSwitchIfRequested(coordinator, retries: retries - 1)
                } else {
                    print("[RemuxSmoke] audio switch: playback never became ready — not exercised")
                }
                return
            }
            let tracks = coordinator.audioTracks
            print("[RemuxSmoke] audio tracks: " + (tracks.isEmpty ? "none" : tracks.map {
                "#\($0.streamIndex)\($0.selected ? "*" : "")=\($0.name)\($0.playable ? "" : " (unplayable)")"
            }.joined(separator: " | ")))
            Task { @MainActor in
                guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible), group.options.count > 1 else {
                    print("[RemuxSmoke] no alternate audible option — switch not exercised")
                    return
                }
                let current = item.currentMediaSelection.selectedMediaOption(in: group)
                guard let alt = group.options.first(where: { $0 != current }) else { return }
                let before = CMTimeGetSeconds(player.currentTime())
                print("[RemuxSmoke] SWITCHING AUDIO → \(alt.displayName) at pos \(String(format: "%.1f", before))s")
                item.select(alt, in: group)
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                let after = CMTimeGetSeconds(player.currentTime())
                let stuck = item.currentMediaSelection.selectedMediaOption(in: group) == alt
                let active = coordinator.audioTracks.first(where: \.selected)
                print("[RemuxSmoke] audio switch result: selected=\(stuck) pos \(String(format: "%.1f→%.1f", before, after))"
                      + " rate=\(player.rate) status=\(item.status.rawValue) remuxActive=\(active.map { "#\($0.streamIndex) \($0.name)" } ?? "?")")
            }
        }
    }

    @MainActor
    private static func observe(_ coordinator: NativePlaybackCoordinator, attempt: Int) {
        switch coordinator.phase {
        case .playing:
            let status = coordinator.player?.currentItem?.status
            if status == .readyToPlay {
                let secs = coordinator.player?.currentItem.map { CMTimeGetSeconds($0.duration) } ?? .nan
                let text = secs.isFinite ? String(format: "%.1fs", secs) : "live"
                print("[RemuxSmoke] coordinator playing + AVPlayer readyToPlay \u{2705} duration=\(text)")
                // D5 assertion: the asset should expose a legible media-selection group when
                // external subtitles were injected. Select the first option so the VTT actually
                // downloads/converts and any rendition failure surfaces in the [HLS] log.
                if let item = coordinator.player?.currentItem {
                    Task {
                        let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
                        let names = group?.options.map(\.displayName) ?? []
                        print("[RemuxSmoke] legible options: \(names.count)\(names.isEmpty ? "" : " — \(names.joined(separator: ", "))")")
                        if let group, let first = group.options.first {
                            await MainActor.run {
                                item.select(first, in: group)
                                // Cue sink: proves the selected rendition's VTT parses + time-maps
                                // (embedded per-segment files included). First 6 cues logged.
                                let output = AVPlayerItemLegibleOutput()
                                output.setDelegate(smokeCueSink, queue: .main)
                                item.add(output)
                                smokeLegibleOutput = output
                            }
                            print("[RemuxSmoke] selected subtitle: \(first.displayName)")
                        }
                    }
                }
                // debug.remuxSmokeSeekTo="30,120,60": scrub mid-play to exercise the seek-anywhere
                // reposition path — comma-separated targets fired 12s apart (far-forward, then
                // backward-into-hole, etc., against a throttled source).
                if let spec = UserDefaults.standard.string(forKey: "debug.remuxSmokeSeekTo") {
                    let targets = spec.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    for (i, target) in targets.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4 + Double(i) * 12) { [weak coordinator] in
                            guard let player = coordinator?.player else { return }
                            print("[RemuxSmoke] SEEKING to \(target)s")
                            player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { done in
                                print("[RemuxSmoke] seek completed=\(done) pos=\(String(format: "%.1f", CMTimeGetSeconds(player.currentTime())))")
                            }
                        }
                    }
                }
                samplePlayback(coordinator, sample: 0)
            } else if attempt < 160 {   // throttled sources ready slowly (~40s ceiling)
                schedule(coordinator, attempt: attempt + 1)
            } else {
                print("[RemuxSmoke] playing but item not ready (status=\(String(describing: status)))")
            }
        case .failed(let stage):
            print("[RemuxSmoke] coordinator FAILED \u{274C} — \(stage)")
        case .preparing:
            if attempt < 200 {
                schedule(coordinator, attempt: attempt + 1)
            } else {
                print("[RemuxSmoke] still preparing after timeout")
            }
        }
    }

    /// Logs the first few cues AVPlayer renders for the smoke run's selected subtitle.
    final class SmokeCueSink: NSObject, AVPlayerItemLegibleOutputPushDelegate {
        var seen = 0
        /// The subtitle-delay spike (B3) needs the whole cue stream, not a sample, to see whether a
        /// delay change actually moved the cue times AVFoundation reports.
        private lazy var limit = UserDefaults.standard.string(forKey: "debug.subDelaySpike") == nil ? 6 : Int.max
        func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                           didOutputAttributedStrings strings: [NSAttributedString],
                           nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
            let text = strings.map(\.string).joined(separator: "|")
            guard !text.isEmpty, seen < limit else { return }
            seen += 1
            print("[RemuxSmoke] cue @\(String(format: "%.1f", CMTimeGetSeconds(itemTime)))s \"\(text)\"")
        }
    }
    @MainActor private static let smokeCueSink = SmokeCueSink()
    @MainActor private static var smokeLegibleOutput: AVPlayerItemLegibleOutput?

    @MainActor
    private static func schedule(_ coordinator: NativePlaybackCoordinator, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            observe(coordinator, attempt: attempt)
        }
    }

    // MARK: - Remote-controlled AVPlayer probe loop

    /// When `debug.avplayerProbeURL` holds a URL (typically a playlist served by a dev Mac on the
    /// LAN), probe it with a fresh AVPlayer every ~20s and POST each verdict to `<host>:<port>/report`
    /// on the same server. Lets playlist/media variants be A/B-tested against THIS device's actual
    /// AVFoundation without touching the app flow or relaying console output by hand: the Mac swaps
    /// what the URL serves between rounds and watches the reports arrive.
    @MainActor private static var probePlayer: AVPlayer?

    private static func startProbeLoopIfRequested() {
        guard let raw = UserDefaults.standard.string(forKey: "debug.avplayerProbeURL"),
              let base = URL(string: raw) else { return }
        print("[ProbeLoop] starting against \(raw)")
        Task { @MainActor in
            // Fresh AVPlayer(playerItem:) per round — empirically a single reused AVPlayer fails to
            // load MULTIVARIANT (master) playlists (-12927) while direct media plays. The slow
            // cadence below is what prevents decoder-session exhaustion.
            var round = 0
            while true {
                round += 1
                var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
                comps.queryItems = [URLQueryItem(name: "round", value: String(round))]   // cache-bust
                let item = AVPlayerItem(url: comps.url!)
                let player = AVPlayer(playerItem: item)
                player.isMuted = true
                probePlayer = player
                player.play()

                var verdict = "TIMEOUT(unknown)"
                for _ in 0..<60 {                                    // ≤15s per round
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if item.status == .readyToPlay {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        let pos = CMTimeGetSeconds(player.currentTime())
                        verdict = "READY pos=\(String(format: "%.1f", pos))"
                        // debug.avplayerProbeSelections=1: also exercise media selection on the
                        // probed master — list the audible/legible groups, switch to the alternate
                        // audio rendition, select the first subtitle, and log the cues that arrive.
                        // Used by the info-panel W0 spike (demuxed audio + segmented WebVTT).
                        if UserDefaults.standard.bool(forKey: "debug.avplayerProbeSelections") {
                            verdict += " " + (await exerciseSelections(player: player, item: item))
                        }
                        break
                    }
                    if item.status == .failed {
                        let err = item.error.map { "\(($0 as NSError).domain)#\(($0 as NSError).code)" } ?? "?"
                        let logs = (item.errorLog()?.events ?? [])
                            .map { "\($0.errorStatusCode):\($0.errorComment ?? "")" }.joined(separator: "; ")
                        verdict = "FAILED \(err) [\(logs)]"
                        break
                    }
                }
                player.pause()
                player.replaceCurrentItem(with: nil)
                probePlayer = nil
                print("[ProbeLoop] round \(round): \(verdict)")
                report(base: base, message: "round=\(round) \(verdict)")
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
        }
    }

    /// Media-selection exercise for the probe loop (see `debug.avplayerProbeSelections`). Returns a
    /// compact verdict fragment; details go to the console as `[ProbeLoop]` lines.
    @MainActor
    private static func exerciseSelections(player: AVPlayer, item: AVPlayerItem) async -> String {
        var parts: [String] = []
        let asset = item.asset
        let audible = (try? await asset.loadMediaSelectionGroup(for: .audible)) ?? nil
        let legible = (try? await asset.loadMediaSelectionGroup(for: .legible)) ?? nil
        func describe(_ g: AVMediaSelectionGroup?) -> String {
            guard let g else { return "none" }
            return g.options.map { "\($0.displayName)[\($0.extendedLanguageTag ?? "-")]" }.joined(separator: ", ")
        }
        print("[ProbeLoop] audible options: \(describe(audible))")
        print("[ProbeLoop] legible options: \(describe(legible))")
        parts.append("aud=\(audible?.options.count ?? 0) leg=\(legible?.options.count ?? 0)")

        // Cue sink: any legible output proves the WebVTT segments parse + time-map correctly.
        final class CueSink: NSObject, AVPlayerItemLegibleOutputPushDelegate {
            var seen: [String] = []
            func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                               didOutputAttributedStrings strings: [NSAttributedString],
                               nativeSampleBuffers: [Any], forItemTime itemTime: CMTime) {
                let text = strings.map(\.string).joined(separator: "|")
                guard !text.isEmpty else { return }
                let line = "\(String(format: "%.1f", CMTimeGetSeconds(itemTime)))s \"\(text)\""
                seen.append(line)
                print("[ProbeLoop] cue @\(line)")
            }
        }
        let sink = CueSink()
        let output = AVPlayerItemLegibleOutput()
        output.setDelegate(sink, queue: .main)
        item.add(output)

        if let legible, let first = legible.options.first {
            item.select(first, in: legible)
            print("[ProbeLoop] selected subtitle: \(first.displayName)")
        }
        // Switch to the alternate audio rendition; a demuxed master switches without an item
        // replacement — position must keep advancing and the selection must stick.
        if let audible, audible.options.count > 1 {
            let current = item.currentMediaSelection.selectedMediaOption(in: audible)
            if let alt = audible.options.first(where: { $0 != current }) {
                let before = CMTimeGetSeconds(player.currentTime())
                item.select(alt, in: audible)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                let after = CMTimeGetSeconds(player.currentTime())
                let now = item.currentMediaSelection.selectedMediaOption(in: audible)
                let stuck = now == alt
                print("[ProbeLoop] audio switch → \(alt.displayName): selected=\(stuck) pos \(String(format: "%.1f→%.1f", before, after)) rate=\(player.rate) status=\(item.status.rawValue)")
                parts.append("switch=\(stuck ? "ok" : "lost") adv=\(String(format: "%.1f", after - before))")
            }
        }
        // Let cues accumulate a little longer, then summarize.
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        parts.append("cues=\(sink.seen.count)")
        item.remove(output)
        return parts.joined(separator: " ")
    }

    private static func report(base: URL, message: String) {
        guard let host = base.host else { return }
        let port = base.port.map { ":\($0)" } ?? ""
        guard let url = URL(string: "http://\(host)\(port)/report") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = Data(message.utf8)
        URLSession.shared.dataTask(with: req).resume()
    }

    /// After ready: sample position/rate every 2s so stalls (e.g. live-edge waiting on a growing
    /// playlist) are visible in the console.
    @MainActor
    private static func samplePlayback(_ coordinator: NativePlaybackCoordinator, sample: Int) {
        guard sample < 30, let player = coordinator.player, let item = player.currentItem else { return }
        let pos = CMTimeGetSeconds(player.currentTime())
        let dur = CMTimeGetSeconds(item.duration)
        let control: String
        switch player.timeControlStatus {
        case .playing: control = "playing"
        case .paused: control = "paused"
        case .waitingToPlayAtSpecifiedRate:
            control = "waiting(\(player.reasonForWaitingToPlay?.rawValue ?? "?"))"
        @unknown default: control = "?"
        }
        let durText = dur.isFinite ? String(format: "%.1f", dur) : "live"
        print("[RemuxSmoke] t=\(sample * 2)s pos=\(String(format: "%.1f", pos)) dur=\(durText) \(control) bufferEmpty=\(item.isPlaybackBufferEmpty) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            samplePlayback(coordinator, sample: sample + 1)
        }
    }
}
#endif
