import Combine
import SwiftUI
import SharedCore

// Settings > Playback > Advanced: the less-used playback options, one pushed page each so the
// Playback pane itself stays short. Every row is the kit's stock one (SettingsRowViews.swift) and
// every setting keeps the storage and the view-model call it always had; only where it is shown
// moved. Menu on a page pops back to Playback.

// MARK: - Stream Recommendations

/// "Stream Recommendations": a pushed page whose row shows whether ranking is on, like Video Tuning.
struct StreamRecommendationsSettingsLinkRow: View {
    @ObservedObject var ranking: StreamRankingPreferencesModel

    var body: some View {
        NavigationLink {
            StreamRecommendationsSettingsPage()
        } label: {
            LabeledContent {
                Text(ranking.preferences.enabled ? String(localized: "On") : String(localized: "Off"))
                    .font(SettingsRowFont.title)
                    .settingsAccentTint()
            } label: {
                SettingsRowLabel(
                    title: String(localized: "settings.streams.section", defaultValue: "Stream Recommendations", comment: "Playback settings section: how the source picker ranks streams")
                )
            }
        }
    }
}

/// How the source picker ranks streams and picks the "Recommended" one. Saved per profile;
/// "Same as Audio Language" (the default) follows the Audio picker in Playback, so nothing changes
/// for a viewer who never opens this page. Owns its own watcher: the Playback pane stops its own
/// when it is covered by this page.
struct StreamRecommendationsSettingsPage: View {
    @StateObject private var ranking = StreamRankingPreferencesModel()

    var body: some View {
        let prefs = ranking.preferences
        let repository = StreamRankingSettingsRepository.shared
        List {
            SettingsSection(
                title: nil,
                footer: String(localized: "settings.streams.explanation", defaultValue: "The source list reads each stream's title (languages, quality, HDR, audio, size) and puts the best match for you first, marked Recommended. VFF is French from France, VFQ French from Qu\u{00E9}bec, VF French without a stated version.", comment: "Explanation at the top of the Stream Recommendations settings section")
            ) {
                SettingsToggleRow(
                    title: String(localized: "settings.streams.enabled", defaultValue: "Recommend Streams", comment: "Playback settings toggle: rank streams and mark the recommended one"),
                    subtitle: String(localized: "settings.streams.enabled.subtitle", defaultValue: "Sort each add-on's streams for you and pin the recommended one. Off: add-on order.", comment: "Explanation under the Recommend Streams toggle"),
                    isOn: Binding(get: { prefs.enabled }, set: { repository.setEnabled(enabled: $0) })
                )
                if prefs.enabled {
                    SettingsPickerRow(
                        title: String(localized: "settings.streams.audio", defaultValue: "Preferred Audio", comment: "Playback settings picker: the audio language/version streams are ranked for"),
                        subtitle: String(localized: "settings.streams.audio.subtitle", defaultValue: "VFF and VFQ are different dubs: pick the one you want first, or any French version.", comment: "Explanation under the Preferred Audio picker"),
                        selection: Binding(get: { prefs.audioLanguage }, set: { repository.setAudioLanguage(language: $0) }),
                        options: StreamRankingOptions.audioCodes(including: prefs.audioLanguage),
                        label: { StreamRankingOptions.audioLabel($0) }
                    )
                    SettingsPickerRow(
                        title: String(localized: "settings.streams.fallback", defaultValue: "Also Acceptable", comment: "Playback settings picker: audio language accepted when the preferred one is missing"),
                        subtitle: String(localized: "settings.streams.fallback.subtitle", defaultValue: "Ranked next when no stream has your preferred audio.", comment: "Explanation under the Also Acceptable picker"),
                        selection: Binding(
                            get: { prefs.fallbackAudioLanguages.first ?? "" },
                            set: { repository.setFallbackAudioLanguage(language: $0.isEmpty ? nil : $0) }
                        ),
                        options: StreamRankingOptions.fallbackCodes(including: prefs.fallbackAudioLanguages.first ?? ""),
                        label: { StreamRankingOptions.audioLabel($0) }
                    )
                    SettingsToggleRow(
                        title: String(localized: "settings.streams.subtitled", defaultValue: "Original Version with Subtitles", comment: "Playback settings toggle: accept original audio + subtitles (VOSTFR) when no dub exists"),
                        subtitle: String(localized: "settings.streams.subtitled.subtitle", defaultValue: "When no stream is dubbed in your language, recommend the original audio with subtitles (VOSTFR) before other languages.", comment: "Explanation under the Original Version with Subtitles toggle"),
                        isOn: Binding(get: { prefs.acceptSubtitledOriginal }, set: { repository.setAcceptSubtitledOriginal(accept: $0) })
                    )
                    if prefs.acceptSubtitledOriginal {
                        SettingsPickerRow(
                            title: String(localized: "settings.streams.subtitleLanguage", defaultValue: "Subtitle Language", comment: "Playback settings picker: subtitle language that makes an original-audio stream acceptable"),
                            selection: Binding(get: { prefs.subtitleLanguage }, set: { repository.setSubtitleLanguage(language: $0) }),
                            options: StreamRankingOptions.subtitleCodes(including: prefs.subtitleLanguage),
                            label: { StreamRankingOptions.subtitleLabel($0) }
                        )
                    }
                    SettingsPickerRow(
                        title: String(localized: "settings.streams.maxResolution", defaultValue: "Maximum Resolution", comment: "Playback settings picker: streams above this resolution are not recommended"),
                        selection: Binding(get: { Int(prefs.maxResolution) }, set: { repository.setMaxResolution(lines: Int32($0)) }),
                        options: StreamRankingOptions.withCurrent([0, 2160, 1080, 720], Int(prefs.maxResolution)),
                        label: { StreamRankingOptions.resolutionLabel($0) }
                    )
                    SettingsPickerRow(
                        title: String(localized: "settings.streams.hdr", defaultValue: "HDR & Dolby Vision", comment: "Playback settings picker: how HDR streams are ranked"),
                        subtitle: StreamRankingOptions.hdrCapabilityText,
                        selection: Binding(get: { prefs.hdrMode }, set: { repository.setHdrMode(mode: $0) }),
                        options: ["auto", "prefer", "avoid"],
                        label: { StreamRankingOptions.hdrLabel($0) }
                    )
                    SettingsPickerRow(
                        title: String(localized: "settings.streams.maxSize", defaultValue: "Maximum Size", comment: "Playback settings picker: streams larger than this are not recommended"),
                        selection: Binding(get: { Int(prefs.maxSizeGb) }, set: { repository.setMaxSizeGb(gigabytes: Int32($0)) }),
                        options: StreamRankingOptions.withCurrent([0, 5, 10, 20, 40, 60, 100], Int(prefs.maxSizeGb)),
                        label: { StreamRankingOptions.sizeLabel($0) }
                    )
                    SettingsToggleRow(
                        title: String(localized: "settings.streams.cached", defaultValue: "Prefer Cached Streams", comment: "Playback settings toggle: rank debrid-cached (instant) streams first"),
                        subtitle: String(localized: "settings.streams.cached.subtitle", defaultValue: "Streams your debrid service already has start instantly.", comment: "Explanation under the Prefer Cached Streams toggle"),
                        isOn: Binding(get: { prefs.preferCached }, set: { repository.setPreferCached(prefer: $0) })
                    )
                    SettingsToggleRow(
                        title: String(localized: "settings.streams.lowQuality", defaultValue: "Avoid CAM and TS", comment: "Playback settings toggle: never recommend releases filmed in a cinema"),
                        subtitle: String(localized: "settings.streams.lowQuality.subtitle", defaultValue: "Releases filmed in a cinema (CAM, TS, TC, screeners) are never recommended. They stay in the list, dimmed.", comment: "Explanation under the Avoid CAM and TS toggle"),
                        isOn: Binding(get: { prefs.avoidLowQuality }, set: { repository.setAvoidLowQuality(avoid: $0) })
                    )
                }
                // VERIFIED-LANGUAGES: read the real tracks of the top sources when their title is silent.
                SettingsToggleRow(
                    title: String(localized: "settings.streams.verifyLanguages", defaultValue: "Verify Source Languages",
                                  comment: "Playback settings toggle: read the audio/subtitle tracks of the top sources to confirm their languages"),
                    subtitle: String(localized: "settings.streams.verifyLanguages.subtitle",
                                     defaultValue: "Reads a few hundred KB of each top source (only ready-to-play links, never a torrent that still needs downloading) to list its real audio and subtitle tracks. Verified languages show a seal.",
                                     comment: "Explanation under the Verify Source Languages toggle"),
                    isOn: Binding(get: { prefs.verifyLanguages }, set: { repository.setVerifyLanguages(verify: $0) })
                )
            }
        }
        .navigationTitle(String(localized: "settings.streams.section", defaultValue: "Stream Recommendations", comment: "Playback settings section: how the source picker ranks streams"))
        .onAppear { ranking.start() }
        .onDisappear { ranking.stop() }
    }
}

// MARK: - Next Episode Stream

/// How Up Next picks the NEXT episode's stream, which sources count, and the Reuse Last Link window.
struct NextEpisodeStreamSettingsPage: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var streamSelection: StreamSelectionSettingsModel

    var body: some View {
        List {
            // Stream auto-play (shared settings, this Apple TV's namespace). The stream picker stays
            // manual on tvOS; this is how Up Next picks the NEXT episode's stream. The binge-group
            // preference (same source as the current episode) applies in every mode.
            SettingsSection(String(localized: "Next Episode Stream")) {
                SettingsPickerRow(
                    title: String(localized: "Stream Selection"),
                    subtitle: Self.streamModeSubtitle(model.streamAutoPlayMode),
                    selection: Binding(get: { model.streamAutoPlayMode }, set: { model.setStreamAutoPlayMode($0) }),
                    options: Self.streamModeOptions.map(\.value),
                    label: { value in Self.streamModeOptions.first { $0.value == value }?.label ?? value }
                )
                if model.streamAutoPlayMode != "MANUAL" {
                    SettingsPickerRow(
                        title: String(localized: "Source Scope"),
                        selection: Binding(get: { model.streamAutoPlaySource }, set: { model.setStreamAutoPlaySource($0) }),
                        options: Self.streamSourceOptions.map(\.value),
                        label: { value in Self.streamSourceOptions.first { $0.value == value }?.label ?? value }
                    )
                }
                if model.streamAutoPlayMode == "REGEX_MATCH" {
                    SettingsPickerRow(
                        title: String(localized: "Regex Pattern"),
                        subtitle: model.streamAutoPlayRegex.isEmpty
                            ? String(localized: "No pattern set: the first stream is picked.")
                            : String(localized: "Matches against stream name, title, description, add-on and URL: \(model.streamAutoPlayRegex)"),
                        selection: Binding(get: { model.streamAutoPlayRegex }, set: { _ = model.setStreamAutoPlayRegex($0) }),
                        options: Self.regexOptions(current: model.streamAutoPlayRegex),
                        label: { value in Self.regexLabel(value) }
                    )
                    RegexPatternEntryRow { model.setStreamAutoPlayRegex($0) }
                }
                NextEpisodeSourceRows(model: streamSelection, mode: model.streamAutoPlayMode,
                                      source: model.streamAutoPlaySource)
            }

            LastLinkSettingsSection(model: streamSelection)
        }
        .navigationTitle(String(localized: "Next Episode Stream"))
    }

    // MARK: Options (values = Kotlin enum names / regex patterns)

    private static let streamModeOptions: [(value: String, label: String)] = [
        ("MANUAL", String(localized: "Any Source")),
        ("FIRST_STREAM", String(localized: "First Stream in Scope")),
        ("REGEX_MATCH", String(localized: "Regex Match")),
    ]

    private static let streamSourceOptions: [(value: String, label: String)] = [
        ("ALL_SOURCES", String(localized: "All sources")),
        ("INSTALLED_ADDONS_ONLY", String(localized: "Installed add-ons only")),
        ("ENABLED_PLUGINS_ONLY", String(localized: "Enabled plugins only")),
    ]

    private static func streamModeSubtitle(_ mode: String) -> String {
        switch mode {
        case "FIRST_STREAM": return String(localized: "Up Next plays the first stream found within the source scope below.")
        case "REGEX_MATCH": return String(localized: "Up Next plays the first stream whose text matches your pattern.")
        default: return String(localized: "Up Next plays the first stream found from any source.")
        }
    }

    /// Upstream's regex presets (PlaybackSettingsPage), plus French audio for this app's users.
    private static let regexPresets: [(pattern: String, label: String)] = [
        ("(2160p|4k|1080p)", String(localized: "Any 1080p+")),
        ("(2160p|4k|remux)", String(localized: "4K / Remux")),
        ("(1080p|full\\s*hd)", String(localized: "1080p Standard")),
        ("(720p|webrip|web-dl)", String(localized: "720p / Smaller")),
        ("(web[-\\s]?dl|webrip)", String(localized: "WEB Sources")),
        ("(bluray|b[dr]rip|remux)", String(localized: "BluRay Quality")),
        ("(hevc|x265|h\\.265)", String(localized: "HEVC / x265")),
        ("(x264|h\\.264|avc)", String(localized: "AVC / x264")),
        ("(hdr|hdr10\\+?|dv|dolby\\s*vision)", String(localized: "HDR / Dolby Vision")),
        ("(atmos|truehd|dts[-\\s]?hd|dtsx?)", String(localized: "Dolby Atmos / DTS")),
        ("(\\beng\\b|english)", String(localized: "English")),
        ("\\b(multi|vff|vfq|vfi|vf2|vf|truefrench|french)\\b", String(localized: "French")),
        ("^(?!.*\\b(cam|hdcam|ts|telesync)\\b).*$", String(localized: "No CAM/TS")),
        ("(?is)^(?!.*\\b(hdr|hdr10|dv|dolby|vision|hevc|remux|2160p)\\b).+$", String(localized: "No REMUX/HDR")),
    ]

    /// "" (no pattern), every preset, and the current pattern when it is a custom one — the picker
    /// needs its selection among the options.
    private static func regexOptions(current: String) -> [String] {
        let presets = regexPresets.map(\.pattern)
        let base = [""] + presets
        return base.contains(current) ? base : base + [current]
    }

    private static func regexLabel(_ pattern: String) -> String {
        if pattern.isEmpty { return String(localized: "None") }
        return regexPresets.first { $0.pattern == pattern }?.label ?? String(localized: "Custom")
    }
}

/// Custom pattern for the Next Episode Stream "Regex Match" mode. Checked before it is saved (see
/// `SettingsViewModel.setStreamAutoPlayRegex`); the typed pattern stays when it is rejected.
private struct RegexPatternEntryRow: View {
    let onSave: (String) -> Bool
    @State private var pattern = ""
    @State private var rejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "text.magnifyingglass")
                    .font(SettingsRowFont.title)
                    .foregroundStyle(.secondary)
                TextField(String(localized: "Custom pattern, e.g. 4K|2160p|Remux"), text: $pattern)
                    .textFieldStyle(.plain)
                    .font(SettingsRowFont.title)
            }
            Button {
                if onSave(pattern) {
                    pattern = ""
                    rejected = false
                } else {
                    rejected = true
                }
            } label: {
                Label("Save Pattern", systemImage: "checkmark")
                    .font(SettingsRowFont.subtitle)
            }
            .disabled(pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if rejected {
                Text("Invalid regex pattern")
                    .font(SettingsRowFont.subtitle)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Skip Sources

/// Where skip timings come from beyond the built-in providers (Anime Skip, IntroDB). Only linked
/// while Skip Intro is on.
struct SkipSourcesSettingsPage: View {
    @ObservedObject var skip: SkipSettingsModel

    var body: some View {
        List {
            SkipSourcesSection(skip: skip)
        }
        .navigationTitle(String(localized: "Skip Sources"))
    }
}

// MARK: - Audio and Video

/// The mpv player's audio output and video tuning, its renderer, and the stream buffer. All of it
/// is device-local and applies from the next video.
struct AudioVideoSettingsPage: View {
    @ObservedObject var model: SettingsViewModel
    @ObservedObject var mpvTuning: MPVTuningSettingsModel

    var body: some View {
        List {
            SettingsSection(
                title: nil,
                footer: String(localized: "These apply to the mpv player, from the next video. The native player follows Audio Format in tvOS Settings \u{2192} Video and Audio. Volume Boost and Dialogue Boost are in the player's Audio menu.")
            ) {
                AudioOutputSettingsRow(tuning: mpvTuning)
                VideoTuningSettingsLinkRow(tuning: mpvTuning)
                SettingsToggleRow(
                    title: String(localized: "Enhanced Video Renderer"),
                    subtitle: String(localized: "Use the gpu-next (libplacebo) renderer for better HDR tone-mapping. Experimental \u{2014} Apple TV hardware only (ignored on the Simulator). Applies to the next video."),
                    isOn: Binding(get: { model.enhancedRenderer }, set: { model.setEnhancedRenderer($0) })
                )
            }

            SettingsSection(
                title: nil,
                footer: String(localized: "Buffer changes apply to the next playback. Larger buffers smooth out flaky connections at the cost of memory.")
            ) {
                SettingsPickerRow(
                    title: String(localized: "Streaming Buffer"),
                    selection: Binding(get: { model.bufferMB }, set: { model.setBufferMB($0) }),
                    options: [0, 64, 150, 512],
                    label: Self.bufferLabel
                )
                SettingsPickerRow(
                    title: String(localized: "Network Readahead"),
                    selection: Binding(get: { model.readaheadSec }, set: { model.setReadaheadSec($0) }),
                    options: [0, 30, 60, 120],
                    label: Self.readaheadLabel
                )
            }
        }
        .navigationTitle(String(localized: "Audio and Video"))
    }

    private static func bufferLabel(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Default")
        case 64: return String(localized: "64 MB")
        case 150: return String(localized: "150 MB")
        case 512: return String(localized: "512 MB")
        default: return "\(value) MB"
        }
    }

    private static func readaheadLabel(_ value: Int) -> String {
        switch value {
        case 0: return String(localized: "Default")
        case 30: return String(localized: "30 s")
        case 60: return String(localized: "60 s")
        case 120: return String(localized: "120 s")
        default: return "\(value) s"
        }
    }
}
