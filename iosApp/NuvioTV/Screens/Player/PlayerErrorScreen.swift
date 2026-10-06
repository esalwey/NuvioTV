import Foundation
import SwiftUI
import UIKit

/// Why the mpv player can't show the stream (PLY-1). Until this existed a failed load only reached
/// the console: the spinner stayed up for good, with no message and no way on.
struct PlayerPlaybackError: Equatable {
    enum Kind: Equatable {
        /// mpv gave up on the file (END_FILE with an error): an expired or refused link, a missing
        /// file, an unsupported format.
        case failed
        /// Nothing playable arrived in time — a source that accepts the connection but never delivers
        /// data raises neither FILE_LOADED nor END_FILE. The load keeps going underneath: the card
        /// goes away by itself if the file loads after all.
        case timedOut
        /// The stream reached its end a few seconds after it started: it dropped or is truncated.
        case endedEarly
        /// The stream ended mid-way, well short of its duration: the connection dropped or the link
        /// expired (FFmpeg ends the file there rather than reporting an error).
        case dropped
        /// A short error/placeholder clip played instead of the video (a debrid "not cached" notice).
        case placeholder
    }

    let kind: Kind
    /// Technical detail under the explanation (HTTP status, else mpv's own error text), if any.
    var detail: String? = nil

    /// What went wrong, as a title (VIS-14: say what failed, in words, before any code).
    var title: String {
        switch kind {
        case .failed:
            return String(localized: "player.error.failed.title", defaultValue: "Can’t Play This Source",
                          comment: "Player error title: the source gave no playable video.")
        case .timedOut:
            return String(localized: "player.error.timedOut.title", defaultValue: "The Source Isn’t Responding",
                          comment: "Player error title: the source accepted the connection but sends nothing.")
        case .endedEarly:
            return String(localized: "player.error.endedEarly.title", defaultValue: "Playback Stopped Right Away",
                          comment: "Player error title: the stream ended seconds after it started.")
        case .dropped:
            return String(localized: "player.error.dropped.title", defaultValue: "Playback Stopped Early",
                          comment: "Player error title: the stream ended well before the end of the video.")
        case .placeholder:
            return String(localized: "player.error.placeholder.title", defaultValue: "This Video Isn’t Ready Yet",
                          comment: "Player error title: a short notice clip (debrid 'not cached') played instead of the video.")
        }
    }

    /// Why it probably happened, in one or two short sentences.
    var hint: String {
        switch kind {
        case .failed:
            return String(localized: "player.error.failed.hint",
                          defaultValue: "The link may have expired, or the file is unavailable or in a format that can’t be played.",
                          comment: "Player error hint under 'Can’t Play This Source'.")
        case .timedOut:
            return String(localized: "player.error.timedOut.hint",
                          defaultValue: "It may be busy or offline. Playback starts by itself if it answers.",
                          comment: "Player error hint under 'The Source Isn’t Responding'. The load keeps going underneath.")
        case .endedEarly:
            return String(localized: "player.error.endedEarly.hint",
                          defaultValue: "The file may be incomplete, or the connection dropped.",
                          comment: "Player error hint under 'Playback Stopped Right Away'.")
        case .dropped:
            return String(localized: "player.error.dropped.hint",
                          defaultValue: "The connection may have dropped, or the link expired. Try Again picks up where it stopped.",
                          comment: "Player error hint under 'Playback Stopped Early'. 'Try Again' is the button title.")
        case .placeholder:
            return String(localized: "player.error.placeholder.hint",
                          defaultValue: "The source played a short notice instead of the video. The debrid service may still be preparing the file.",
                          comment: "Player error hint under 'This Video Isn’t Ready Yet'.")
        }
    }

    /// The detail line for an END_FILE error: the HTTP status the core logged while opening the file
    /// (the usual reason — an expired debrid link answers 403/404), else mpv's error string.
    static func detail(httpStatus: Int?, mpvError: String?) -> String? {
        if let status = httpStatus {
            switch status {
            case 401, 403:
                return String(localized: "The server refused access (HTTP \(status)). The link may have expired.")
            case 404, 410:
                return String(localized: "The file is no longer on the server (HTTP \(status)).")
            case 500...599:
                return String(localized: "The server ran into an error (HTTP \(status)).")
            default:
                return String(localized: "The server answered with an error (HTTP \(status)).")
            }
        }
        guard let mpvError, !mpvError.isEmpty else { return nil }
        return "mpv: \(mpvError)"
    }

    /// The status of an FFmpeg `HTTP error 403 Forbidden` log line (nil for any other line). Runs on
    /// the mpv event queue.
    nonisolated static func httpStatus(inLogLine line: String) -> Int? {
        guard let marker = line.range(of: "HTTP error ") else { return nil }
        let digits = line[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
        guard digits.count == 3, let status = Int(digits), (400...599).contains(status) else { return nil }
        return status
    }
}

/// Full-screen error over the player (PLY-1, VIS-14): what failed, why, then the way on: another
/// source (the default, since an expired or refused link rarely recovers), the same source again,
/// or, while a slow source is still being waited on, more waiting. The technical cause (HTTP
/// status, mpv's own text) stays behind Show Details. Menu leaves the player
/// (`PlayerErrorHostController`).
///
/// Black, a large symbol, a Title 3 sentence and a Body hint, system buttons with the system focus
/// effect. No glass: tvOS keeps it for navigation and player controls, and this is neither.
struct PlayerErrorScreen: View {
    let error: PlayerPlaybackError
    /// What was playing ("S1E3 · Title", or the movie's title).
    let title: String
    /// A stream picker is behind the player. Without one, the first button just leaves the player.
    let canChooseSource: Bool
    let onChooseSource: () -> Void
    let onRetry: () -> Void
    let onKeepWaiting: () -> Void
    /// Leave the player (the same as Menu). With a picker behind the player it adds a Back button
    /// after the others; nil = Menu only.
    var onBack: (() -> Void)? = nil

    /// Focus targets (internal, not private: it types the `@FocusState` below, and the memberwise
    /// initializer must stay internal for the player controller).
    enum Target: Hashable {
        case chooseSource, retry, keepWaiting, details, back
    }

    @FocusState private var focus: Target?
    @State private var showsDetails = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.lg) {
                Image(systemName: "exclamationmark.triangle")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 120)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .padding(.bottom, Theme.Spacing.md)

                VStack(spacing: Theme.Spacing.sm) {
                    if !title.isEmpty {
                        Text(verbatim: title)
                            .font(Theme.Font.meta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(verbatim: error.title)
                        .font(Theme.Font.screenTitle)
                        .foregroundStyle(.primary)
                    Text(verbatim: error.hint)
                        .font(Theme.Font.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if showsDetails, let detail = error.detail {
                        Text(verbatim: detail)
                            .font(Theme.Font.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Theme.Spacing.xs)
                            .transition(.opacity)
                    }
                }
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)

                buttons
                    .padding(.top, Theme.Spacing.xl)
            }
            .frame(maxWidth: 1200)
            .padding(Theme.Spacing.screen)
        }
        // Drawn over the player whatever the system appearance.
        .environment(\.colorScheme, .dark)
        .defaultFocus($focus, .chooseSource)
        .onAppear { DispatchQueue.main.async { focus = .chooseSource } }
    }

    private var detailsTitle: String {
        showsDetails
            ? String(localized: "player.error.hideDetails", defaultValue: "Hide Details",
                     comment: "Player error button: hides the technical cause (HTTP status, player message).")
            : String(localized: "player.error.showDetails", defaultValue: "Show Details",
                     comment: "Player error button: shows the technical cause (HTTP status, player message).")
    }

    private var buttons: some View {
        let chooseTitle = canChooseSource ? String(localized: "Choose Another Source") : String(localized: "Back")
        return HStack(spacing: Theme.Spacing.xl) {
            Button(action: onChooseSource) {
                Label(chooseTitle, systemImage: canChooseSource ? "list.bullet" : "chevron.backward")
            }
            .focused($focus, equals: .chooseSource)
            Button(action: onRetry) {
                Label(String(localized: "Try Again"), systemImage: "arrow.clockwise")
            }
            .focused($focus, equals: .retry)
            if error.kind == .timedOut {
                Button(action: onKeepWaiting) {
                    Label(String(localized: "Keep Waiting"), systemImage: "hourglass")
                }
                .focused($focus, equals: .keepWaiting)
            }
            if error.detail != nil {
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { showsDetails.toggle() }
                } label: {
                    Label(detailsTitle, systemImage: "info.circle")
                }
                .focused($focus, equals: .details)
            }
            if canChooseSource, let onBack {
                Button(action: onBack) {
                    Label(String(localized: "Back"), systemImage: "chevron.backward")
                }
                .focused($focus, equals: .back)
            }
        }
        .focusSection()
    }
}

/// Presents `PlayerErrorScreen` over the mpv player — `.overFullScreen`, like the top panel, so the
/// player underneath gets no disappearance callbacks: its session (progress, Trakt, display mode,
/// the state timer) is still alive for "Retry", and a late load can simply take the card away.
/// Menu leaves the player; it is handled here so it can't pop the card alone and strand a dead
/// player behind it.
final class PlayerErrorHostController: UIHostingController<PlayerErrorScreen> {
    var onMenu: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "player.error"
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Menu acts on its release (below): the card goes away before the player does, and a release
        // arriving after that would reach whatever is underneath as half a press.
        if presses.contains(where: { $0.type == .menu }) { return }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            onMenu?()
            return
        }
        super.pressesEnded(presses, with: event)
    }
}
