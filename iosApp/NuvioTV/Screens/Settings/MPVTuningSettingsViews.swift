import Combine
import SwiftUI

// Settings > Playback rows for the mpv engine's audio output and video tuning, built from the same
// kit as their neighbours (SettingsRowViews.swift). Everything here is device-local and applies to
// the next video (the mpv player reads it when it starts).

/// Backs the Audio Output row and the Video page. Each change is written straight to UserDefaults.
@MainActor
final class MPVTuningSettingsModel: ObservableObject {
    @Published private(set) var audioOutput: AudioOutputMode = .current
    @Published private(set) var video: MPVVideoSettings = .current

    func setAudioOutput(_ mode: AudioOutputMode) {
        audioOutput = mode
        mode.store()
    }

    /// Applies `change` to the video settings and stores the result.
    func updateVideo(_ change: (inout MPVVideoSettings) -> Void) {
        var updated = video
        change(&updated)
        video = updated
        updated.store()
    }

    func resetVideo() {
        updateVideo { $0 = MPVVideoSettings() }
    }
}

/// "Audio Output": the channel layout of the mpv player.
struct AudioOutputSettingsRow: View {
    @ObservedObject var tuning: MPVTuningSettingsModel

    var body: some View {
        SettingsPickerRow(
            title: String(localized: "Audio Output"),
            subtitle: tuning.audioOutput.detail,
            selection: Binding(get: { tuning.audioOutput }, set: { tuning.setAudioOutput($0) }),
            options: AudioOutputMode.allCases,
            label: { $0.title }
        )
    }
}

/// "Video": a pushed page (`NavigationLink`, like Automatic Skipping) whose row shows whether
/// anything differs from the defaults.
struct VideoTuningSettingsLinkRow: View {
    @ObservedObject var tuning: MPVTuningSettingsModel

    var body: some View {
        NavigationLink {
            VideoTuningSettingsPage(tuning: tuning)
        } label: {
            LabeledContent {
                Text(tuning.video.summary)
                    .font(SettingsRowFont.title)
                    .settingsAccentTint()
            } label: {
                SettingsRowLabel(
                    title: String(localized: "Video Tuning"),
                    subtitle: String(localized: "Tone mapping, decoding, smoothing and picture adjustments of the mpv player.")
                )
            }
        }
    }
}

/// The page behind the row. Menu pops back to Playback.
struct VideoTuningSettingsPage: View {
    @ObservedObject var tuning: MPVTuningSettingsModel

    var body: some View {
        List {
            SettingsSection(
                String(localized: "HDR"),
                footer: String(localized: "Tone mapping fits HDR highlights to your display. Peak detection measures every scene for a more faithful picture and costs a little graphics power.")
            ) {
                SettingsPickerRow(
                    title: String(localized: "Tone Mapping"),
                    selection: Binding(get: { tuning.video.toneMapping },
                                       set: { value in tuning.updateVideo { $0.toneMapping = value } }),
                    options: VideoToneMapping.allCases,
                    label: { $0.title }
                )
                SettingsToggleRow(
                    title: String(localized: "HDR Peak Detection"),
                    isOn: Binding(get: { tuning.video.hdrPeakDetection },
                                  set: { value in tuning.updateVideo { $0.hdrPeakDetection = value } })
                )
            }

            SettingsSection(String(localized: "Decoding")) {
                SettingsPickerRow(
                    title: String(localized: "Hardware Decoding"),
                    subtitle: tuning.video.hardwareDecoding.detail,
                    selection: Binding(get: { tuning.video.hardwareDecoding },
                                       set: { value in tuning.updateVideo { $0.hardwareDecoding = value } }),
                    options: VideoHardwareDecoding.allCases,
                    label: { $0.title }
                )
            }

            SettingsSection(String(localized: "Smoothing")) {
                SettingsToggleRow(
                    title: String(localized: "Debanding"),
                    subtitle: String(localized: "Hide the visible steps in skies and other smooth gradients."),
                    isOn: Binding(get: { tuning.video.deband },
                                  set: { value in tuning.updateVideo { $0.deband = value } })
                )
                SettingsToggleRow(
                    title: String(localized: "Motion Smoothing"),
                    subtitle: String(localized: "Blend frames to match the display's refresh rate for steadier pans. Films can look less cinematic."),
                    isOn: Binding(get: { tuning.video.interpolation },
                                  set: { value in tuning.updateVideo { $0.interpolation = value } })
                )
            }

            SettingsSection(
                String(localized: "Picture"),
                footer: String(localized: "Changes apply to the next video you play.")
            ) {
                ForEach(PictureAdjustment.allCases) { adjustment in
                    pictureRow(adjustment)
                }
            }

            if !tuning.video.isDefault {
                SettingsSection(title: nil) {
                    SettingsActionRow(title: String(localized: "Reset to Defaults")) {
                        tuning.resetVideo()
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Video Tuning"))
    }

    private func pictureRow(_ adjustment: PictureAdjustment) -> some View {
        SettingsPickerRow(
            title: adjustment.title,
            selection: Binding(get: { tuning.video.value(for: adjustment) },
                               set: { value in tuning.updateVideo { $0.set(value, for: adjustment) } }),
            options: Self.pictureOptions(including: tuning.video.value(for: adjustment)),
            label: { MPVVideoSettings.pictureTitle($0) }
        )
    }

    /// The offered values, plus the current one when it is off the grid.
    private static func pictureOptions(including current: Int) -> [Int] {
        var options = MPVVideoSettings.pictureChoices
        if !options.contains(current) {
            options.append(current)
            options.sort()
        }
        return options
    }
}
