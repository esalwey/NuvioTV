import Foundation
import SwiftUI

/// The one loading screen of the player, whichever engine is getting ready (PLY-A12): black, then a
/// spinner only once the wait gets noticeable, then a short caption only once it gets long.
///
/// No backdrop, logo or card: HIG "Playing video › Loading content" asks for the video itself as
/// quickly as possible, and a loading screen that looks like content reads as a hang once it stays
/// up. Most starts never show more than black.
///
/// The delays count from the moment playback was asked for (`playerLoadingStartedAt`, set by
/// `PlayerScreen`), not from this view's appearance: the router's probe and then the engine's own
/// preparation each show this view in turn, and the spinner must not restart its wait between them.
struct PlayerLoadingView: View {
    /// What is taking long (for example "Preparing Dolby Vision…"). Shown under the spinner after
    /// `captionDelay`. nil = the spinner alone.
    var caption: String? = nil

    /// Black only, up to here.
    static let spinnerDelay: TimeInterval = 2
    /// The caption joins the spinner from here.
    static let captionDelay: TimeInterval = 5

    @Environment(\.playerLoadingStartedAt) private var startedAt
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSpinner = false
    @State private var showsCaption = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: Theme.Spacing.lg) {
                ProgressView()
                    .scaleEffect(1.5)
                    .opacity(showsSpinner ? 1 : 0)
                if let caption {
                    Text(verbatim: caption)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .opacity(showsCaption ? 1 : 0)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: caption ?? String(
                localized: "player.loading.accessibilityLabel",
                defaultValue: "Loading",
                comment: "VoiceOver label of the player's loading spinner.")))
            .accessibilityHidden(!showsSpinner)
        }
        // Drawn before any video, whatever the system appearance.
        .environment(\.colorScheme, .dark)
        .task { await reveal() }
    }

    /// Fades the spinner, then the caption, in at their delays from `startedAt`.
    private func reveal() async {
        let origin = startedAt ?? Date()
        let fade: Animation? = reduceMotion ? nil : .easeIn(duration: 0.3)

        let spinnerWait = Self.spinnerDelay - Date().timeIntervalSince(origin)
        if spinnerWait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(spinnerWait * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        withAnimation(fade) { showsSpinner = true }

        guard caption != nil else { return }
        let captionWait = Self.captionDelay - Date().timeIntervalSince(origin)
        if captionWait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(captionWait * 1_000_000_000))
        }
        guard !Task.isCancelled else { return }
        withAnimation(fade) { showsCaption = true }
    }
}

private struct PlayerLoadingStartedAtKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// When the viewer asked for this playback (`PlayerScreen` sets it per context). nil = the
    /// loading view counts from its own appearance.
    var playerLoadingStartedAt: Date? {
        get { self[PlayerLoadingStartedAtKey.self] }
        set { self[PlayerLoadingStartedAtKey.self] = newValue }
    }
}
