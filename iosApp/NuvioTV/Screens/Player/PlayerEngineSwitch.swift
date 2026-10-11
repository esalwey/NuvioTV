import Foundation

// Switching the player engine by hand, from the player. The dispatcher (`PlayerScreen`) normally
// picks the engine: the native AVPlayer path for the files it can take, libmpv for everything else,
// and mpv again when the native path fails. This is the viewer's override of that choice: the
// "Player Engine" item of the transport bar (both engines draw the same one) and the error card's
// "Try Native Player".
//
// A switch hands the stream over at the playback position, with the audio and subtitle selection
// carried across: the engine being left writes its live selection to the title's track memory
// (`PlayerSubtitleMemory`, the memory both engines already restore from at start), so the other
// engine opens on the same tracks. Speed and subtitle timing are remembered per title already, and
// the aspect ratio is a player-wide setting.

/// What a player screen needs to offer and perform an engine switch. Built by `PlayerScreen`.
struct PlayerEngineSwitch {
    /// The engine playing now.
    let current: PlaybackEngine
    /// The native engine can take this stream over. The probe did not rule it out (or there was no
    /// probe: the native engine is off in Settings, and a manual switch is the viewer's own opt-in).
    /// The mpv side plays everything, so it is always available.
    let nativeAvailable: Bool
    /// Hand the stream to `target`, at `positionSec`. Runs on the main thread.
    let perform: (_ target: PlaybackEngine, _ positionSec: Double) -> Void

    /// There is another engine to offer: the transport bar shows the "Player Engine" item only then.
    var canSwitch: Bool { current == .native || nativeAvailable }

    /// The engine that is not playing, when it can take over.
    var alternative: PlaybackEngine? {
        switch current {
        case .native: return .mpv
        case .mpv: return nativeAvailable ? .native : nil
        }
    }
}

/// Why an engine other than the router's pick is showing. Drives the Stream Info "Engine" row and
/// the failover guard.
enum PlayerEngineOverride: Equatable {
    /// The native path failed; the dispatcher pinned this stream to mpv.
    case fallback
    /// The viewer asked for this engine from the player.
    case manual(PlaybackEngine)

    /// The engine the override pins, with `.fallback` meaning mpv.
    var engine: PlaybackEngine {
        switch self {
        case .fallback: return .mpv
        case .manual(let engine): return engine
        }
    }

    /// Label of the Stream Info "Engine" row.
    var note: String {
        switch self {
        case .fallback:
            return String(localized: "mpv \u{00B7} fallback")
        case .manual(let engine):
            return engine == .native
                ? String(localized: "Native \u{00B7} manual")
                : String(localized: "mpv \u{00B7} manual")
        }
    }
}

extension PlaybackEngine {
    /// Name of the engine in the "Player Engine" menu, the same words as the Stream Info row.
    var menuTitle: String {
        switch self {
        case .native:
            return String(localized: "player.engine.native", defaultValue: "Native",
                          comment: "Player Engine menu: the native Apple player (AVPlayer).")
        case .mpv:
            return String(localized: "player.engine.mpv", defaultValue: "mpv",
                          comment: "Player Engine menu: the mpv player, which plays every format. A product name.")
        }
    }
}
