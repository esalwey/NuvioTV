import Foundation
import SharedCore

/// The words the app uses for a media-server failure, shared by the Library shelves, the stream
/// picker and the player. Kotlin carries the failure as the `ServerFailure` enum (matched by
/// `.name`, like `MediaServersViewModel`) or, where it crossed the bridge inside a plain string
/// (a stream group's error line), as its English fallback copy.
enum ServerFailureText {
    static func message(failure name: String) -> String {
        switch name {
        case "AUTH_REQUIRED":
            return String(localized: "Sign in to this server again in Settings.")
        case "UNREACHABLE":
            return String(localized: "The server is unavailable.")
        case "NOT_FOUND":
            return String(localized: "This item is no longer available on the server.")
        case "INCOMPLETE":
            return String(localized: "Still checking this server\u{2019}s library. Try again in a moment.")
        case "FORBIDDEN":
            return String(localized: "This user does not have access.")
        case "UNSUPPORTED":
            return String(localized: "The server doesn\u{2019}t support this item.")
        default:
            return String(localized: "Could not connect to the server.")
        }
    }

    static func message(for failure: ServerFailure) -> String {
        message(failure: failure.name)
    }

    /// A stream group's `error` line is `ServerFailure.message()` rendered in English by Kotlin; this
    /// maps it back to the localized copy. Anything unknown is returned as it is.
    static func localized(fallbackMessage text: String) -> String {
        let known = ["AUTH_REQUIRED", "UNREACHABLE", "NOT_FOUND", "INCOMPLETE", "FORBIDDEN", "UNSUPPORTED", "FAILED"]
        for name in known {
            if text == englishMessage(failure: name) { return message(failure: name) }
        }
        return text
    }

    /// The copy `ServerMessages.kt` produces, for the reverse lookup above.
    private static func englishMessage(failure name: String) -> String {
        switch name {
        case "AUTH_REQUIRED": return "Sign in to this server again in Settings."
        case "UNREACHABLE": return "The server is unavailable."
        case "NOT_FOUND": return "This item is no longer available on the server."
        case "INCOMPLETE": return "Still checking this server's library. Try again in a moment."
        case "FORBIDDEN": return "This user does not have access."
        case "UNSUPPORTED": return "The server doesn't support this item."
        default: return "Could not connect to the server."
        }
    }

    static var playbackFailed: String {
        String(localized: "Could not start playback from the server.")
    }

    static var audioSwitchFailed: String {
        String(localized: "Couldn\u{2019}t switch the audio track.")
    }

    static var subtitleSwitchFailed: String {
        String(localized: "Couldn\u{2019}t switch the subtitle track.")
    }
}
