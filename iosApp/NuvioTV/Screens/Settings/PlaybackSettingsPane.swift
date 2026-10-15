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

    /// STREAM-INSIGHT: the stream-recommendation preferences (shared `StreamRankingSettingsRepository`).
    @StateObject private var streamRanking = StreamRankingPreferencesModel()

    /// Automatic Skipping, Anime Skip and the IntroDB key (shared `PlayerSettingsRepository`).
    @StateObject private var skip = SkipSettingsModel()

    /// Loading screen, parental guide and clock switches (shared `PlayerSettingsRepository`).
    @ObservedObject private var playerInterface = PlayerOverlaySettings.shared

    /// Audio output layout and video tuning of the mpv player (device-local).
    @StateObject private var mpvTuning = MPVTuningSettingsModel()

    /// How the Subtitles menu groups its rows (this Apple TV's own setting, read by both players).
    @AppStorage(SubtitleOrganization.storageKey) private var subtitleOrganizationRaw = SubtitleOrganization.ungrouped.rawValue

    /// Up Next's timeout, allow lists and source group, the last-link window and the external
    /// player's subtitle forwarding (shared `PlayerSettingsRepository`).
    @StateObject private var streamSelection = StreamSelectionSettingsModel()

    var body: some View {
        Group {
            sections
        }
        .onAppear {
            secondaryLanguages.start()
            streamRanking.start()
            skip.start()
            streamSelection.start()
        }
        .onDisappear {
            secondaryLanguages.stop()
            streamRanking.stop()
        }
    }

    @ViewBuilder
    private var sections: some View {
        SettingsSection(String(localized: "Playback")) {
            // Hidden entirely unless an external player (Infuse) is installed —
            // see DefaultPlayerRow.
            DefaultPlayerRow(selection: streamSelection)
            // VIS-02 (settings half): its own key, so the setting's name and the player's "Skip
            // Intro" button (`player.skip.intro`) can be translated independently.
            SettingsToggleRow(
                title: String(localized: "settings.skipIntro.title", defaultValue: "Skip Intro", comment: "Playback settings toggle that shows a Skip button during intros and outros"),
                subtitle: String(localized: "Show a Skip button during intros and outros"),
                isOn: Binding(get: { model.skipIntroEnabled }, set: { model.setSkipIntro($0) })
            )
            // Skipping needs the segments Skip Intro looks up, so the rows below only exist with it on.
            if model.skipIntroEnabled {
                AutoSkipSettingsLinkRow(skip: skip)
            }
            SettingsToggleRow(
                title: String(localized: "Match Content Frame Rate"),
                subtitle: String(localized: "Switch the display mode to the video's native frame rate and dynamic range. Also enable Match Content in tvOS Settings \u{2192} Video and Audio."),
                isOn: Binding(get: { model.matchFrameRate }, set: { model.setMatchFrameRate($0) })
            )
            SettingsPickerRow(
                title: String(localized: "Dolby Vision"),
                subtitle: model.dolbyVisionMode.detail,
                selection: Binding(get: { model.dolbyVisionMode }, set: { model.setDolbyVisionMode($0) }),
                options: DolbyVisionMode.allCases,
                label: { $0.title }
            )
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
        }

        // Audio of the native player: Atmos / DTS:X as Dolby Atmos (APAC, SpatialAudioBridge) and FLAC
        // instead of AAC 5.1 for TrueHD / DTS-HD MA. The mpv player's own audio settings are in
        // Advanced > Audio and Video. Device-local, applied from the next video.
        SettingsSection(
            String(localized: "Audio"),
            footer: String(localized: "These apply to the native player, from the next video. Dolby Atmos needs Audio Format on Auto and Dolby Atmos switched on in tvOS Settings \u{2192} Video and Audio, and a receiver or soundbar that plays Atmos from Apple TV. Spatial Audio uses an open-source renderer (SpatialAudioBridge). Dolby Atmos, TrueHD and DTS:X are covered by Dolby and DTS patents.")
        ) {
            // Apple TV HD has no Dolby Atmos output: no row to switch on.
            if SpatialAudioPolicy.deviceCanOutputAtmos {
                SettingsToggleRow(
                    title: String(localized: "Spatial Audio for TrueHD Atmos and DTS:X"),
                    subtitle: String(localized: "Play TrueHD Atmos and DTS:X tracks as Dolby Atmos, with their height channels. The Apple TV converts the audio as it plays; tracks it cannot convert play as before."),
                    isOn: Binding(get: { model.spatialAudio }, set: { model.setSpatialAudio($0) })
                )
            }
            SettingsToggleRow(
                title: String(localized: "Lossless Surround Sound"),
                subtitle: String(localized: "Play TrueHD and DTS-HD Master Audio tracks without objects as lossless 5.1 or 7.1 instead of AAC 5.1."),
                isOn: Binding(get: { model.losslessAudio }, set: { model.setLosslessAudio($0) })
            )
        }

        SettingsSection(String(localized: "Player Interface")) {
            SettingsToggleRow(
                title: String(localized: "Show Loading Screen"),
                subtitle: String(localized: "Show a spinner while a video opens. When off, the screen stays black until the first frame."),
                isOn: Binding(get: { playerInterface.showLoadingOverlay },
                              set: { playerInterface.setShowLoadingOverlay($0) })
            )
            SettingsToggleRow(
                title: String(localized: "Show Parental Guide"),
                subtitle: String(localized: "Briefly list the content advisories at the start of a video, when the title has any."),
                isOn: Binding(get: { playerInterface.showParentalGuide },
                              set: { playerInterface.setShowParentalGuide($0) })
            )
            SettingsToggleRow(
                title: String(localized: "Show Clock and End Time"),
                subtitle: String(localized: "Show the time and when the video will end while the playback controls are on screen."),
                isOn: Binding(get: { playerInterface.osdClockEnabled },
                              set: { playerInterface.setOsdClockEnabled($0) })
            )
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

        SettingsSection(String(localized: "Subtitles")) {
            if let style = model.subtitleStyle {
                SubtitleAppearanceControls(
                    style: style,
                    onTextColor: { model.setSubtitleTextColor($0) },
                    onSize: { model.setSubtitleFontSize($0) },
                    onBackground: { model.setSubtitleBackground($0) },
                    onBold: { model.setSubtitleBold($0) },
                    onOutline: { model.setSubtitleOutline($0) },
                    onOutlineColor: { model.setSubtitleOutlineColor($0) },
                    onOutlineWidth: { model.setSubtitleOutlineWidth($0) },
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
        SettingsSection(
            String(localized: "Audio & Subtitle Language"),
            footer: String(localized: "When playback starts, auto-select the audio and subtitle tracks in your preferred language (when a matching track exists).")
        ) {
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
            SettingsPickerRow(
                title: String(localized: "settings.subtitleList.title", defaultValue: "Subtitle List",
                              comment: "Playback settings picker: how the player's Subtitles menu groups its subtitles."),
                subtitle: subtitleOrganization.detail,
                selection: Binding(get: { subtitleOrganization },
                                   set: { subtitleOrganizationRaw = $0.rawValue }),
                options: SubtitleOrganization.allCases,
                label: { $0.title }
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

        // Expert options live one level down, so this pane stays short: each row opens a page of
        // its own (the tvOS Settings pattern for a category's less-used controls).
        SettingsSection(String(localized: "Advanced")) {
            // Native first by default; the Dolby Vision picker above keeps its own say (its Off turns
            // the native player off for good, and its other modes decide how Dolby Vision plays).
            SettingsPickerRow(
                title: String(localized: "Player"),
                subtitle: model.enginePreference.detail(nativeEngineEnabled: model.dolbyVisionMode.nativeEngineEnabled),
                selection: Binding(get: { model.enginePreference }, set: { model.setEnginePreference($0) }),
                options: PlayerEnginePreference.allCases,
                label: { $0.title }
            )
            StreamRecommendationsSettingsLinkRow(ranking: streamRanking)
            SettingsLinkRow(title: String(localized: "Next Episode Stream")) {
                NextEpisodeStreamSettingsPage(model: model, streamSelection: streamSelection)
            }
            if model.skipIntroEnabled {
                SettingsLinkRow(title: String(localized: "Skip Sources")) {
                    SkipSourcesSettingsPage(skip: skip)
                }
            }
            SettingsLinkRow(title: String(localized: "Audio and Video")) {
                AudioVideoSettingsPage(model: model, mpvTuning: mpvTuning)
            }
        }
    }

    private var subtitleOrganization: SubtitleOrganization {
        SubtitleOrganization(rawValue: subtitleOrganizationRaw) ?? .ungrouped
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
    /// Carries the subtitle forwarding switch (shared `PlayerSettingsRepository`).
    @ObservedObject var selection: StreamSelectionSettingsModel
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
            // The external players take subtitle URLs, so the add-on subtitles can go along: those
            // in the preferred and secondary subtitle language, fetched when the stream is handed
            // over. A subtitle the stream itself comes with is always sent.
            SettingsToggleRow(
                title: String(localized: "settings.external.forwardSubtitles", defaultValue: "Send Subtitles to External Players",
                              comment: "Playback settings toggle: pass add-on subtitles in the preferred languages to Infuse, VLC and the other external players."),
                subtitle: String(localized: "settings.external.forwardSubtitles.subtitle",
                                 defaultValue: "Fetch subtitles from your add-ons in your preferred and secondary subtitle languages and pass them to the external player. Not used when Subtitles is set to None.",
                                 comment: "Explanation under the Send Subtitles to External Players toggle."),
                isOn: Binding(get: { selection.forwardSubtitles }, set: { selection.setForwardSubtitles($0) })
            )
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
    let onOutlineColor: (Int64) -> Void
    let onOutlineWidth: (Int32) -> Void
    let onStripSdh: (Bool) -> Void
    let onBottomOffset: (Int32) -> Void

    private let textColors: [(name: String, argb: Int64)] = [
        ("White", 0xFFFFFFFF), ("Yellow", 0xFFFFFF00), ("Cyan", 0xFF00FFFF), ("Green", 0xFF00FF00)
    ]
    private let sizes: [(name: String, sp: Int32)] = [
        (String(localized: "Small"), 14), (String(localized: "Medium"), 18),
        (String(localized: "Large"), 24), (String(localized: "X-Large"), 30)
    ]
    /// Outline colours: black (the default) and a few that stay legible on light and dark pictures.
    private let outlineColors: [(name: String, argb: Int64)] = [
        ("Black", 0xFF000000), ("White", 0xFFFFFFFF), ("Yellow", 0xFFFFFF00), ("Red", 0xFFFF5C5C), ("Blue", 0xFF3B82F6)
    ]
    /// Outline widths: the phone's 1 to 5. mpv draws an outline of `width * 1.5` points.
    private let outlineWidths: [(name: String, width: Int32)] = [
        (String(localized: "settings.subtitles.outline.thin", defaultValue: "Thin", comment: "Subtitle outline width 1"), 1),
        (String(localized: "Default"), 2),
        (String(localized: "settings.subtitles.outline.medium", defaultValue: "Medium", comment: "Subtitle outline width 3"), 3),
        (String(localized: "settings.subtitles.outline.thick", defaultValue: "Thick", comment: "Subtitle outline width 4"), 4),
        (String(localized: "settings.subtitles.outline.heavy", defaultValue: "Heavy", comment: "Subtitle outline width 5"), 5),
    ]
    private let backgrounds: [(name: String, argb: Int64)] = [
        (String(localized: "Off"), 0x00000000), (String(localized: "Semi"), 0x80000000), (String(localized: "Solid"), 0xFF000000)
    ]
    /// LANG-11 Subtitle Position: `SubtitleStyleState.bottomOffset` presets (shared default 20,
    /// the phone's slider runs 0-200 in steps of 5). mpv maps it to `sub-pos` through
    /// `SubtitleRenderStyle.mpvSubPos` (a 5 % bottom margin at the default, one point per 10
    /// units); a value set on the phone between presets is
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
        if style.outlineEnabled {
            // The native (AVPlayer) engine draws its own caption edge: colour and width are the mpv
            // player's. Said once, under the colour row, rather than left to surprise.
            controlRow(String(localized: "settings.subtitles.outlineColor", defaultValue: "Outline Color",
                              comment: "Subtitle settings row: the colour of the outline around the text (mpv player only).")) {
                ForEach(outlineColors, id: \.argb) { entry in
                    Button { onOutlineColor(entry.argb) } label: {
                        SubtitleColorSwatch(
                            fill: color(entry.argb),
                            colorHex: UInt32(entry.argb & 0xFFFFFF),
                            isSelected: style.outlineColor == entry.argb
                        )
                    }
                    .buttonStyle(.borderless)
                }
            }
            SettingsPickerRow(
                title: String(localized: "settings.subtitles.outlineWidth", defaultValue: "Outline Width",
                              comment: "Subtitle settings picker: how thick the outline around the text is (mpv player only)."),
                subtitle: String(localized: "settings.subtitles.outline.subtitle",
                                 defaultValue: "Outline color and width apply to the mpv player. The native player draws the system caption edge.",
                                 comment: "Note under Outline Width: the settings have no effect on the native player."),
                selection: Binding(get: { style.outlineWidth }, set: { onOutlineWidth($0) }),
                options: outlineWidthOptions,
                label: { width in outlineWidths.first { $0.width == width }?.name ?? "\(width)" }
            )
        }
        SettingsToggleRow(
            title: String(localized: "Strip SDH Subtitles"),
            subtitle: String(localized: "Hide sound descriptions and speaker labels from text subtitles."),
            isOn: Binding(get: { style.stripSdh }, set: { onStripSdh($0) })
        )
    }

    /// 1 to 5, plus the current width when it is off the list.
    private var outlineWidthOptions: [Int32] {
        let widths = outlineWidths.map(\.width)
        return widths.contains(style.outlineWidth) ? widths : (widths + [style.outlineWidth]).sorted()
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
                .modifier(SubtitlePreviewOutline(enabled: style.outlineEnabled, color: color(style.outlineColor),
                                                 width: CGFloat(style.outlineWidth)))
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

/// The outline of the settings preview: four hard shadows, one per side, as wide as the setting
/// (a preview of the mpv player's outline, not a render of it).
private struct SubtitlePreviewOutline: ViewModifier {
    let enabled: Bool
    let color: Color
    let width: CGFloat

    func body(content: Content) -> some View {
        if enabled {
            let offset = max(width * 0.5, 0.5)
            content
                .shadow(color: color, radius: 0, x: offset, y: 0)
                .shadow(color: color, radius: 0, x: -offset, y: 0)
                .shadow(color: color, radius: 0, x: 0, y: offset)
                .shadow(color: color, radius: 0, x: 0, y: -offset)
        } else {
            content
        }
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

/// STREAM-INSIGHT: values and labels of the Stream Recommendations pickers. Codes are the shared
/// `StreamRankingPreferences` ones: "auto", "original", "fr-fr" (VFF), "fr-ca" (VFQ), "fr" (any
/// French), then lower-case ISO codes ("en", "es-419", "pt-br"…).
enum StreamRankingOptions {
    static let curatedAudio = ["auto", "original", "fr-fr", "fr-ca", "fr", "en", "es-es", "es-419", "pt-br", "pt-pt", "it", "de", "ja", "ko"]

    static func audioCodes(including current: String) -> [String] {
        let extra = LanguageOptions.trackLanguages.map(\.code).filter { !curatedAudio.contains($0) }
        return withCurrent(curatedAudio + extra, current)
    }

    static func fallbackCodes(including current: String) -> [String] {
        let base = audioCodes(including: current).filter { $0 != "auto" }
        return withCurrent([""] + base, current)
    }

    static func subtitleCodes(including current: String) -> [String] {
        withCurrent(["auto"] + LanguageOptions.trackLanguages.map(\.code), current)
    }

    static func audioLabel(_ code: String) -> String {
        switch code {
        case "": return String(localized: "None")
        case "auto":
            return String(localized: "settings.streams.audio.auto", defaultValue: "Same as Audio Language", comment: "Preferred Audio option: follow the Audio language picker")
        case "original":
            return String(localized: "settings.streams.audio.original", defaultValue: "Original Version (VO)", comment: "Preferred Audio option: the title's original language")
        case "fr-fr":
            return String(localized: "settings.streams.audio.vff", defaultValue: "French (France) \u{2014} VFF", comment: "Preferred Audio option: French dub made in France")
        case "fr-ca":
            return String(localized: "settings.streams.audio.vfq", defaultValue: "French (Qu\u{00E9}bec) \u{2014} VFQ", comment: "Preferred Audio option: French dub made in Qu\u{00E9}bec")
        case "fr":
            return String(localized: "settings.streams.audio.frAny", defaultValue: "French (Any Version)", comment: "Preferred Audio option: VFF, VFQ or unspecified French, equally")
        default:
            return LanguageOptions.trackLabel(code)
        }
    }

    static func subtitleLabel(_ code: String) -> String {
        if code == "auto" {
            return String(localized: "settings.streams.subtitle.auto", defaultValue: "Same as Subtitle Language", comment: "Subtitle Language option: follow the Subtitles picker (else the audio language)")
        }
        return LanguageOptions.trackLabel(code)
    }

    static func resolutionLabel(_ lines: Int) -> String {
        switch lines {
        case 0: return String(localized: "settings.streams.noLimit", defaultValue: "No Limit", comment: "Stream Recommendations picker option: no maximum")
        case 2160: return "4K"
        default: return "\(lines)p"
        }
    }

    static func sizeLabel(_ gigabytes: Int) -> String {
        if gigabytes == 0 { return resolutionLabel(0) }
        return String(localized: "settings.streams.size.gb", defaultValue: "\(gigabytes) GB",
                      comment: "Maximum Size option: a whole number of gigabytes (French: Go). %lld is the number.")
    }

    static func hdrLabel(_ mode: String) -> String {
        switch mode {
        case "prefer":
            return String(localized: "settings.streams.hdr.prefer", defaultValue: "Prefer HDR", comment: "HDR & Dolby Vision option: rank HDR streams higher")
        case "avoid":
            return String(localized: "settings.streams.hdr.avoid", defaultValue: "Prefer SDR", comment: "HDR & Dolby Vision option: rank HDR streams lower")
        default:
            return String(localized: "settings.streams.hdr.auto", defaultValue: "Automatic", comment: "HDR & Dolby Vision option: prefer HDR only when this TV can show it")
        }
    }

    /// What this Apple TV + TV can show, read live (AVPlayer.eligibleForHDRPlayback).
    static var hdrCapabilityText: String {
        if !StreamDisplayCapabilities.supportsHdr {
            return String(localized: "settings.streams.hdr.none", defaultValue: "This TV currently shows SDR: HDR streams are ranked lower (they play tone-mapped).", comment: "HDR & Dolby Vision picker subtitle when the display path has no HDR")
        }
        if !StreamDisplayCapabilities.supportsDolbyVision {
            return String(localized: "settings.streams.hdr.noDv", defaultValue: "This TV shows HDR. Dolby Vision plays as HDR10 unless the native Dolby Vision player is on, so DV-only streams rank lower.", comment: "HDR & Dolby Vision picker subtitle when HDR works but native Dolby Vision is off")
        }
        return String(localized: "settings.streams.hdr.full", defaultValue: "This TV shows HDR and Dolby Vision: Automatic ranks them first.", comment: "HDR & Dolby Vision picker subtitle when HDR and Dolby Vision both work")
    }

    static func withCurrent<T: Equatable>(_ options: [T], _ current: T) -> [T] {
        options.contains(current) ? options : options + [current]
    }
}

/// STREAM-INSIGHT: the shared stream-recommendation preferences, watched for the pane.
@MainActor
final class StreamRankingPreferencesModel: ObservableObject {
    @Published private(set) var preferences: StreamRankingPreferences = StreamRankingSettingsRepository.shared.snapshot()

    private var watcher: FlowWatcher?

    func start() {
        guard watcher == nil else { return }
        StreamRankingSettingsRepository.shared.ensureLoaded()
        watcher = FlowWatcherKt.watch(StreamRankingSettingsRepository.shared.uiState) { [weak self] emitted in
            guard let self, let value = emitted as? StreamRankingPreferences else { return }
            if self.preferences != value { self.preferences = value }
        }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
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
