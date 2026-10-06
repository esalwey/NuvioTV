import Foundation
import MediaPlayer
import UIKit

/// Now Playing for the mpv engine (PLY-A7 mpv half, VIS-06, spec gap 6). AVPlayerViewController
/// publishes the native engine's session by itself; libmpv publishes nothing, so before this
/// Control Center, the iPhone Remote and Siri ("pause") could neither see nor control mpv.
///
/// Ported from the iOS app's `PlayerNowPlayingController` (`iosApp/Player/NowPlayingController.swift`),
/// reshaped for tvOS:
///  - one instance per `MPVTVPlayerViewController`, active only while that player is on screen
///    (`activate()` in `viewDidAppear`, `deactivate()` in `viewDidDisappear`), so a player covered
///    by the end screen, or one on its way out while the next episode's player starts, never
///    receives a command or clears the other player's info;
///  - commands land on the controller's main-actor entry points (`nowPlayingPlay()` …), which go
///    through the same `eventQueue` path as the Siri Remote;
///  - the position is re-published only when it drifts from the rate-extrapolated value (a seek, a
///    stall), not on every 0.5 s poll tick.
///
/// The tvOS 27 `NowPlaying` framework (`MediaSession`) is not used yet: it needs the tvOS 27 SDK on
/// CI (plan fact 3). `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` work on tvOS 26 and 27.
final class MPVNowPlaying {
    private weak var controller: MPVTVPlayerViewController?
    private let title: String
    private let subtitle: String?
    private let artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: URLSessionDataTask?

    private struct RemoteTarget {
        let command: MPRemoteCommand
        let token: Any
    }
    private var targets: [RemoteTarget] = []
    private(set) var isActive = false

    /// The player whose info is in `MPNowPlayingInfoCenter` right now.
    private static weak var activeOwner: MPVNowPlaying?

    private struct Published: Equatable {
        var positionSec: Double
        var durationSec: Double
        var isPlaying: Bool
        var rate: Double
        var uptime: TimeInterval
    }
    private var published: Published?
    /// Latest values from the player, kept while inactive so `activate()` publishes them at once.
    private var latest = Published(positionSec: 0, durationSec: 0, isPlaying: false, rate: 1, uptime: 0)
    /// Re-publish the elapsed time when it is this far from where the last publish extrapolates to.
    private static let positionDriftSec: Double = 1.5

    init(controller: MPVTVPlayerViewController, context: PlaybackContext) {
        self.controller = controller
        let art = CachedTitleArt.peek(type: context.contentType, id: context.parentMetaId)

        // Episodes: the SERIES name as the title and "S2, E5 · Episode" under it (spec §9). Movies:
        // the title alone. Without a known series name the context's own label ("S1E3 · Pilot")
        // stays the title and carries the episode by itself.
        let seriesName = Self.nonEmpty(context.seriesTitle) ?? Self.nonEmpty(art?.name)
        if let season = context.season, let episode = context.episode, let seriesName {
            title = seriesName
            let number = String(
                localized: "player.nowPlaying.episodeNumber",
                defaultValue: "S\(season), E\(episode)",
                comment: "Now Playing (Control Center, iPhone Remote) line under the series name: season and episode numbers."
            )
            if let episodeTitle = Self.nonEmpty(context.episodeTitle) {
                subtitle = "\(number) \u{00B7} \(episodeTitle)"
            } else {
                subtitle = number
            }
        } else {
            title = Self.nonEmpty(context.title) ?? seriesName ?? ""
            subtitle = nil
        }

        let artworkString = Self.nonEmpty(context.poster)
            ?? Self.nonEmpty(context.background)
            ?? Self.nonEmpty(art?.background)
            ?? Self.nonEmpty(context.episodeStill)
        artworkURL = artworkString.flatMap { URL(string: $0) }
    }

    deinit {
        artworkTask?.cancel()
        // Normally already done by `deactivate()`; a target left behind would call into nothing
        // (the controller reference is weak), but it would keep the command enabled.
        for target in targets { target.command.removeTarget(target.token) }
    }

    // MARK: - Lifecycle

    func activate() {
        guard !isActive else { return }
        isActive = true
        Self.activeOwner = self
        registerCommands()
        loadArtworkIfNeeded()
        published = nil
        publish(latest)
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        for target in targets { target.command.removeTarget(target.token) }
        targets.removeAll()
        published = nil
        if Self.activeOwner === self {
            Self.activeOwner = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    // MARK: - Playback state

    /// From the player's 0.5 s state poll (`refreshState()`).
    func update(positionSec: Double, durationSec: Double, isPlaying: Bool, rate: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        latest = Published(
            positionSec: max(0, positionSec),
            durationSec: max(0, durationSec),
            isPlaying: isPlaying,
            rate: rate > 0 ? rate : 1,
            uptime: now
        )
        guard isActive else { return }
        if let last = published,
           last.isPlaying == latest.isPlaying,
           last.durationSec == latest.durationSec,
           last.rate == latest.rate {
            let expected = last.positionSec + (last.isPlaying ? (now - last.uptime) * last.rate : 0)
            if abs(expected - latest.positionSec) < Self.positionDriftSec { return }
        }
        publish(latest)
    }

    private func publish(_ state: Published) {
        guard isActive, !title.isEmpty else { return }
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        if let subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        info[MPNowPlayingInfoPropertyMediaType] = NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue)
        if state.durationSec > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = NSNumber(value: state.durationSec)
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = NSNumber(value: state.positionSec)
        info[MPNowPlayingInfoPropertyPlaybackRate] = NSNumber(value: state.isPlaying ? state.rate : 0)
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = NSNumber(value: 1.0)
        info[MPNowPlayingInfoPropertyIsLiveStream] = NSNumber(value: state.durationSec <= 0)
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        Self.activeOwner = self
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        var stamped = state
        stamped.uptime = ProcessInfo.processInfo.systemUptime
        published = stamped
    }

    // MARK: - Artwork

    private func loadArtworkIfNeeded() {
        guard artwork == nil, artworkTask == nil, let url = artworkURL else { return }
        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data, let image = UIImage(data: data) else { return }
            Task { @MainActor in self.artworkDidLoad(image) }
        }
        artworkTask = task
        task.resume()
    }

    private func artworkDidLoad(_ image: UIImage) {
        artworkTask = nil
        artwork = Self.makeArtwork(image)
        guard isActive else { return }
        published = nil
        publish(latest)
    }

    /// Nonisolated on purpose: MediaPlayer calls the request handler on its own queue, and a closure
    /// formed in main-actor code would be main-actor isolated.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    // MARK: - Remote commands

    private func registerCommands() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        let controller = self.controller

        // Each handler is `@Sendable` (nonisolated): MediaPlayer may call it off the main thread.
        // It reads what it needs from the event, then hops to the main actor.
        register(center.playCommand) { @Sendable [weak controller] _ in
            guard let target = controller else { return .noActionableNowPlayingItem }
            Task { @MainActor in target.nowPlayingPlay() }
            return .success
        }
        register(center.pauseCommand) { @Sendable [weak controller] _ in
            guard let target = controller else { return .noActionableNowPlayingItem }
            Task { @MainActor in target.nowPlayingPause() }
            return .success
        }
        register(center.togglePlayPauseCommand) { @Sendable [weak controller] _ in
            guard let target = controller else { return .noActionableNowPlayingItem }
            Task { @MainActor in target.nowPlayingTogglePause() }
            return .success
        }
        register(center.skipForwardCommand) { @Sendable [weak controller] event in
            guard let target = controller else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in target.nowPlayingSkip(by: interval) }
            return .success
        }
        register(center.skipBackwardCommand) { @Sendable [weak controller] event in
            guard let target = controller else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? 10
            Task { @MainActor in target.nowPlayingSkip(by: -interval) }
            return .success
        }
        register(center.changePlaybackPositionCommand) { @Sendable [weak controller] event in
            guard let target = controller,
                  let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime
            else { return .commandFailed }
            Task { @MainActor in target.nowPlayingSeek(to: position) }
            return .success
        }
    }

    private func register(
        _ command: MPRemoteCommand,
        handler: @escaping @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        command.isEnabled = true
        let token = command.addTarget(handler: handler)
        targets.append(RemoteTarget(command: command, token: token))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
