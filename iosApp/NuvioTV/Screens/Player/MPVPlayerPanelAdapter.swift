import AVFoundation
import Combine
import SharedCore
import SwiftUI

/// The structured fields of one mpv track (LANG-04), published by the track walk next to the
/// plain `PlayerTrack` rows so the panel can show "Français · Dolby Digital+ 5.1" and
/// "Anglais · Forcés" instead of "fre (subrip)". Pure formatting, no mpv access.
nonisolated struct MPVTrackFields: Equatable, Sendable {
    let id: Int
    let isAudio: Bool
    /// The file's language code ("fre", "pt-BR"), or the addon's for a side-loaded addon subtitle.
    let language: String
    /// The file's track title ("English SDH", "Commentary"), or the addon's display label.
    let title: String
    /// mpv codec name ("eac3", "truehd", "subrip") and profile ("Dolby TrueHD + Dolby Atmos").
    let codec: String
    let codecProfile: String
    /// Channel count; 0 = unknown.
    let channels: Int
    let forced: Bool
    let isDefault: Bool
    /// mpv's `hearing-impaired` flag.
    let hearingImpaired: Bool
    /// A side-loaded addon subtitle, and the addon it came from.
    var isAddon = false
    var addonName: String? = nil

    /// The language as a BCP 47 tag: the code refined by the variant the title states ("fre" +
    /// "VFQ" → "fr-CA", so the row reads "Français (Canada)"), else what the title says ("VFQ",
    /// "Español").
    var languageTag: String? {
        TrackLabelFormatter.trackLanguageTag(language: language, title: title)
    }

    var sdh: Bool { !isAudio && (hearingImpaired || TrackLabelFormatter.looksSdh(title)) }
    var atmos: Bool { isAudio && (TrackLabelFormatter.looksAtmos(codecProfile) || TrackLabelFormatter.looksAtmos(title)) }

    /// Primary line: the localized language name; the file's title when there is none.
    var displayTitle: String {
        if let tag = languageTag, let name = TrackLabelFormatter.languageName(tag) { return name }
        if !title.isEmpty { return title }
        return String(localized: "Track \(id)")
    }

    /// Secondary line: the title when it adds something ("Commentary"), then the descriptors —
    /// codec and layout for audio, Forced / SDH / format for subtitles, the addon for addon rows.
    var detail: String? {
        var parts: [String] = []
        let hasLanguageName = languageTag.flatMap { TrackLabelFormatter.languageName($0) } != nil
        // The release tag the file names the track with ("VFF", "VFQ"), which the descriptor below
        // drops as a mere restatement of the language (LANG-10: two French dubs must read apart).
        if hasLanguageName, !isAddon, let release = TrackLabelFormatter.releaseTag(title) {
            parts.append(release)
        }
        if hasLanguageName, !isAddon,
           let descriptor = TrackLabelFormatter.titleDescriptor(title, language: languageTag) {
            parts.append(descriptor)
        }
        if isAudio {
            let codecName = codecProfile.isEmpty ? codec : "\(codec) \(codecProfile)"
            if let audio = TrackLabelFormatter.audioDetail(codec: codecName,
                                                            channels: channels > 0 ? channels : nil,
                                                            atmos: atmos) {
                parts.append(audio)
            }
        } else {
            if let sub = TrackLabelFormatter.subtitleDetail(forced: forced, sdh: sdh, codec: isAddon ? nil : codec) {
                parts.append(sub)
            }
            if isAddon, let addonName, !addonName.isEmpty { parts.append(addonName) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: TrackLabelFormatter.separator)
    }

    /// Both lines on one, for the plain `PlayerTrack.label`.
    var label: String {
        [displayTitle, detail].compactMap { $0 }.joined(separator: TrackLabelFormatter.separator)
    }
}

/// Per-player store of the walk's `MPVTrackFields`, keyed by the player's `MPVPlaybackState` (the
/// one object the controller and this adapter share), so the structured rows reach the panel
/// without new stored state on the controller or the playback state.
final class MPVTrackCatalog: ObservableObject {
    @Published private(set) var audio: [Int: MPVTrackFields] = [:]
    @Published private(set) var subtitles: [Int: MPVTrackFields] = [:]

    func publish(audio: [MPVTrackFields], subtitles: [MPVTrackFields]) {
        let audioById = Dictionary(audio.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let subtitlesById = Dictionary(subtitles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.audio != audioById { self.audio = audioById }
        if self.subtitles != subtitlesById { self.subtitles = subtitlesById }
    }

    private static let catalogs = NSMapTable<MPVPlaybackState, MPVTrackCatalog>.weakToStrongObjects()

    static func catalog(for state: MPVPlaybackState) -> MPVTrackCatalog {
        if let existing = catalogs.object(forKey: state) { return existing }
        let created = MPVTrackCatalog()
        catalogs.setObject(created, forKey: state)
        return created
    }
}

/// Feeds the shared top panel from the mpv player: `MPVPlaybackState.audioTracks/subtitleTracks`
/// (mpv track ids; -1 = subtitles Off) plus their `MPVTrackCatalog` fields → checkmark rows with a
/// language title and a descriptor line, the libmpv diagnostics snapshot → Info rows/chips,
/// AVAudioSession → output route name. Picks go back through the state's
/// `selectAudio/selectSubtitle` closures, exactly like the old swipe-up picker did.
@MainActor
final class MPVPlayerPanelAdapter {
    private let state: MPVPlaybackState
    private let model: PlayerTopPanelModel
    private let context: PlaybackContext
    private let catalog: MPVTrackCatalog
    private var cancellables: Set<AnyCancellable> = []
    private var routeObserver: NSObjectProtocol?

    /// Addon subtitles shown per language and in total (LANG-05, same caps as the native engine);
    /// the selected one is always kept.
    private static let addonPerLanguageCap = 4
    private static let addonTotalCap = 24

    init(state: MPVPlaybackState, model: PlayerTopPanelModel, context: PlaybackContext) {
        self.state = state
        self.model = model
        self.context = context
        self.catalog = MPVTrackCatalog.catalog(for: state)

        model.onSelectSubtitle = { [weak state] option in
            state?.selectSubtitle?(option.flatMap { Int($0.id) } ?? -1)
        }
        model.onSelectAudio = { [weak state] option in
            if let id = Int(option.id) { state?.selectAudio?(id) }
        }
        // mpv can always re-time subtitles (`sub-delay`); the native AVPlayer adapter leaves
        // `supportsSubtitleDelay` false until beta.15 §B3 lands a delay mechanism there.
        model.supportsSubtitleDelay = true
        model.subtitleDelayMs = Self.ms(fromSeconds: state.subtitleDelaySec)
        model.onSubtitleDelayChange = { [weak state] ms in
            state?.setSubtitleDelay?(Double(ms) / 1000.0)
        }
        // mpv shifts audio too (`audio-delay`, LANG-13); the value is kept per device.
        model.supportsAudioDelay = true
        model.audioDelayMs = Self.ms(fromSeconds: state.audioDelaySec)
        model.onAudioDelayChange = { [weak state] ms in
            state?.setAudioDelay?(Double(ms) / 1000.0)
        }

        Publishers.Merge3(
            state.$audioTracks.map { _ in () }.eraseToAnyPublisher(),
            state.$subtitleTracks.map { _ in () }.eraseToAnyPublisher(),
            state.$subtitleSearchInFlight.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildSelections() }
        .store(in: &cancellables)

        Publishers.Merge(
            catalog.$audio.map { _ in () }.eraseToAnyPublisher(),
            catalog.$subtitles.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildSelections() }
        .store(in: &cancellables)

        // Reflects the controller's applied delay back into the panel — covers both the
        // persisted-value-on-load case (controller sets it before the panel is ever opened) and
        // any future non-panel path that changes it.
        state.$subtitleDelaySec
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                guard let self else { return }
                let ms = Self.ms(fromSeconds: seconds)
                if self.model.subtitleDelayMs != ms { self.model.subtitleDelayMs = ms }
            }
            .store(in: &cancellables)
        state.$audioDelaySec
            .receive(on: RunLoop.main)
            .sink { [weak self] seconds in
                guard let self else { return }
                let ms = Self.ms(fromSeconds: seconds)
                if self.model.audioDelayMs != ms { self.model.audioDelayMs = ms }
            }
            .store(in: &cancellables)

        Publishers.Merge3(
            state.$streamInfo.map { _ in () }.eraseToAnyPublisher(),
            state.$durationSec.map { _ in () }.eraseToAnyPublisher(),
            state.$routingNote.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuildInfo() }
        .store(in: &cancellables)

        rebuildSelections()
        rebuildInfo()
        refreshRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshRoute() }
        }
    }

    deinit {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    private func rebuildSelections() {
        // mpv's subtitle list already carries an "Off" entry (id -1) when there is anything to
        // pick; the panel puts Off first regardless of the engine's ordering. Then the file's own
        // tracks (and the stream's subtitle files) in file order, then the addon subtitles ranked.
        var subtitles: [PlayerPanelOption] = []
        let tracks = state.subtitleTracks
        if !tracks.isEmpty {
            let off = tracks.first { $0.id == -1 }
            subtitles.append(PlayerPanelOption(id: "off", title: String(localized: "Off"), group: .off,
                                               isSelected: off?.isSelected ?? !tracks.contains { $0.isSelected }))
            var addonRows: [(option: PlayerPanelOption, fields: MPVTrackFields)] = []
            for track in tracks where track.id != -1 {
                guard let fields = catalog.subtitles[track.id] else {
                    subtitles.append(PlayerPanelOption(id: String(track.id), title: track.label,
                                                       group: .embedded, isSelected: track.isSelected))
                    continue
                }
                var option = PlayerPanelOption(id: String(track.id), title: fields.displayTitle,
                                               detail: fields.detail,
                                               group: fields.isAddon ? .addon : .embedded,
                                               isSelected: track.isSelected)
                option.language = fields.languageTag
                if fields.isAddon {
                    addonRows.append((option, fields))
                } else {
                    subtitles.append(option)
                }
            }
            subtitles.append(contentsOf: rankedAddonRows(addonRows))
            subtitles = Self.disambiguated(subtitles)
        }
        if model.subtitles != subtitles { model.subtitles = subtitles }
        if model.subtitlesSearching != state.subtitleSearchInFlight { model.subtitlesSearching = state.subtitleSearchInFlight }

        let audio = state.audioTracks.map { track -> PlayerPanelOption in
            guard let fields = catalog.audio[track.id] else {
                return PlayerPanelOption(id: String(track.id), title: track.label, group: .audio,
                                         isSelected: track.isSelected)
            }
            var option = PlayerPanelOption(id: String(track.id), title: fields.displayTitle, detail: fields.detail,
                                           group: .audio, isSelected: track.isSelected)
            option.language = fields.languageTag
            return option
        }
        let distinctAudio = Self.disambiguated(audio)
        if model.audio != distinctAudio { model.audio = distinctAudio }
    }

    /// Never two identical rows: tracks that still read the same (two untitled French AC3 5.1
    /// tracks) get their track number on the descriptor line ("Piste 3"). Rows keep their ids.
    private static func disambiguated(_ options: [PlayerPanelOption]) -> [PlayerPanelOption] {
        func key(_ option: PlayerPanelOption) -> String { option.title + "\u{1F}" + (option.detail ?? "") }
        var counts: [String: Int] = [:]
        for option in options where option.group != .off { counts[key(option), default: 0] += 1 }
        guard counts.values.contains(where: { $0 > 1 }) else { return options }
        return options.map { option in
            guard option.group != .off, (counts[key(option)] ?? 0) > 1, let number = Int(option.id) else { return option }
            var copy = option
            let track = String(localized: "Track \(number)")
            copy.detail = [option.detail, track].compactMap { $0 }.joined(separator: TrackLabelFormatter.separator)
            return copy
        }
    }

    /// LANG-05 ranking: the preferred subtitle languages in their order, then the language of the
    /// audio being heard, then the rest, each in arrival order; at most `addonPerLanguageCap` per
    /// language and `addonTotalCap` in all, the selected row always kept.
    private func rankedAddonRows(_ rows: [(option: PlayerPanelOption, fields: MPVTrackFields)]) -> [PlayerPanelOption] {
        guard !rows.isEmpty else { return [] }
        var targets: [String] = []
        if let settings = PlayerSettingsRepository.shared.uiState.value_ as? PlayerSettingsUiState {
            targets = PlayerTrackSelectionKt.preferredSubtitleTargetsForSettings(settings: settings)
        }
        if let audioLanguage = state.audioTracks.first(where: { $0.isSelected })
            .flatMap({ catalog.audio[$0.id] })?.languageTag {
            targets.append(audioLanguage)
        }
        func rank(_ fields: MPVTrackFields) -> Int {
            let language = fields.languageTag ?? fields.language
            return targets.firstIndex { target in
                PlayerLanguagePreferencesKt.languageMatchesPreference(trackLanguage: language, targetLanguage: target)
            } ?? targets.count
        }
        let ordered = rows.enumerated()
            .sorted { lhs, rhs in
                let l = rank(lhs.element.fields), r = rank(rhs.element.fields)
                return l != r ? l < r : lhs.offset < rhs.offset
            }
            .map { $0.element }
        var perLanguage: [String: Int] = [:]
        var kept: [PlayerPanelOption] = []
        for row in ordered {
            let key = row.fields.languageTag ?? "und"
            let count = perLanguage[key, default: 0]
            guard row.option.isSelected || (count < Self.addonPerLanguageCap && kept.count < Self.addonTotalCap)
            else { continue }
            perLanguage[key] = count + 1
            kept.append(row.option)
        }
        return kept
    }

    private func rebuildInfo() {
        var rows: [NativeInfoRow] = []
        if let info = state.streamInfo {
            rows = info.rows.map { NativeInfoRow(label: $0.0, value: $0.1) }
        }
        if !rows.contains(where: { $0.label == String(localized: "Engine") }) {
            rows.insert(NativeInfoRow(label: String(localized: "Engine"),
                                      value: state.routingNote.isEmpty ? "mpv" : state.routingNote), at: 0)
        }
        if model.info.rows != rows { model.info.rows = rows }

        var chips: [PlayerPanelChip] = []
        if let year = context.meta?.year { chips.append(PlayerPanelChip(text: year)) }
        if let rating = context.meta?.imdbRating { chips.append(PlayerPanelChip(text: rating, symbol: "star.fill")) }
        if let age = context.meta?.ageRating { chips.append(PlayerPanelChip(text: age)) }
        if state.durationSec > 0 {
            chips.append(PlayerPanelChip(text: Self.runtimeString(state.durationSec), isRuntime: true))
        } else if let runtime = context.meta?.runtime {
            chips.append(PlayerPanelChip(text: runtime, isRuntime: true))
        }
        if let info = state.streamInfo {
            if !info.resolution.isEmpty { chips.append(PlayerPanelChip(text: info.resolution)) }
            // mpv's codec string is verbose ("H.264 / AVC / MPEG-4 AVC / MPEG-4 part 10"); chip = first name.
            if let codec = info.videoCodec.components(separatedBy: " / ").first, !codec.isEmpty {
                chips.append(PlayerPanelChip(text: codec))
            }
            if !info.fps.isEmpty { chips.append(PlayerPanelChip(text: info.fps)) }
            if !info.audio.isEmpty { chips.append(PlayerPanelChip(text: info.audio)) }
            if !info.videoBitrate.isEmpty { chips.append(PlayerPanelChip(text: info.videoBitrate)) }
        }
        if let bytes = context.fileSizeBytes, bytes > 0 {
            chips.append(PlayerPanelChip(text: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
        }
        if let genres = context.meta?.genres, !genres.isEmpty {
            chips.append(PlayerPanelChip(text: genres.prefix(3).joined(separator: ", ")))
        }
        // Dedupe by text — chip ids are their text.
        var seen = Set<String>()
        chips = chips.filter { seen.insert($0.text).inserted }
        if model.info.chips != chips { model.info.chips = chips }
    }

    private func refreshRoute() {
        let names = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).filter { !$0.isEmpty }
        let name = names.isEmpty ? "Apple TV" : names.joined(separator: ", ")
        if model.outputRouteName != name { model.outputRouteName = name }
    }

    private static func ms(fromSeconds seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    private static func runtimeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? String(localized: "\(h) h \(m) min") : String(localized: "\(m) min")
    }
}
