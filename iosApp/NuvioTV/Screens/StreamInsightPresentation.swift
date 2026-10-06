import AVFoundation
import SwiftUI
import SharedCore

// STREAM-INSIGHT: the tvOS face of the shared stream parser and recommender
// (`StreamInsightParser`, `StreamRecommender`, `StreamRankingSettingsRepository` in SharedCore).
// Kotlin reads the messy add-on title; this file turns the result into what a row shows — a
// quality line, audio/subtitle language chips with the French version always visible (VFF, VFQ,
// "VF ?" when unstated), size and cache state in a right column, source/provider on focus, the
// section (tier) a stream belongs to, and the reasons behind the "Recommended" pick. SF Symbols
// only: every add-on emoji is stripped before display.

/// What this Apple TV can show, for the HDR/DV part of the ranking.
enum StreamDisplayCapabilities {
    /// HDR reaches the screen — AVFoundation's own verdict for the current display path.
    static var supportsHdr: Bool { AVPlayer.eligibleForHDRPlayback }

    /// Dolby Vision plays as Dolby Vision: an HDR path AND the native (AVPlayer) DV engine on —
    /// the mpv engine shows DV as HDR10, or with wrong colours for profile 5.
    static var supportsDolbyVision: Bool {
        supportsHdr && UserDefaults.standard.bool(forKey: PlayerTuning.nativeDVKey)
    }
}

/// The title's original language, for "Original" preferences and VO matching.
enum StreamOriginalLanguage {
    static func resolve(meta: PlaybackMeta?, type: String, parentMetaId: String) -> String? {
        if let language = meta?.originalLanguage, !language.isEmpty { return language }
        guard let details = MetaDetailsRepository.shared.peek(type: type, id: parentMetaId) else { return nil }
        let resolved: String? = PlayerLanguagePreferencesKt.resolveContentLanguage(
            language: details.language, country: details.country
        )
        return resolved
    }
}

/// One language chip ("VFF", "VF ?", "Anglais", "Français" under a captions symbol).
struct StreamLanguageChipInfo: Hashable {
    let text: String
    /// Low-confidence deductions (a lone 🇨🇦 flag, a bare MULTi): drawn dashed, read as a question.
    let isUncertain: Bool
    /// What VoiceOver reads ("Français, version inconnue" for "VF ?").
    let accessibilityText: String
}

/// Where a stream sits for this viewer — the section headers inside an add-on's list. Follows the
/// recommender's first reason, so the order matches the ranking: a dub in the viewer's language,
/// the right language in another version (VFQ for a VFF viewer), the original with subtitles,
/// anything else, then what the viewer's own limits filter out.
enum StreamRowTier: Int, Comparable {
    case yourLanguage = 0
    case otherVersion
    case subtitled
    case otherLanguages
    case outsideLimits

    static func < (lhs: StreamRowTier, rhs: StreamRowTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .yourLanguage:
            return String(localized: "streams.tier.yourLanguage", defaultValue: "In Your Language",
                          comment: "Source picker section header: streams with audio in the viewer's language (e.g. VFF).")
        case .otherVersion:
            return String(localized: "streams.tier.otherVersion", defaultValue: "Other Version",
                          comment: "Source picker section header: right language, other version (e.g. VFQ for a viewer who wants VFF).")
        case .subtitled:
            return String(localized: "streams.tier.subtitled", defaultValue: "Original with Subtitles",
                          comment: "Source picker section header: original-language audio with subtitles in the viewer's language (VOSTFR).")
        case .otherLanguages:
            return String(localized: "streams.tier.otherLanguages", defaultValue: "Other Languages",
                          comment: "Source picker section header: none of the viewer's languages, or nothing stated.")
        case .outsideLimits:
            return String(localized: "streams.tier.outsideLimits", defaultValue: "Outside Your Limits",
                          comment: "Source picker section header: streams filtered by the viewer's settings (CAM, max size, max resolution). Still playable.")
        }
    }

    static func from(_ recommendation: StreamRecommendation) -> StreamRowTier {
        if recommendation.isExcluded { return .outsideLimits }
        let reasons = recommendation.reasons
        func has(_ kind: String, positive: Bool) -> Bool {
            reasons.contains { $0.kind.name == kind && $0.positive == positive }
        }
        if has("LANGUAGE", positive: true) || has("ORIGINAL_LANGUAGE", positive: true) { return .yourLanguage }
        if has("OTHER_VARIANT", positive: false) { return .otherVersion }
        if has("SUBTITLED", positive: true) { return .subtitled }
        return .otherLanguages
    }
}

/// Everything a stream row draws, computed once per stream by `StreamsViewModel`.
struct StreamRowInfo {
    /// The big first token of the row: "4K", "1080p", "CAM 720p"; empty when not stated.
    let resolution: String
    /// The rest of the quality line: "Dolby Vision · Atmos · REMUX"; may be empty.
    let qualityExtras: String
    /// "4K · Dolby Vision · Atmos" (VoiceOver, and the fallback check for "nothing technical").
    let quality: String
    let audio: [StreamLanguageChipInfo]
    let subtitles: [StreamLanguageChipInfo]
    let sizeBytes: Int64?
    /// "WEB-DL · YggTorrent · S01E05 · FW" — shown on focus only.
    let detail: String
    let cache: StreamCacheBadge?
    /// Torrent seeders when the cache state says nothing better (shown under the size).
    let seeders: Int?
    /// "VFF · 4K DV · Atmos · Cached" — why this stream ranks where it does.
    let reasons: String
    /// The first hard-filter or downside reason ("Over your size limit"), nil when none.
    let caveat: String?
    let isExcluded: Bool
    let isLowQuality: Bool
    let tier: StreamRowTier
    /// The add-on's own name and description, emoji removed — the "original title".
    let rawTitle: String
    let score: Int
}

enum StreamCacheBadge: Equatable {
    case cached(service: String)
    case download(service: String)
    case direct
}

enum StreamInsightPresenter {

    // MARK: Row info

    static func rowInfo(stream: StreamItem, recommendation: StreamRecommendation) -> StreamRowInfo {
        let insight = recommendation.insight
        let size: Int64? = {
            let value: KotlinLong? = insight.sizeBytes
            return value?.int64Value
        }()
        let seeders: Int? = {
            let value: KotlinInt? = insight.seeders
            guard let value, insight.cacheState.name != "CACHED" else { return nil }
            return Int(value.int32Value)
        }()
        let positive = recommendation.reasons.filter { $0.positive }
        let negative = recommendation.reasons.filter { !$0.positive }
        let headline = qualityHeadline(insight)
        return StreamRowInfo(
            resolution: headline.resolution,
            qualityExtras: headline.extras,
            quality: insight.qualitySummary,
            audio: audioChips(insight),
            subtitles: insight.subtitleLanguages.map { language in
                let name = languageName(language)
                return StreamLanguageChipInfo(text: name, isUncertain: language.confidence == StreamConfidence.low,
                                              accessibilityText: name)
            },
            sizeBytes: size,
            detail: detailLine(insight),
            cache: cacheBadge(insight),
            seeders: seeders,
            reasons: positive.prefix(4).map(reasonText).joined(separator: " \u{00B7} "),
            caveat: negative.first.map(reasonText),
            isExcluded: recommendation.isExcluded,
            isLowQuality: insight.isLowQuality,
            tier: StreamRowTier.from(recommendation),
            rawTitle: rawTitle(stream),
            score: Int(recommendation.score)
        )
    }

    /// "4K" + "Dolby Vision · Atmos · REMUX". A CAM/TS release leads with its source so the
    /// warning is the first thing read ("CAM 720p").
    static func qualityHeadline(_ insight: StreamInsight) -> (resolution: String, extras: String) {
        var resolution = insight.resolution.label
        if insight.isLowQuality {
            resolution = [insight.source.label, resolution].filter { !$0.isEmpty }.joined(separator: " ")
        }
        var extras: [String] = []
        let hdr: StreamHdrFormat? = insight.primaryHdr
        if let hdr { extras.append(hdr.label) }
        if insight.is3D { extras.append("3D") }
        let audio: String? = insight.audioSummary
        if let audio, !audio.isEmpty { extras.append(audio) }
        if insight.source.name == "REMUX" { extras.append(insight.source.label) }
        return (resolution, extras.joined(separator: " \u{00B7} "))
    }

    /// Audio chips: the UI language first (a French viewer reads VFF/VFQ before "Anglais"), then
    /// the rest in the parser's order; then "VO" when the original track is in the file but not
    /// named (MULTi, DUAL, VO).
    static func audioChips(_ insight: StreamInsight) -> [StreamLanguageChipInfo] {
        let uiLanguage = String((Bundle.main.preferredLocalizations.first ?? "en").prefix(2))
        let languages = insight.audioLanguages.enumerated().sorted { lhs, rhs in
            let left = lhs.element.language == uiLanguage ? 0 : 1
            let right = rhs.element.language == uiLanguage ? 0 : 1
            return left != right ? left < right : lhs.offset < rhs.offset
        }.map { $0.element }
        var chips = languages.map { language in
            StreamLanguageChipInfo(
                text: audioLabel(language),
                isUncertain: language.confidence == StreamConfidence.low,
                accessibilityText: audioAccessibilityLabel(language)
            )
        }
        if insight.includesOriginalAudio && insight.audioLanguages.count < 2 {
            let original = String(localized: "streams.chip.original", defaultValue: "VO",
                                  comment: "Source picker audio chip: the original-language track is in the file (version originale).")
            chips.append(StreamLanguageChipInfo(
                text: original,
                isUncertain: insight.originalAudioConfidence == StreamConfidence.low,
                accessibilityText: original
            ))
        }
        return chips
    }

    /// French keeps its release tag so the version is never hidden behind a generic "French":
    /// VFF, VFQ, VFI — and "VF ?" when the release says French without saying which. Other
    /// languages read as their name in the UI language, the Spanish/Portuguese variant kept short
    /// ("Espagnol LAT", "Portugais BR").
    static func audioLabel(_ language: StreamLanguage) -> String {
        if language.language == "fr" {
            return language.variant.name == "UNSPECIFIED" ? "VF\u{202F}?" : language.tag
        }
        let name = languageDisplayName(language.language)
        switch language.variant.name {
        case "LATIN_AMERICA": return "\(name) LAT"
        case "SPAIN": return "\(name) ES"
        case "BRAZIL": return "\(name) BR"
        case "PORTUGAL": return "\(name) PT"
        default: return name
        }
    }

    static func audioAccessibilityLabel(_ language: StreamLanguage) -> String {
        guard language.language == "fr" else { return audioLabel(language) }
        let french = languageDisplayName("fr")
        switch language.variant.name {
        case "FRANCE": return "\(french) VFF"
        case "QUEBEC": return "\(french) VFQ"
        case "INTERNATIONAL": return "\(french) VFI"
        default:
            return String(localized: "streams.a11y.frenchUnknownVersion", defaultValue: "\(french), version not stated",
                          comment: "VoiceOver, source picker: French audio whose version (France/Québec) the release does not state; the chip shows 'VF ?'. %@ is the language name.")
        }
    }

    /// Subtitle chips: the plain language name ("Français"), Québec/Brazil kept as a suffix.
    static func languageName(_ language: StreamLanguage) -> String {
        let name = languageDisplayName(language.language)
        switch language.variant.name {
        case "QUEBEC": return "\(name) CA"
        case "BRAZIL": return "\(name) BR"
        case "LATIN_AMERICA": return "\(name) LAT"
        default: return name
        }
    }

    /// "en" → "Anglais" / "English", in the language the app runs in.
    static func languageDisplayName(_ code: String) -> String {
        let locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        guard let name = locale.localizedString(forLanguageCode: code), !name.isEmpty else { return code.uppercased() }
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// Source · provider · episode · group: secondary facts, shown when the row is focused.
    static func detailLine(_ insight: StreamInsight) -> String {
        var parts: [String] = []
        let source = insight.source.label
        if !source.isEmpty && !insight.isLowQuality && insight.source.name != "REMUX" { parts.append(source) }
        let provider: String? = insight.provider
        if let provider, !provider.isEmpty { parts.append(provider) }
        let episode: String? = insight.episodeLabel
        if let episode, !episode.isEmpty {
            parts.append(insight.isSeasonPack
                ? String(localized: "streams.detail.pack", defaultValue: "\(episode) pack",
                         comment: "Source picker detail line: the stream is a whole-season pack. %@ is the season code, e.g. S01.")
                : episode)
        }
        let group: String? = insight.releaseGroup
        if let group, !group.isEmpty { parts.append(group) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func cacheBadge(_ insight: StreamInsight) -> StreamCacheBadge? {
        let service: String = {
            let value: String? = insight.debridService
            return value ?? ""
        }()
        switch insight.cacheState.name {
        case "CACHED": return .cached(service: service)
        case "NOT_CACHED": return .download(service: service)
        default: return insight.isDirectLink && !insight.isTorrent ? .direct : nil
        }
    }

    static func seedersText(_ count: Int) -> String {
        String(localized: "streams.detail.seeders", defaultValue: "\(count) seeders",
               comment: "Source picker detail line: how many peers share this torrent. %lld is the count.")
    }

    static func rawTitle(_ stream: StreamItem) -> String {
        let name: String? = stream.name
        let description: String? = stream.description_
        let title: String? = stream.title
        let parts = [name, description ?? title]
            .compactMap { $0 }
            .map { StreamInsightText.shared.stripEmojiSingleLine(text: $0) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " \u{2014} ")
    }

    // MARK: Reasons

    static func reasonText(_ reason: StreamReason) -> String {
        let label = reason.label
        switch reason.kind.name {
        case "LANGUAGE", "ORIGINAL_LANGUAGE", "SUBTITLED", "QUALITY", "AUDIO", "SOURCE":
            return label
        case "OTHER_VARIANT":
            return String(localized: "streams.reason.otherVariant", defaultValue: "\(label), not your version",
                          comment: "Source picker reason: right language, other version (e.g. VFQ for a VFF viewer). %@ is the tag.")
        case "LANGUAGE_MISSING":
            return String(localized: "streams.reason.languageMissing", defaultValue: "Not in your language",
                          comment: "Source picker reason: none of the viewer's audio languages.")
        case "CACHED":
            return String(localized: "streams.reason.cached", defaultValue: "Cached",
                          comment: "Source picker reason/chip: the debrid service already has this file, it starts instantly.")
        case "NOT_CACHED":
            return String(localized: "streams.reason.notCached", defaultValue: "Needs downloading",
                          comment: "Source picker reason: the debrid service must download this torrent first.")
        case "DIRECT":
            return String(localized: "streams.reason.direct", defaultValue: "Direct link",
                          comment: "Source picker reason: a plain playable link.")
        case "LOW_QUALITY":
            return String(localized: "streams.reason.lowQuality", defaultValue: "\(label): filmed in a cinema",
                          comment: "Source picker reason: CAM/TS/TC release. %@ is the tag.")
        case "OVER_RESOLUTION":
            return String(localized: "streams.reason.overResolution", defaultValue: "Above your maximum resolution",
                          comment: "Source picker reason: filtered by the max-resolution setting.")
        case "OVER_SIZE":
            return String(localized: "streams.reason.overSize", defaultValue: "Above your size limit",
                          comment: "Source picker reason: filtered by the max-size setting.")
        case "HDR_UNSUPPORTED":
            return String(localized: "streams.reason.hdrUnsupported", defaultValue: "\(label) not supported by this TV",
                          comment: "Source picker reason: HDR/Dolby Vision this display path can't show. %@ is the format.")
        case "HDR_AVOIDED":
            return String(localized: "streams.reason.hdrAvoided", defaultValue: "HDR (you prefer SDR)",
                          comment: "Source picker reason: the viewer asked to avoid HDR.")
        case "THREE_D":
            return "3D"
        case "NO_SEEDERS":
            return String(localized: "streams.reason.noSeeders", defaultValue: "No seeders",
                          comment: "Source picker reason: nobody shares this torrent.")
        default:
            return label
        }
    }

    // MARK: Labels shared with the picker

    static var recommendedLabel: String {
        String(localized: "streams.recommended", defaultValue: "Recommended",
               comment: "Source picker: capsule on the stream that best matches the viewer's preferences.")
    }
}

/// True while the stream row this view sits in has focus (white platter). Reads both signals the
/// `.settingsRow` style publishes (BUG-65: `\.isFocused` alone can die inside a custom style).
fileprivate struct RowFocusReader<Content: View>: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.settingsRowIsFocused) private var rowFocused
    private let content: (Bool) -> Content

    init(@ViewBuilder content: @escaping (Bool) -> Content) {
        self.content = content
    }

    var body: some View { content(isFocused || rowFocused) }
}

/// A language chip sized for the 3 m read. Audio: a solid chip (white with near-black text at
/// rest, inverted on the white focus platter: about 19:1 either way). Subtitles: an outlined chip
/// behind a captions symbol. A deduction the parser is unsure of is dashed and ends with "?" — the
/// difference is never carried by colour alone.
struct StreamLanguageChip: View {
    enum Kind { case audio, subtitle, overflow }

    let text: String
    var kind: Kind = .audio
    var systemImage: String?
    var isUncertain = false

    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 44

    var body: some View {
        RowFocusReader { focused in
            let ink = focused ? Color(hex: 0x0D0D0D) : Color.white
            let paper = focused ? Color.white : Color(hex: 0x0D0D0D)
            let solid = kind == .audio && !isUncertain
            let shape = RoundedRectangle(cornerRadius: StreamBadgeMetrics.cornerRadius, style: .continuous)
            HStack(spacing: Theme.Spacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                }
                Text(isUncertain && !text.hasSuffix("?") ? "\(text)\u{202F}?" : text)
                    .lineLimit(1)
            }
            .font(Theme.Font.meta)
            .foregroundStyle(solid ? paper : ink.opacity(kind == .overflow ? 0.75 : 1))
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(minHeight: height)
            .background(solid ? ink : ink.opacity(kind == .subtitle ? 0.12 : 0), in: shape)
            .overlay {
                if !solid {
                    shape.strokeBorder(
                        ink.opacity(kind == .overflow ? 0.4 : 0.7),
                        style: StrokeStyle(lineWidth: 2, dash: isUncertain ? [6, 4] : [])
                    )
                }
            }
            .fixedSize()
        }
    }
}

/// The audio chips then the subtitle chips of one row, on one line. A `ViewThatFits` ladder
/// folds trailing chips into a "+N" chip (never the first audio one) instead of widening the row.
struct StreamLanguageChipsLine: View {
    let audio: [StreamLanguageChipInfo]
    let subtitles: [StreamLanguageChipInfo]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.candidates(audio: audio.count, subtitles: subtitles.count), id: \.self) { candidate in
                line(audioCount: candidate.audio, subtitleCount: candidate.subtitles)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Candidate: Hashable {
        let audio: Int
        let subtitles: Int
    }

    /// Widest first: every chip, then fewer subtitles, then fewer audio chips (at least one).
    static func candidates(audio: Int, subtitles: Int) -> [Candidate] {
        let shownAudio = min(audio, 4)
        let shownSubtitles = min(subtitles, 3)
        var list: [Candidate] = []
        for subtitleCount in stride(from: shownSubtitles, through: 0, by: -1) {
            list.append(Candidate(audio: shownAudio, subtitles: subtitleCount))
        }
        for audioCount in stride(from: shownAudio - 1, through: min(1, shownAudio), by: -1) {
            list.append(Candidate(audio: audioCount, subtitles: 0))
        }
        return list
    }

    private func line(audioCount: Int, subtitleCount: Int) -> some View {
        let hidden = (audio.count - audioCount) + (subtitles.count - subtitleCount)
        return HStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(audio.prefix(audioCount).enumerated()), id: \.offset) { index, chip in
                StreamLanguageChip(text: chip.text, kind: .audio,
                                   systemImage: index == 0 ? "speaker.wave.2.fill" : nil,
                                   isUncertain: chip.isUncertain)
            }
            ForEach(Array(subtitles.prefix(subtitleCount).enumerated()), id: \.offset) { index, chip in
                StreamLanguageChip(text: chip.text, kind: .subtitle,
                                   systemImage: index == 0 ? "captions.bubble" : nil,
                                   isUncertain: chip.isUncertain)
            }
            if hidden > 0 {
                StreamLanguageChip(text: "+\(hidden)", kind: .overflow)
            }
        }
    }
}

/// The right-hand column of a row: the size, big and aligned, with the ready-to-play state under
/// it (cached on the debrid service, needs downloading, direct link, or the torrent's seeders).
struct StreamSizeColumn: View {
    let sizeBytes: Int64?
    let cache: StreamCacheBadge?
    let seeders: Int?
    /// The viewer's file-size badge setting: off hides the size (an unknown size shows a dash).
    var showsSize = true

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
            if showsSize {
                Text(sizeBytes.map { StreamFileSizeChip.label(for: $0) } ?? "\u{2014}")
                    .font(Theme.Font.sectionTitle.monospacedDigit())
                    .rowTextColor(secondary: sizeBytes == nil)
                    .lineLimit(1)
            }
            if let state = stateLine {
                Label(state.text, systemImage: state.symbol)
                    .font(Theme.Font.caption)
                    .rowTextColor(secondary: !state.emphasized)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var stateLine: (text: String, symbol: String, emphasized: Bool)? {
        let cached = StreamInsightPresenter.reasonText(StreamReason(kind: .cached, label: "", positive: true))
        switch cache {
        case .cached(let service):
            return (service.isEmpty ? cached : "\(service) \u{00B7} \(cached)", "bolt.fill", true)
        case .download(let service):
            let download = StreamInsightPresenter.reasonText(StreamReason(kind: .notCached, label: "", positive: false))
            return (service.isEmpty ? download : "\(service) \u{00B7} \(download)", "arrow.down.circle", false)
        case .direct:
            return (StreamInsightPresenter.reasonText(StreamReason(kind: .direct, label: "", positive: true)), "link", true)
        case nil:
            guard let seeders else { return nil }
            return (StreamInsightPresenter.seedersText(seeders), "person.2.fill", false)
        }
    }
}

/// The "Recommended" / "Best Match" / "Last Used" capsule: solid (white with near-black text at
/// rest, inverted on the focus platter) so the pick is the first thing the eye lands on.
struct StreamPickCapsule: View {
    let text: String
    var systemImage: String?

    var body: some View {
        RowFocusReader { focused in
            HStack(spacing: Theme.Spacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .imageScale(.small)
                }
                Text(text)
                    .lineLimit(1)
            }
            .font(Theme.Font.meta)
            .foregroundStyle(focused ? Color.white : Color(hex: 0x0D0D0D))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Capsule().fill(focused ? Color(hex: 0x0D0D0D) : Color.white))
            .fixedSize()
        }
    }
}

/// Text shown only while its row has focus — the slot keeps its height, so nothing moves.
struct StreamFocusRevealText: View {
    let text: String

    var body: some View {
        RowFocusReader { focused in
            Text(text)
                .font(Theme.Font.caption)
                .rowTextColor(secondary: true)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(focused ? 1 : 0)
        }
    }
}

/// Wiring for the player (spec item 5), kept out of the player files: the audio-language targets
/// with the stream settings' explicit version first ("fr-ca" for a Québec viewer, so a MULTi
/// VFF+VFQ file opens on the VFQ track). Call from the audio-target resolution with that
/// resolution's own targets as `base`; returns them unchanged when the feature is off or set to
/// "Same as Audio Language".
enum StreamPlaybackAudioHints {
    static func audioTargets(context: PlaybackContext, base: [String], originalLanguage: String?) -> [String] {
        StreamPlaybackLanguageHints.shared.audioTargets(
            streamName: context.streamTitle,
            streamDescription: context.streamSubtitle,
            url: context.url.absoluteString,
            baseTargets: base,
            originalLanguage: originalLanguage
        )
    }
}
