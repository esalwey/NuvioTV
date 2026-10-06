import AVKit
import SwiftUI

/// Audio tab, laid out like the classic tvOS panel: a LANGUAGE column (one checkmark row per audio
/// track) and a right column with SPEAKERS & HEADPHONES (current output route + the system route
/// picker) and, when the engine can shift audio, TIMING (Audio Delay, LANG-13).
/// Enhance Dialogue / Reduce Loud Sounds have no public API — on the native engine they stay in
/// the transport-bar Audio popover and the column says so (`showsSystemAudioHint`, VIS-07); mpv
/// has no such button, so no hint there.
///
/// Focus: Down from the tab row lands on the CURRENT track (spec §8.2).
struct PlayerAudioTab: View {
    @ObservedObject var model: PlayerTopPanelModel
    @FocusState private var focusedRow: String?

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.screen) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    PlayerPanelSectionCaption(text: String(localized: "Language"))
                    ForEach(model.audio) { option in
                        PlayerPanelOptionRow(option: option, identifierPrefix: "player.panel.audio") {
                            model.onSelectAudio?(option)
                        }
                        .focused($focusedRow, equals: option.id)
                    }
                    if model.audio.isEmpty {
                        Text("No stream details yet.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Full-width rows: Down from the (centred) tab row must land in the language list,
            // not on the route picker in the trailing column — the focus engine prefers overlap.
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    PlayerPanelSectionCaption(text: String(localized: "Speakers & Headphones"))
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "checkmark").font(Theme.Font.body.weight(.semibold)).frame(width: 34)
                        Image(systemName: "hifispeaker.and.appletv")
                        Text(model.outputRouteName.isEmpty ? "Apple TV" : model.outputRouteName)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                    }
                    if model.canPickRoute {
                        AudioRoutePickerButton()
                            .frame(height: 70)
                            .padding(.top, Theme.Spacing.xs)
                            .accessibilityIdentifier("player.panel.audio.route")
                    }
                    if model.supportsAudioDelay {
                        PlayerPanelSectionCaption(text: String(localized: "Timing")).padding(.top, Theme.Spacing.sm)
                        PlayerPanelDelayControl(
                            title: String(localized: "Audio Delay"),
                            valueMs: model.audioDelayMs,
                            steps: [.init(ms: -1000, id: "minus1"), .init(ms: -100, id: "minus"),
                                    .init(ms: 100, id: "plus"), .init(ms: 1000, id: "plus1")],
                            range: -PlayerTopPanelModel.audioDelayLimitMs...PlayerTopPanelModel.audioDelayLimitMs,
                            identifierPrefix: "player.panel.audioDelay"
                        ) { model.onAudioDelayChange?($0) }
                        Text(String(localized: "player.audio.delay.hint",
                                    defaultValue: "Positive values play the sound later.",
                                    comment: "Audio tab: explanation under the audio delay control."))
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.showsSystemAudioHint {
                        Text("Enhance Dialogue and sound options are in the player's Audio button.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Theme.Spacing.sm)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 600, alignment: .leading)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: 520, alignment: .topLeading)
        .defaultFocus($focusedRow, model.audio.first(where: \.isSelected)?.id, priority: .userInitiated)
    }
}

/// System AirPlay / Bluetooth output picker (opens the tvOS route sheet). Wrapped so it takes part
/// in the SwiftUI focus layout like any other control.
struct AudioRoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.routePickerButtonStyle = .system
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
