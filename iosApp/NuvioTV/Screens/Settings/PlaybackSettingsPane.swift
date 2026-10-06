import Combine
import SwiftUI
import SharedCore

/// "Playback" category content: player engine toggles, buffer/readahead tuning, subtitle
/// appearance, and audio/subtitle language preference. Extracted from SettingsView.swift (Phase 2
/// HIG revamp file split) — logic and wiring preserved verbatim, only regrouped into a
/// per-category pane.
///
/// beta.15 §C (C3a): converted onto the native-List Settings kit (SettingsRowViews.swift, C1) —
/// the pane body returns its sections directly (no `VStack(spacing: sectionGap)` wrapper, which
/// used to collapse the whole pane into one giant List row), every toggle binds straight to the
/// view-model instead of the legacy value+action shim, and the Streaming Buffer / Network
/// Readahead / subtitle Size & Background chip rows are now `SettingsPickerRow` menus. Text Color
/// stays a custom swatch row — the kit has no colour-swatch primitive.
struct PlaybackSettingsPane: View {
    @ObservedObject var model: SettingsViewModel

    /// FEAT-11: whether a full-screen trailer should start with sound instead of muted. Mirrors
    /// DetailView's `trailer_audio_default_on` key (same @AppStorage key) — DetailView reads this
    /// to seed `HeroTrailerAudioState` at app launch and to restore it after a full-screen trailer
    /// dismisses; this pane also flips the shared state immediately so the change is felt without
    /// a relaunch.
    @AppStorage("trailer_audio_default_on") private var trailerAudioDefaultOn = false

    /// LANG-11: the secondary audio/subtitle languages are not on `SettingsViewModel`, so this pane
    /// watches them straight off the shared repository (same `FlowWatcher` pattern).
    @StateObject private var secondaryLanguages = SecondaryLanguagePreferences()

    var body: some View {
        Group {
            sections
        }
        .onAppear { secondaryLanguages.start() }
        .onDisappear { secondaryLanguages.stop() }
    }

    @ViewBuilder
    private var sections: some View {
        SettingsSection(String(localized: "Playback")) {
            // Hidden entirely unless an external player (Infuse) is installed —
            // see DefaultPlayerRow.
            DefaultPlayerRow()
            // VIS-02 (settings half): its own key, so the setting's name and the player's "Skip
            // Intro" button (`player.skip.intro`) can be translated independently.
            SettingsToggleRow(
                title: String(localized: "settings.skipIntro.title", defaultValue: "Skip Intro", comment: "Playback settings toggle that shows a Skip button during intros and outros"),
                subtitle: String(localized: "Show a Skip button during intros and outros"),
                isOn: Binding(get: { model.skipIntroEnabled }, set: { model.setSkipIntro($0) })
            )
            SettingsToggleRow(
                title: String(localized: "Match Content Frame Rate"),
                subtitle: String(localized: "Switch the display mode to the video's native frame rate and dynamic range. Also enable Match Content in tvOS Settings \u{2192} Video and Audio."),
                isOn: Binding(get: { model.matchFrameRate }, set: { model.setMatchFrameRate($0) })
            )
            SettingsToggleRow(
                title: String(localized: "Enhanced Video Renderer"),
                subtitle: String(localized: "Use the gpu-next (libplacebo) renderer for better HDR tone-mapping. Experimental \u{2014} Apple TV hardware only (ignored on the Simulator). Applies to the next video."),
                isOn: Binding(get: { model.enhancedRenderer }, set: { model.setEnhancedRenderer($0) })
            )
            SettingsToggleRow(
                title: String(localized: "Native player (Dolby Vision & HDR)"),
                subtitle: String(localized: "Play Dolby Vision, HDR10 and other compatible MKVs through the native AVPlayer engine for true DV output on Apple TV 4K; everything else stays on the mpv player. Profile 7 discs convert to 8.1 on the fly, and TrueHD/DTS-only audio plays as AAC 5.1."),
                isOn: Binding(get: { model.nativeDolbyVision }, set: { model.setNativeDolbyVision($0) })
            )
            if model.nativeDolbyVision {
                SettingsToggleRow(
                    title: String(localized: "Keep Profile 7 FEL on mpv"),
                    subtitle: String(localized: "Profile 7 FEL releases carry enhancement data the 8.1 conversion must discard. Turn on to keep those files on the mpv player (plays as HDR10, nothing discarded) instead of native Dolby Vision. MEL releases convert losslessly and always play native."),
                    isOn: Binding(get: { model.dvP7FelMpv }, set: { model.setDvP7FelMpv($0) })
                )
            }
            // FEAT-11
            SettingsToggleRow(
                title: String(localized: "Trailer Sound by Default"),
                subtitle: String(localized: "Trailers start with sound; play/pause mutes"),
                isOn: Binding(
                    get: { trailerAudioDefaultOn },
                    set: { newValue in
                        trailerAudioDefaultOn = newValue
                        // Applies immediately, without relaunch — DetailView otherwise only reads
                        // this default at app launch and after a full-screen trailer dismisses.
                        HeroTrailerAudioState.shared.setMuted(value: !newValue)
                    }
                )
            )
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
            Text("Buffer changes apply to the next playback. Larger buffers smooth out flaky connections at the cost of memory.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
        }

        // Up Next (NE-6/SET-1). Every row is this Apple TV's own (the phone's synced auto-play
        // switch defaults off, and its threshold slider can't hold 15/45 s); until "Before the End"
        // is picked here, the timing set on the phone applies — see `UpNextPreferences`.
        SettingsSection(String(localized: "Next Episode")) {
            SettingsToggleRow(
                title: String(localized: "Autoplay Next Episode"),
                subtitle: String(localized: "When an episode ends, the next one starts on its own after a countdown. Press OK or Menu during the countdown to cancel and go back to the details page."),
                isOn: Binding(get: { model.upNextAutoplay }, set: { model.setUpNextAutoplay($0) })
            )
            if model.upNextAutoplay {
                SettingsToggleRow(
                    title: String(localized: "Start at the Credits When Known"),
                    subtitle: String(localized: "Show Up Next as soon as the credits begin, for episodes whose credits timing is known (needs Skip Intro). A scene after the credits plays first."),
                    isOn: Binding(get: { model.upNextUseCredits }, set: { model.setUpNextUseCredits($0) })
                )
                SettingsPickerRow(
                    title: String(localized: "Before the End"),
                    subtitle: String(localized: "Otherwise, Up Next appears this long before the end of the episode. Until you pick a value, the timing set on your phone applies."),
                    selection: Binding(get: { model.upNextSecondsBeforeEnd }, set: { model.setUpNextSecondsBeforeEnd($0) }),
                    options: model.upNextSecondsBeforeEndOptions,
                    label: { model.upNextSecondsBeforeEndLabel($0) }
                )
                SettingsPickerRow(
                    title: String(localized: "Countdown"),
                    subtitle: String(localized: "How long Up Next counts down before playing. Pausing the video pauses the countdown."),
                    selection: Binding(get: { model.upNextCountdown }, set: { model.setUpNextCountdown($0) }),
                    options: UpNextPreferences.countdownOptions,
                    label: { String(localized: "\($0) s") }
                )
                SettingsToggleRow(
                    title: String(localized: "Ask \u{201C}Still Watching?\u{201D}"),
                    subtitle: String(localized: "After 3 episodes in a row without touching the remote, wait for a press before the next one."),
                    isOn: Binding(get: { model.upNextAskStillWatching }, set: { model.setUpNextAskStillWatching($0) })
                )
            }
        }

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
        }

        SettingsSection(String(localized: "Subtitles")) {
            if let style = model.subtitleStyle {
                SubtitleAppearanceControls(
                    style: style,
                    onTextColor: { model.setSubtitleTextColor($0) },
                    onSize: { model.setSubtitleFontSize($0) },
                    onBackground: { model.setSubtitleBackground($0) },
                    onBold: { model.setSubtitleBold($0) },
                    onOutline: { model.setSubtitleOutline($0) },
                    onStripSdh: { model.setSubtitleStripSdh($0) },
                    onBottomOffset: { offset in updateSubtitleStyle(bottomOffset: offset) }
                )
            } else {
                Text("Loading subtitle settings\u{2026}")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }

        // LANG-11: the full language list the phone offers (`AvailableLanguageOptionCodes`), a
        // secondary language for each, and the two subtitle rules the shared selection already
        // honours (forced-only, preferred-languages-only). Every row is synced per profile.
        SettingsSection(String(localized: "Audio & Subtitle Language")) {
            Text("When playback starts, auto-select the audio and subtitle tracks in your preferred language (when a matching track exists).")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(maxWidth: 1100, alignment: .leading)
            SettingsPickerRow(
                title: String(localized: "Audio"),
                selection: Binding(get: { model.preferredAudioLanguage }, set: { model.setPreferredAudioLanguage($0) }),
                options: LanguageOptions.preferredAudioCodes(including: model.preferredAudioLanguage),
                label: { LanguageOptions.trackLabel($0) }
            )
            SettingsPickerRow(
                title: String(localized: "settings.language.secondaryAudio", defaultValue: "Secondary Audio", comment: "Playback settings picker: audio language used when the preferred one is missing"),
                subtitle: String(localized: "settings.language.secondaryAudio.subtitle", defaultValue: "Used when no track matches the preferred audio language.", comment: "Explanation under the Secondary Audio picker"),
                selection: Binding(
                    get: { secondaryLanguages.audio },
                    set: { PlayerSettingsRepository.shared.setSecondaryPreferredAudioLanguage(language: $0.isEmpty ? nil : $0) }
                ),
                options: LanguageOptions.secondaryAudioCodes(including: secondaryLanguages.audio),
                label: { LanguageOptions.trackLabel($0) }
            )
            SettingsPickerRow(
                title: String(localized: "Subtitles"),
                selection: Binding(get: { model.preferredSubtitleLanguage }, set: { model.setPreferredSubtitleLanguage($0) }),
                options: LanguageOptions.preferredSubtitleCodes(including: model.preferredSubtitleLanguage),
                label: { LanguageOptions.trackLabel($0) }
            )
            SettingsPickerRow(
                title: String(localized: "settings.language.secondarySubtitles", defaultValue: "Secondary Subtitles", comment: "Playback settings picker: subtitle language used when the preferred one is missing"),
                subtitle: String(localized: "settings.language.secondarySubtitles.subtitle", defaultValue: "Used when no subtitles match the preferred language.", comment: "Explanation under the Secondary Subtitles picker"),
                selection: Binding(
                    get: { secondaryLanguages.subtitle },
                    set: { PlayerSettingsRepository.shared.setSecondaryPreferredSubtitleLanguage(language: $0.isEmpty ? nil : $0) }
                ),
                options: LanguageOptions.secondarySubtitleCodes(including: secondaryLanguages.subtitle),
                label: { LanguageOptions.trackLabel($0) }
            )
            if let style = model.subtitleStyle {
                SettingsToggleRow(
                    title: String(localized: "settings.subtitles.forcedOnly", defaultValue: "Forced Subtitles Only", comment: "Playback settings toggle: when the audio is in the subtitle language, show only forced subtitles"),
                    subtitle: String(localized: "settings.subtitles.forcedOnly.subtitle", defaultValue: "When the audio is already in your subtitle language, show only forced subtitles (signs and foreign dialogue), or none.", comment: "Explanation under the Forced Subtitles Only toggle"),
                    isOn: Binding(get: { style.useForcedSubtitles }, set: { updateSubtitleStyle(useForcedSubtitles: $0) })
                )
                SettingsToggleRow(
                    title: String(localized: "settings.subtitles.preferredOnly", defaultValue: "Show Only Preferred Languages", comment: "Playback settings toggle: hide add-on subtitles in other languages"),
                    subtitle: String(localized: "settings.subtitles.preferredOnly.subtitle", defaultValue: "Hide add-on subtitles that are not in your preferred or secondary subtitle language.", comment: "Explanation under the Show Only Preferred Languages toggle"),
                    isOn: Binding(get: { style.showOnlyPreferredLanguages }, set: { updateSubtitleStyle(showOnlyPreferredLanguages: $0) })
                )
            }
        }
    }

    /// Rebuilds the synced `SubtitleStyleState` with the given fields changed (KMP has no partial
    /// copy from Swift) — same shape as `SettingsViewModel.updateSubtitleStyle`, for the three
    /// fields that view model has no setter for. No-op until the style has loaded.
    private func updateSubtitleStyle(
        bottomOffset: Int32? = nil,
        useForcedSubtitles: Bool? = nil,
        showOnlyPreferredLanguages: Bool? = nil
    ) {
        guard let current = model.subtitleStyle else { return }
        PlayerSettingsRepository.shared.setSubtitleStyle(style: SubtitleStyleState(
            textColor: current.textColor,
            backgroundColor: current.backgroundColor,
            outlineColor: current.outlineColor,
            outlineEnabled: current.outlineEnabled,
            outlineWidth: current.outlineWidth,
            bold: current.bold,
            fontSizeSp: current.fontSizeSp,
            bottomOffset: bottomOffset ?? current.bottomOffset,
            stripSdh: current.stripSdh,
            useForcedSubtitles: useForcedSubtitles ?? current.useForcedSubtitles,
            showOnlyPreferredLanguages: showOnlyPreferredLanguages ?? current.showOnlyPreferredLanguages
        ))
    }

    // MARK: - Next Episode Stream options (values = Kotlin enum names / regex patterns)

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

/// "Default Player" chooser (FEAT-5 follow-up): built-in vs. any installed external player
/// (Infuse / VLC / Outplayer — whichever the Info.plist allowlist probe finds). When an
/// external player is the default, plain Select on a stream row hands off to it instead of the
/// in-app player, and the row's long-press menu gains a "Play in NuvioTV Player" escape hatch
/// (StreamPickerView reads the same key).
///
/// Self-contained on purpose: owns its own `availablePlayers()` probe and @AppStorage binding so
/// SettingsView doesn't grow more state. Renders NOTHING when no external player is installed —
/// a "Default Player" row whose only option is the built-in player is dead UI, and hiding it
/// matches the picker's own behavior (no Infuse ⇒ no handoff affordances anywhere).
///
/// The stored id is deliberately device-local (@AppStorage, not synced): which apps are
/// installed differs per Apple TV, so a synced default would dangle on every other device.
///
/// C3a: was a hand-rolled `Menu` + manual `HStack` with the legacy focus-aware text-colour
/// modifier and full-width row button style; now `SettingsPickerRow` gives the same Menu{Picker}
/// pill for free with system-inverted label colour, so the custom row chrome is gone.
private struct DefaultPlayerRow: View {
    @AppStorage("default_external_player_id") private var defaultExternalPlayerId = ""
    /// Probed at init, NOT in `.onAppear`: with no players this row renders nothing, and
    /// SwiftUI never fires `onAppear` for a view that renders empty — an onAppear probe
    /// therefore deadlocks the row into permanent invisibility (found on a real Apple TV with
    /// Infuse installed: the probe returned Infuse fine, but never got the chance to run).
    /// Init runs on the main thread (canOpenURL requirement) every time SettingsView rebuilds,
    /// so install/remove of a player is picked up at least as often as the old per-appearance
    /// probe — and the calls are a few cheap registry lookups.
    private let externalPlayers: [ExternalPlayerApp] = ExternalPlayerPlatform.shared.availablePlayers()

    /// Display name for the current selection (row trailing value).
    private var selectedName: String {
        externalPlayers.first { $0.id == defaultExternalPlayerId }?.name ?? String(localized: "NuvioTV (Built-in)")
    }

    var body: some View {
        if !externalPlayers.isEmpty {
            SettingsPickerRow(
                title: String(localized: "Default Player"),
                subtitle: defaultExternalPlayerId.isEmpty
                    ? String(localized: "Streams play in the built-in player. Hold a stream to open it in an external player instead.")
                    : String(localized: "Streams open in \(selectedName). Hold a stream to play it in NuvioTV instead; if \(selectedName) can\u{2019}t open, playback falls back to the built-in player."),
                selection: $defaultExternalPlayerId,
                options: [""] + externalPlayers.map(\.id),
                label: { id in
                    id.isEmpty ? String(localized: "NuvioTV (Built-in)") : (externalPlayers.first { $0.id == id }?.name ?? id)
                }
            )
            .onAppear {
                // Safe here: this onAppear is on the VISIBLE content, so it actually fires.
                // A stored default whose app was uninstalled silently reverts to built-in —
                // the picker independently guards against this too, but clearing here keeps
                // the row's displayed value honest. When NO player is installed the row is
                // hidden and a stale id survives harmlessly; the stream picker's membership
                // check already ignores it.
                if !defaultExternalPlayerId.isEmpty,
                   !externalPlayers.contains(where: { $0.id == defaultExternalPlayerId }) {
                    defaultExternalPlayerId = ""
                }
            }
        }
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

/// Subtitle appearance controls: a live preview plus text color, size, background, bold and outline.
/// Colors are `SubtitleColor` argb longs (0xAARRGGBB). The player reads these on the next file load.
///
/// C3a: Size and Background were text-label chip rows (the anti-pattern per the kit's field notes)
/// — both are now `SettingsPickerRow` menus. Text Color stays a custom swatch row: the kit has no
/// colour-swatch primitive, and a `Menu{Picker}` pill can't show a live colour preview.
private struct SubtitleAppearanceControls: View {
    let style: SubtitleStyleState
    let onTextColor: (Int64) -> Void
    let onSize: (Int32) -> Void
    let onBackground: (Int64) -> Void
    let onBold: (Bool) -> Void
    let onOutline: (Bool) -> Void
    let onStripSdh: (Bool) -> Void
    let onBottomOffset: (Int32) -> Void

    private let textColors: [(name: String, argb: Int64)] = [
        ("White", 0xFFFFFFFF), ("Yellow", 0xFFFFFF00), ("Cyan", 0xFF00FFFF), ("Green", 0xFF00FF00)
    ]
    private let sizes: [(name: String, sp: Int32)] = [
        (String(localized: "Small"), 14), (String(localized: "Medium"), 18),
        (String(localized: "Large"), 24), (String(localized: "X-Large"), 30)
    ]
    private let backgrounds: [(name: String, argb: Int64)] = [
        (String(localized: "Off"), 0x00000000), (String(localized: "Semi"), 0x80000000), (String(localized: "Solid"), 0xFF000000)
    ]
    /// LANG-11 Subtitle Position: `SubtitleStyleState.bottomOffset` presets (shared default 20,
    /// the phone's slider runs 0-200 in steps of 5). mpv maps it to `sub-pos` = 100 - offset/10
    /// (MPVPlayerView+Tracks `applySubtitleStyle`); a value set on the phone between presets is
    /// shown as its number.
    private let positions: [(name: String, offset: Int32)] = [
        (String(localized: "settings.subtitles.position.lowest", defaultValue: "Lowest", comment: "Subtitle position preset: at the bottom edge"), 0),
        (String(localized: "Default"), 20),
        (String(localized: "settings.subtitles.position.raised", defaultValue: "Raised", comment: "Subtitle position preset: a little above the default"), 60),
        (String(localized: "settings.subtitles.position.higher", defaultValue: "Higher", comment: "Subtitle position preset: well above the default"), 120),
        (String(localized: "settings.subtitles.position.highest", defaultValue: "Highest", comment: "Subtitle position preset: as high as the setting goes"), 200),
    ]

    var body: some View {
        preview

        controlRow(String(localized: "Text Color")) {
            ForEach(textColors, id: \.argb) { entry in
                Button { onTextColor(entry.argb) } label: {
                    SubtitleColorSwatch(
                        fill: color(entry.argb),
                        colorHex: UInt32(entry.argb & 0xFFFFFF),
                        isSelected: style.textColor == entry.argb
                    )
                }
                .buttonStyle(.borderless)
            }
        }

        SettingsPickerRow(
            title: String(localized: "Size"),
            selection: Binding(get: { style.fontSizeSp }, set: { onSize($0) }),
            options: sizes.map(\.sp),
            label: { sp in sizes.first { $0.sp == sp }?.name ?? "\(sp)" }
        )

        SettingsPickerRow(
            title: String(localized: "Background"),
            selection: Binding(get: { style.backgroundColor }, set: { onBackground($0) }),
            options: backgrounds.map(\.argb),
            label: { argb in backgrounds.first { $0.argb == argb }?.name ?? "\(argb)" }
        )

        // LANG-11 + LANG-06 note: the native (AVPlayer) engine lays captions out itself, so the
        // position only reaches the mpv player. Said under the row rather than left to surprise.
        SettingsPickerRow(
            title: String(localized: "settings.subtitles.position", defaultValue: "Subtitle Position", comment: "Playback settings picker: how high subtitles sit on screen"),
            subtitle: String(localized: "settings.subtitles.position.subtitle", defaultValue: "Applies to the mpv player only. The native player (Dolby Vision & HDR) places subtitles itself.", comment: "Note under Subtitle Position: the setting has no effect on the native player"),
            selection: Binding(get: { style.bottomOffset }, set: { onBottomOffset($0) }),
            options: positionOptions,
            label: { offset in positions.first { $0.offset == offset }?.name ?? "\(offset)" }
        )

        SettingsToggleRow(
            title: String(localized: "Bold"),
            subtitle: String(localized: "Use a heavier subtitle font"),
            isOn: Binding(get: { style.bold }, set: { onBold($0) })
        )
        SettingsToggleRow(
            title: String(localized: "Outline"),
            subtitle: String(localized: "Draw an outline around text for readability"),
            isOn: Binding(get: { style.outlineEnabled }, set: { onOutline($0) })
        )
        SettingsToggleRow(
            title: String(localized: "Strip SDH Subtitles"),
            subtitle: String(localized: "Hide sound descriptions and speaker labels from text subtitles."),
            isOn: Binding(get: { style.stripSdh }, set: { onStripSdh($0) })
        )
    }

    /// The presets, plus the current value when the phone set one between them.
    private var positionOptions: [Int32] {
        let presets = positions.map(\.offset)
        return presets.contains(style.bottomOffset) ? presets : (presets + [style.bottomOffset]).sorted()
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Color.black)
            Text("The quick brown fox")
                .font(style.bold ? Theme.Font.sectionTitle : Theme.Font.body)
                .foregroundStyle(color(style.textColor))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(color(style.backgroundColor))
        }
        .frame(height: 130)
        .frame(maxWidth: 700)
    }

    @ViewBuilder
    private func controlRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            HStack(spacing: Theme.Spacing.md) { content() }
        }
    }

    private func color(_ argb: Int64) -> Color {
        Color(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255.0,
            green: Double((argb >> 8) & 0xFF) / 255.0,
            blue: Double(argb & 0xFF) / 255.0,
            opacity: Double((argb >> 24) & 0xFF) / 255.0
        )
    }
}

/// A subtitle text-color swatch: selection wears a ring that contrasts with the swatch's own
/// fill; focus scales + shadows the circle (platter-free, same focus language as the theme
/// swatches).
private struct SubtitleColorSwatch: View {
    let fill: Color
    /// Raw RGB backing `fill`, so the selection ring can pick a shade that stays visible against
    /// it — a static accent ring nearly disappeared on the White swatch when the app theme was
    /// also White (same problem `SwatchLabel` fixes for the theme picker).
    let colorHex: UInt32
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 46, height: 46)
            .overlay(
                Circle().stroke(
                    isSelected ? Theme.Palette.onColor(forFillHex: colorHex) : Theme.Palette.textSecondary.opacity(0.4),
                    lineWidth: isSelected ? 4 : 1
                )
            )
            .padding(Theme.Spacing.xs)
    }
}

/// LANG-11: the two secondary track languages, watched straight off `PlayerSettingsRepository`
/// because `SettingsViewModel` does not publish them. "" stands for "none" (`nil` in the shared
/// settings) so a `SettingsPickerRow` can hold it.
@MainActor
private final class SecondaryLanguagePreferences: ObservableObject {
    @Published private(set) var audio = LanguageOptions.noSecondaryCode
    @Published private(set) var subtitle = LanguageOptions.noSecondaryCode

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        PlayerSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(PlayerSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let state = emitted as? PlayerSettingsUiState else { return }
            let audio = state.secondaryPreferredAudioLanguage ?? LanguageOptions.noSecondaryCode
            let subtitle = state.secondaryPreferredSubtitleLanguage ?? LanguageOptions.noSecondaryCode
            if self.audio != audio { self.audio = audio }
            if self.subtitle != subtitle { self.subtitle = subtitle }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
    }
}
