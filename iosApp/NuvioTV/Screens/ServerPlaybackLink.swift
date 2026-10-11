import Combine
import Foundation
import SharedCore
import SwiftUI

// Jellyfin / Emby playback, as the player sees it.
//
// A server file is not a link until it is picked: `ServerPlayback.prepare` asks the server how to
// play it (the original file, or a transcode when the player or the network cannot take it) and
// opens a playback session. Everything after that is the shared `ServerPlayback`'s job: it reports
// start / pause / progress / stop to the server, and restarts the session when the viewer switches
// the audio track or a burned-in subtitle of a transcode.
//
// This file is the engine-agnostic half on the Swift side, used by BOTH engines:
//  - `ServerStreamPreparer` turns a picked server stream into a playable one (the stream picker, the
//    in-player Sources panel and the next-episode hand-off all go through it);
//  - `ServerPlaybackLink` follows one playing context: it reports the playback position, offers the
//    server's own audio / burned-in subtitle tracks through the player's shared top-panel model, and
//    falls back from a failed direct play to a transcode.

/// The outcome of preparing a server stream.
struct ServerPreparedStream {
    let stream: StreamItem
    let url: URL
    /// A position the server holds that is newer than the one saved on this device, in seconds.
    let resumePositionSec: Double?
}

enum ServerStreamPreparer {
    /// True for a Jellyfin / Emby file that still has to be prepared into a playable URL.
    static func needsPreparation(_ stream: StreamItem) -> Bool {
        stream.needsServerPreparation
    }

    /// Prepares `stream`. `savedAtEpochMs` is when the position saved on this device was last
    /// updated (0 = none), so the server's resume point only wins when it is the more recent one.
    /// The completion runs on the main queue; on failure it gets the words for the toast.
    static func prepare(_ stream: StreamItem,
                        savedAtEpochMs: Int64,
                        completion: @escaping (Result<ServerPreparedStream, ServerPrepareFailure>) -> Void) {
        ServerPlaybackBridge.shared.prepare(stream: stream, savedAtEpochMs: savedAtEpochMs) { result, _ in
            DispatchQueue.main.async {
                if let prepared = result?.stream {
                    let direct: String? = prepared.playableDirectUrl
                    if let direct, !direct.isEmpty, let url = URL(string: direct) {
                        let resume: Int64? = result?.resumePositionMs?.int64Value
                        completion(.success(ServerPreparedStream(
                            stream: prepared,
                            url: url,
                            resumePositionSec: resume.map { Double($0) / 1000 }
                        )))
                        return
                    }
                    // A session was opened for a link we cannot use: close it again.
                    ServerPlayback.shared.stop(url: direct)
                }
                let failure: ServerFailure? = result?.failure
                completion(.failure(ServerPrepareFailure(failure: failure)))
            }
        }
    }

    /// When the position saved for `videoId` was last written, for `prepare`'s resume comparison.
    static func savedProgressTimestamp(videoId: String, parentMetaId: String, season: Int?, episode: Int?) -> Int64 {
        guard let entry = WatchProgressRepository.shared.progressForVideo(
            videoId: videoId,
            parentMetaId: parentMetaId,
            seasonNumber: season.map { KotlinInt(int: Int32($0)) },
            episodeNumber: episode.map { KotlinInt(int: Int32($0)) }
        ) else { return 0 }
        return entry.lastUpdatedEpochMs
    }
}

/// Why a server stream could not be prepared, in the app's words.
struct ServerPrepareFailure: Error {
    let message: String

    init(failure: ServerFailure?) {
        guard let failure else {
            message = ServerFailureText.playbackFailed
            return
        }
        // A bare "could not connect" is wrong for a server that answered but refused to play.
        message = failure.name == "FAILED" ? ServerFailureText.playbackFailed : ServerFailureText.message(for: failure)
    }
}

/// Follows one playing context that came from a media server. Created for every `PlayerScreen`;
/// `isServer` is false (and every method a no-op) for any other source.
@MainActor
final class ServerPlaybackLink: ObservableObject {
    /// The playback URL, which is also the key of the shared playback session.
    let url: String
    let isServer: Bool

    /// The server's audio tracks of a transcode (empty for a direct play): switching restarts it.
    @Published private(set) var audioTracks: [PlayerPanelOption] = []
    /// The server's burned-in subtitle choices of a transcode: "Off" first, then each track.
    @Published private(set) var subtitleTracks: [PlayerPanelOption] = []
    /// "Direct play" / "Transcoding · Audio codec not supported", for the Stream Info.
    @Published private(set) var summary: String?
    /// A short message for the viewer (a track switch that failed); clears itself.
    @Published private(set) var notice: String?

    /// Swaps the playing context (a new URL after a track switch or a fallback). nil = this player
    /// cannot swap its own source, so the switching entries are not offered.
    private let switchContext: ((PlaybackContext) -> Void)?
    private let context: PlaybackContext
    private var lastReport = Date.distantPast
    private var lastReportedPaused: Bool?
    private var lastReportedEnded = false
    private var switching = false
    private var preferredAudioApplied = false
    private var fallbackTried = false
    private var stopped = false
    private var noticeTask: Task<Void, Never>?
    /// The playhead as the engines last reported it (a track switch restarts from here).
    private var lastPositionSec: Double = 0

    init(context: PlaybackContext, switchContext: ((PlaybackContext) -> Void)?) {
        self.context = context
        self.url = context.url.absoluteString
        self.switchContext = switchContext
        self.isServer = ServerPlayback.shared.isServerSource(url: context.url.absoluteString)
        guard isServer else { return }
        refresh()
    }

    /// Re-reads the session's tracks and play method. The session never changes under one link (a
    /// restart is a new context), so this runs once at creation.
    private func refresh() {
        let current = url
        if switchContext != nil {
            let audio: [ServerTrack] = ServerPlayback.shared.audioTracks(url: current)
            audioTracks = audio.map { PlayerPanelOption(id: "server-audio-\($0.index)", title: $0.label,
                                                        language: $0.language, group: .audio, isSelected: $0.selected) }
            let subtitles: [ServerTrack] = ServerPlayback.shared.burnInSubtitles(url: current)
            if !subtitles.isEmpty {
                let anySelected = subtitles.contains { $0.selected }
                subtitleTracks = [PlayerPanelOption(id: "off", title: String(localized: "Off"), group: .off,
                                                    isSelected: !anySelected)]
                    + subtitles.map { PlayerPanelOption(id: "server-subtitle-\($0.index)", title: $0.label,
                                                        language: $0.language, group: .embedded, isSelected: $0.selected) }
            }
        }
        summary = Self.summary(for: current)
    }

    private static func summary(for url: String) -> String? {
        guard let method = ServerPlaybackBridge.shared.playMethod(url: url) else { return nil }
        let label: String
        switch method {
        case "DIRECT_PLAY": label = String(localized: "Direct play")
        case "DIRECT_STREAM": label = String(localized: "Direct stream")
        default: label = String(localized: "Transcoding")
        }
        let reasons: [String] = ServerPlaybackBridge.shared.transcodeReasons(url: url)
        return reasons.isEmpty ? label : "\(label) \u{00B7} \(reasons.joined(separator: ", "))"
    }

    // MARK: - Reporting

    /// A playback tick from either engine. The shared session turns snapshots into the server's
    /// start / pause / resume / progress / stop reports; this only throttles and de-duplicates.
    func report(positionSec: Double, isPaused: Bool, isBuffering: Bool, isEnded: Bool) {
        guard isServer, !stopped, positionSec.isFinite else { return }
        lastPositionSec = positionSec
        let now = Date()
        let changed = lastReportedPaused != isPaused || lastReportedEnded != isEnded
        guard changed || now.timeIntervalSince(lastReport) >= 1 else { return }
        lastReport = now
        lastReportedPaused = isPaused
        lastReportedEnded = isEnded
        ServerPlayback.shared.onPlaybackSnapshot(
            url: url,
            positionMs: Int64(max(positionSec, 0) * 1000),
            isPlaying: !isPaused,
            isLoading: isBuffering,
            isEnded: isEnded
        )
    }

    /// The player is gone (or the source was replaced): the server gets its stop report.
    func stop() {
        guard isServer, !stopped else { return }
        stopped = true
        ServerPlayback.shared.stop(url: url)
    }

    // MARK: - Track switching (transcodes)

    /// Binds the server's tracks to the shared top-panel model both engines draw their transport
    /// menus from. The entries only exist for a transcode that can restart (`switchContext`).
    func bind(to model: PlayerTopPanelModel) {
        guard isServer else { return }
        model.serverAudio = audioTracks
        model.serverSubtitles = subtitleTracks
        model.onSelectServerAudio = { [weak self] option in self?.selectAudio(option) }
        model.onSelectServerSubtitle = { [weak self] option in self?.selectSubtitle(option) }
        applyPreferredAudio()
    }

    /// The viewer's audio language preference (Settings > Playback, or the track picked earlier for
    /// this show) for a transcode that started on the server's default track: restarts it once on
    /// the matching track. A track the viewer picked here is remembered first in those targets, so the
    /// restart this causes finds its preference already satisfied and stops there.
    private func applyPreferredAudio() {
        guard !preferredAudioApplied, switchContext != nil, !switching else { return }
        preferredAudioApplied = true
        let tracks: [ServerTrack] = ServerPlayback.shared.audioTracks(url: url)
        guard tracks.count > 1 else { return }
        PlayerSettingsRepository.shared.ensureLoaded()
        guard let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState else { return }
        let targets = PlayerAudioLanguagePlan.audioTargets(
            settings: settings, context: context,
            persisted: PlayerSubtitleMemory.load(parentMetaId: context.parentMetaId))
        let candidates = tracks.map { track -> (id: Int, lang: String, title: String, selected: Bool) in
            let language: String? = track.language
            return (id: Int(track.index), lang: language ?? "", title: track.label, selected: track.selected)
        }
        guard let wanted = PlayerAudioLanguagePlan.trackToForce(targets: targets, tracks: candidates) else { return }
        restart(failure: ServerFailureText.audioSwitchFailed) { current, completion in
            ServerPlayback.shared.switchAudio(url: current, audioStreamIndex: Int32(wanted)) { session, _ in completion(session) }
        }
    }

    private func selectAudio(_ option: PlayerPanelOption) {
        guard let index = Self.trackIndex(of: option, prefix: "server-audio-"), !switching else { return }
        // Remembered for this show, like a pick in either engine's own audio menu (LANG-09).
        let language: String? = audioTracks.first { $0.id == option.id }?.language
        PlayerSubtitleMemory.saveAudio(
            parentMetaId: context.parentMetaId, language: language, name: option.title,
            trackId: String(index), keeping: PlayerSubtitleMemory.load(parentMetaId: context.parentMetaId))
        restart(failure: ServerFailureText.audioSwitchFailed) { current, completion in
            ServerPlayback.shared.switchAudio(url: current, audioStreamIndex: index) { session, _ in completion(session) }
        }
    }

    private func selectSubtitle(_ option: PlayerPanelOption?) {
        guard !switching else { return }
        if let option, let index = Self.trackIndex(of: option, prefix: "server-subtitle-") {
            restart(failure: ServerFailureText.subtitleSwitchFailed) { current, completion in
                ServerPlayback.shared.switchSubtitle(url: current, subtitleStreamIndex: KotlinInt(int: index)) { session, _ in
                    completion(session)
                }
            }
        } else {
            restart(failure: ServerFailureText.subtitleSwitchFailed) { current, completion in
                ServerPlayback.shared.switchSubtitle(url: current, subtitleStreamIndex: nil) { session, _ in completion(session) }
            }
        }
    }

    private static func trackIndex(of option: PlayerPanelOption, prefix: String) -> Int32? {
        guard option.id.hasPrefix(prefix) else { return nil }
        return Int32(option.id.dropFirst(prefix.count))
    }

    /// Restarts the transcode with another track, from where it is now.
    private func restart(failure: String,
                         _ request: (_ url: String, _ completion: @escaping (ServerPlaybackSession?) -> Void) -> Void) {
        guard switchContext != nil, !stopped else { return }
        switching = true
        let startSec: Double? = lastPositionSec > 1 ? lastPositionSec : context.startPositionSec
        request(url) { [weak self] session in
            DispatchQueue.main.async {
                guard let self else { return }
                self.switching = false
                guard let session else {
                    self.show(notice: failure)
                    return
                }
                self.swap(to: session, startSec: startSec)
            }
        }
    }

    // MARK: - Fallback

    /// A direct play the player could not open: asks the server for a transcode instead and swaps
    /// the context. Once per link; false when there is nothing to fall back to (a transcode already,
    /// a server without transcoding) so the caller shows its own error.
    @discardableResult
    func fallBackToTranscode(positionSec: Double, ifUnavailable: @escaping () -> Void) -> Bool {
        guard isServer, !stopped, !fallbackTried, !switching, switchContext != nil,
              ServerPlaybackBridge.shared.canFallBack(url: url) else { return false }
        fallbackTried = true
        switching = true
        let startSec = max(positionSec, 0)
        ServerPlayback.shared.fallback(url: url) { [weak self] session, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.switching = false
                guard let session else {
                    // Nothing to fall back to: the caller carries on with its own error handling.
                    ifUnavailable()
                    return
                }
                self.swap(to: session, startSec: startSec)
            }
        }
        return true
    }

    // MARK: - Notice

    private func show(notice message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - Context swap

    private func swap(to session: ServerPlaybackSession, startSec: Double?) {
        guard let switchContext, let next = URL(string: session.url) else { return }
        stopped = true      // the shared side already closed the old session when it opened this one
        let sessionHeaders: [String: String] = session.headers
        let headers = StreamModelsKt.sanitizePlaybackHeaders(headers: sessionHeaders)
        let subtitles: [StreamSubtitle] = session.subtitles
        let swapped = PlaybackContext(
            url: next,
            title: context.title,
            contentType: context.contentType,
            parentMetaId: context.parentMetaId,
            videoId: context.videoId,
            season: context.season,
            episode: context.episode,
            poster: context.poster,
            background: context.background,
            providerName: context.providerName,
            providerAddonId: context.providerAddonId,
            streamTitle: context.streamTitle,
            streamSubtitle: context.streamSubtitle,
            externalSubtitles: subtitles.map { sub in
                SubtitleFile(url: sub.url, language: sub.language, name: { let n: String? = sub.name; return n }())
            },
            bingeGroup: context.bingeGroup,
            episodes: context.episodes,
            synopsis: context.synopsis,
            episodeStill: context.episodeStill,
            meta: context.meta,
            fileSizeBytes: context.fileSizeBytes,
            requestHeaders: headers,
            startPositionSec: startSec.flatMap { $0 > 1 ? $0 : nil },
            seriesTitle: context.seriesTitle,
            episodeTitle: context.episodeTitle,
            logo: context.logo
        )
        switchContext(swapped)
    }
}

/// A short, non-focusable message over the player ("Couldn’t switch the audio track."). The player
/// chrome is the one place Liquid Glass belongs, so it wears the shared functional glass (which falls
/// back to an opaque surface under Reduce Transparency), in a capsule that clears the safe area.
struct ServerNoticeBanner: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Theme.Font.meta)
            .foregroundStyle(Theme.Palette.textPrimary)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .functionalGlass(in: Capsule())
            .padding(.top, Theme.Spacing.screen)
            .accessibilityAddTraits(.isStaticText)
    }
}
