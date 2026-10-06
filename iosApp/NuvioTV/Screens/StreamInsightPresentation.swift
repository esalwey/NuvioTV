import AVFoundation
import SwiftUI
import SharedCore

// STREAM-INSIGHT: the tvOS face of the shared stream parser and recommender
// (`StreamInsightParser`, `StreamRecommender`, `StreamRankingSettingsRepository` in SharedCore).
// Kotlin reads the messy add-on title; this file turns the result into what a row shows — a
// quality line, audio/subtitle language chips with the French version always visible (VFF, VFQ,
// VF), size, source/provider, cache state and the reasons behind the "Recommended" pick. SF
// Symbols only: every add-on emoji is stripped before display.

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

/// One language chip ("VFF", "Anglais", "Français" under a captions symbol).
struct StreamLanguageChipInfo: Hashable {
    let text: String
    /// Low-confidence deductions (a lone 🇨🇦 flag, a bare MULTi) read as a question.
    let isUncertain: Bool
}

/// Everything a stream row draws, computed once per stream by `StreamsViewModel`.
struct StreamRowInfo {
    /// "4K · Dolby Vision · Atmos"; empty when the title states nothing technical.
    let quality: String
    let audio: [StreamLanguageChipInfo]
    let subtitles: [StreamLanguageChipInfo]
    let sizeBytes: Int64?
    /// "WEB-DL · YggTorrent · 152 seeders · S01E05 · FW".
    let detail: String
    let cache: StreamCacheBadge?
    /// "VFF · 4K DV · Atmos · Cached" — why this stream ranks where it does.
    let reasons: String
    /// The first hard-filter or downside reason ("Over your size limit"), nil when none.
    let caveat: String?
    let isExcluded: Bool
    let isLowQuality: Bool
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
        let positive = recommendation.reasons.filter { $0.positive }
        let negative = recommendation.reasons.filter { !$0.positive }
        return StreamRowInfo(
            quality: insight.qualitySummary,
            audio: audioChips(insight),
            subtitles: insight.subtitleLanguages.prefix(3).map { language in
                StreamLanguageChipInfo(text: languageName(language), isUncertain: language.confidence == StreamConfidence.low)
            },
            sizeBytes: size,
            detail: detailLine(insight),
            cache: cacheBadge(insight),
            reasons: positive.prefix(4).map(reasonText).joined(separator: " \u{00B7} "),
            caveat: negative.first.map(reasonText),
            isExcluded: recommendation.isExcluded,
            isLowQuality: insight.isLowQuality,
            rawTitle: rawTitle(stream),
            score: Int(recommendation.score)
        )
    }

    /// Audio chips: every detected language; then "VO" when the original track is in the file
    /// but not named (MULTi, DUAL, VO, VOSTFR).
    static func audioChips(_ insight: StreamInsight) -> [StreamLanguageChipInfo] {
        var chips = insight.audioLanguages.prefix(4).map { language in
            StreamLanguageChipInfo(text: audioLabel(language), isUncertain: language.confidence == StreamConfidence.low)
        }
        if insight.includesOriginalAudio && insight.audioLanguages.count < 2 {
            chips.append(StreamLanguageChipInfo(
                text: String(localized: "streams.chip.original", defaultValue: "VO",
                             comment: "Source picker audio chip: the original-language track is in the file (version originale)."),
                isUncertain: insight.originalAudioConfidence == StreamConfidence.low
            ))
        }
        return chips
    }

    /// French keeps its release tag — VFF, VFQ, VFI, VF — so the version is never hidden behind
    /// a generic "French". Other languages read as their name in the UI language, with the
    /// Spanish/Portuguese variant kept short ("Espagnol LAT", "Portugais BR").
    static func audioLabel(_ language: StreamLanguage) -> String {
        if language.language == "fr" { return language.tag }
        let name = languageDisplayName(language.language)
        switch language.variant.name {
        case "LATIN_AMERICA": return "\(name) LAT"
        case "SPAIN": return "\(name) ES"
        case "BRAZIL": return "\(name) BR"
        case "PORTUGAL": return "\(name) PT"
        default: return name
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

    static func detailLine(_ insight: StreamInsight) -> String {
        var parts: [String] = []
        let source = insight.source.label
        if !source.isEmpty && !insight.isLowQuality { parts.append(source) }
        let provider: String? = insight.provider
        if let provider, !provider.isEmpty { parts.append(provider) }
        let seeders: KotlinInt? = insight.seeders
        if let seeders, insight.cacheState != .cached {
            let count = Int(seeders.int32Value)
            parts.append(String(
                localized: "streams.detail.seeders",
                defaultValue: "\(count) seeders",
                comment: "Source picker detail line: how many peers share this torrent. %lld is the count."
            ))
        }
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

/// A small fixed-colour chip (dark fill, white text): legible on the resting row and on the
/// white focus platter alike — the same fixed/fixed rule as `StreamFileSizeChip` (BUG-28).
struct StreamInfoChip: View {
    let text: String
    var systemImage: String?
    var isUncertain: Bool = false
    var emphasized: Bool = false

    static let height: CGFloat = 34

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: StreamBadgeMetrics.cornerRadius, style: .continuous)
        HStack(spacing: Theme.Spacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
            }
            Text(isUncertain ? "\(text)?" : text)
                .lineLimit(1)
        }
        .font(Theme.Font.caption.weight(.semibold))
        .foregroundStyle(Color.white.opacity(isUncertain ? 0.75 : 1))
        .padding(.horizontal, Theme.Spacing.sm)
        .frame(minHeight: Self.height)
        .background(emphasized ? Color.white.opacity(0.28) : Theme.Palette.surfaceElevated, in: shape)
        .overlay(shape.stroke(Color.white.opacity(isUncertain ? 0.1 : 0.18), lineWidth: 1))
        .fixedSize()
    }
}

/// The audio chips, subtitle chips and cache state of one row, on one line. A `ViewThatFits`
/// ladder drops trailing chips (never the first audio one) instead of widening the row.
struct StreamLanguageChipsRow: View {
    let info: StreamRowInfo
    let sizeBytes: Int64?

    var body: some View {
        let audio = info.audio
        let subtitles = info.subtitles
        ViewThatFits(in: .horizontal) {
            content(audioCount: audio.count, subtitleCount: subtitles.count, showCache: true)
            content(audioCount: audio.count, subtitleCount: min(1, subtitles.count), showCache: true)
            content(audioCount: min(2, audio.count), subtitleCount: min(1, subtitles.count), showCache: true)
            content(audioCount: min(2, audio.count), subtitleCount: 0, showCache: true)
            content(audioCount: min(1, audio.count), subtitleCount: 0, showCache: false)
        }
        .frame(maxWidth: .infinity, minHeight: StreamInfoChip.height, alignment: .leading)
    }

    private func content(audioCount: Int, subtitleCount: Int, showCache: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let sizeBytes {
                StreamInfoChip(text: StreamFileSizeChip.label(for: sizeBytes), systemImage: "internaldrive")
            }
            ForEach(Array(info.audio.prefix(audioCount).enumerated()), id: \.offset) { index, chip in
                StreamInfoChip(text: chip.text, systemImage: index == 0 ? "speaker.wave.2.fill" : nil,
                               isUncertain: chip.isUncertain, emphasized: index == 0)
            }
            ForEach(Array(info.subtitles.prefix(subtitleCount).enumerated()), id: \.offset) { index, chip in
                StreamInfoChip(text: chip.text, systemImage: index == 0 ? "captions.bubble.fill" : nil,
                               isUncertain: chip.isUncertain)
            }
            if showCache, let cache = info.cache {
                cacheChip(cache)
            }
        }
    }

    @ViewBuilder
    private func cacheChip(_ cache: StreamCacheBadge) -> some View {
        switch cache {
        case .cached(let service):
            StreamInfoChip(
                text: service.isEmpty
                    ? StreamInsightPresenter.reasonText(StreamReason(kind: .cached, label: "", positive: true))
                    : "\(service) \(StreamInsightPresenter.reasonText(StreamReason(kind: .cached, label: "", positive: true)))",
                systemImage: "bolt.fill"
            )
        case .download(let service):
            StreamInfoChip(text: service.isEmpty ? "P2P" : service, systemImage: "arrow.down.circle", isUncertain: false)
                .opacity(0.8)
        case .direct:
            StreamInfoChip(
                text: StreamInsightPresenter.reasonText(StreamReason(kind: .direct, label: "", positive: true)),
                systemImage: "link"
            )
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
