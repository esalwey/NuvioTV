import Foundation
import SharedCore

/// Infuse's x-callback-url return trip (upstream 99ced26a4, ported Swift-side for tvOS). The hand-off
/// names `x-success` / `x-error` addresses on the app's own scheme
/// (`nuviotv://external-player/infuse/<launch id>/success|error`); when the viewer leaves Infuse, it
/// opens x-success with `lastPlayedUrl` and `position` (seconds), and that position is recorded as
/// watch progress — plus a Trakt stop when the duration is known — for the title handed off.
///
/// One pending launch at a time, persisted, so a callback still lands after the app was terminated
/// while Infuse played. A callback for an older launch, a second callback for the same one, or one
/// that names another file is ignored.
enum ExternalPlaybackCallbacks {
    /// Everything the in-app player's progress session carries for the title handed off.
    struct PendingLaunch: Codable, Equatable {
        var id: String
        var sourceUrl: String
        var profileId: Int32
        var contentType: String
        var parentMetaId: String
        var videoId: String
        var title: String
        var poster: String?
        var season: Int?
        var episode: Int?
        var providerName: String?
        var providerAddonId: String?
        var streamTitle: String?
        var streamSubtitle: String?
        /// Known from an earlier in-app session of this video. Unknown → the position is stored as is
        /// (never as "completed") and no Trakt stop is sent.
        var durationMs: Int64?
    }

    static let host = "external-player"
    private static let storageKey = "external_player.pending_launch"

    /// Registers `launch` as the pending hand-off and returns its return addresses.
    static func prepare(_ launch: PendingLaunch) -> (success: String, error: String) {
        if let data = try? JSONEncoder().encode(launch) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
        let base = "\(TopShelf.urlScheme)://\(host)/infuse/\(launch.id)"
        return ("\(base)/success", "\(base)/error")
    }

    /// The hand-off didn't happen: forget that launch (not a newer one).
    static func cancel(id: String) {
        guard pending()?.id == id else { return }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Handles `nuviotv://external-player/…`. True for ANY such URL — recorded, stale or malformed —
    /// so the caller never treats it as a deep link.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        guard url.scheme == TopShelf.urlScheme, url.host == host else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3, parts[0] == "infuse", let launch = pending(), launch.id == parts[1] else {
            print("[ExternalPlayback] ignored callback (no matching pending launch)")
            return true
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func parameter(_ name: String) -> String? { query.first { $0.name == name }?.value }
        switch parts[2] {
        case "success":
            // The viewer may have played something else in Infuse meanwhile: only this file counts.
            // Whole seconds per upstream; a fractional value is accepted too (truncated).
            guard reportsSameFile(parameter("lastPlayedUrl"), as: launch.sourceUrl),
                  let raw = parameter("position"), let seconds = Double(raw),
                  seconds.isFinite, seconds >= 0, seconds < 1_000_000_000 else {
                print("[ExternalPlayback] ignored Infuse callback (other file or no position)")
                return true
            }
            UserDefaults.standard.removeObject(forKey: storageKey)
            record(launch, positionMs: Int64(seconds * 1000))
        case "error":
            UserDefaults.standard.removeObject(forKey: storageKey)
            print("[ExternalPlayback] Infuse reported an error — nothing recorded")
        default:
            break
        }
        return true
    }

    /// Infuse names the file it played last (`lastPlayedUrl`), maybe re-encoded on the way back —
    /// escapes decoded or added, another letter case: the same host, path and (decoded) query are the
    /// same file; anything else is a file the viewer went on to play in Infuse. No URL at all: the
    /// launch id in the callback's path already names this hand-off.
    static func reportsSameFile(_ reported: String?, as launched: String) -> Bool {
        guard let reported, !reported.isEmpty else { return true }
        if reported == launched { return true }
        guard let reportedURL = URL(string: reported), let launchedURL = URL(string: launched) else {
            return reported.removingPercentEncoding == launched.removingPercentEncoding
        }
        func key(_ url: URL) -> String {
            let query = url.query ?? ""
            return "\(url.host?.lowercased() ?? "")\(url.path)?\(query.removingPercentEncoding ?? query)"
        }
        return key(reportedURL) == key(launchedURL)
    }

    private static func pending() -> PendingLaunch? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PendingLaunch.self, from: data)
    }

    private static func record(_ launch: PendingLaunch, positionMs: Int64) {
        guard positionMs > 0 else { return }
        let durationMs = launch.durationMs ?? 0
        // Error/placeholder clips are never progress (shared short-placeholder rule).
        if WatchingPoliciesKt.isShortPlaceholderDuration(durationMs: durationMs) { return }
        let season = launch.season.map { KotlinInt(int: Int32($0)) }
        let episode = launch.episode.map { KotlinInt(int: Int32($0)) }
        let session = WatchProgressPlaybackSession(
            profileId: launch.profileId,
            contentType: launch.contentType,
            parentMetaId: launch.parentMetaId,
            parentMetaType: launch.contentType,
            videoId: launch.videoId,
            title: launch.title,
            logo: nil,
            poster: launch.poster,
            background: nil,
            seasonNumber: season,
            episodeNumber: episode,
            episodeTitle: nil,
            episodeThumbnail: nil,
            providerName: launch.providerName,
            providerAddonId: launch.providerAddonId,
            lastStreamTitle: launch.streamTitle,
            lastStreamSubtitle: launch.streamSubtitle,
            pauseDescription: nil,
            lastSourceUrl: launch.sourceUrl
        )
        let snapshot = PlayerPlaybackSnapshot(
            isLoading: false,
            isPlaying: false,
            // The viewer left Infuse: completion comes from the watched fraction alone.
            isEnded: false,
            durationMs: durationMs,
            positionMs: positionMs,
            bufferedPositionMs: positionMs,
            playbackSpeed: 1,
            videoWidth: 0,
            videoHeight: 0
        )
        // A session's final record, like mobile's (which syncs it to the account).
        WatchProgressRepository.shared.flushPlaybackProgress(session: session, snapshot: snapshot, syncRemote: true)
        print("[ExternalPlayback] Infuse stopped at \(positionMs / 1000)s — progress recorded")

        guard durationMs > 0 else { return }
        let percent = Float(min(100, max(0, Double(positionMs) / Double(durationMs) * 100)))
        TraktScrobbleRepository.shared.buildItem(
            contentType: launch.contentType,
            parentMetaId: launch.parentMetaId,
            videoId: launch.videoId,
            title: launch.title,
            seasonNumber: season,
            episodeNumber: episode,
            episodeTitle: nil,
            releaseInfo: nil
        ) { item, _ in
            // Suspend completions can land off-main.
            DispatchQueue.main.async {
                guard let item else { return }
                TraktScrobbleRepository.shared.scrobbleStop(
                    profileId: launch.profileId,
                    item: item,
                    progressPercent: percent
                ) { _ in }
            }
        }
    }
}
