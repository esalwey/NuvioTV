import Foundation
import SharedCore

/// Readable names for audio and subtitle tracks, shared by both engines (LANG-03/04/07, spec §8.2,
/// contract C3). Languages come out as the system names them in the viewer's language
/// ("Français", "Anglais", "Portugais (Brésil)"), never as raw codes ("fre", "pt-BR"). ISO 639-2/B
/// codes, release tags (VFF/VFQ) and native names go through the shared normalizer first, so both
/// engines and the Kotlin matcher agree on what a track's language is.
///
/// Pure and nonisolated: the native engine calls it from its remux worker.
nonisolated enum TrackLabelFormatter {

    // MARK: - Contract C3

    /// The localized language name for `code` ("fre" → "Français" in a French UI), or nil when the
    /// code names no language (blank, "und", an option word, a track title that is not a language).
    static func languageName(_ code: String?) -> String? {
        guard let tag = normalizedTag(code) else { return nil }
        let locale = Locale.current
        if let name = locale.localizedString(forIdentifier: tag), !name.isEmpty,
           name.lowercased() != tag.lowercased() {
            return capitalizedFirst(name, locale: locale)
        }
        let base = String(tag.split(separator: "-").first ?? Substring(tag))
        if base != tag, let name = locale.localizedString(forLanguageCode: base), !name.isEmpty,
           name.lowercased() != base {
            return capitalizedFirst(name, locale: locale)
        }
        return nil
    }

    /// The BCP 47 tag for `code`: ISO 639-2/B and T codes become 639-1 ("fre"/"fra" → "fr"),
    /// regions are upper-cased ("pt-BR", "fr-CA", "zh-TW"), UN M.49 areas kept ("es-419"). Nil
    /// when the input is not a language.
    static func normalizedTag(_ code: String?) -> String? {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let normalized = PlayerLanguagePreferencesKt.normalizeLanguageCode(language: raw)
        else { return nil }
        let parts = normalized.split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased(), isLanguageSubtag(primary),
              !nonLanguageCodes.contains(primary)
        else { return nil }
        var subtags: [String] = []
        for part in parts.dropFirst() {
            guard !part.isEmpty, part.count <= 8, part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            else { return nil }
            if part.count == 2, part.allSatisfy(\.isLetter) {
                subtags.append(part.uppercased())                       // region
            } else if part.count == 4, part.allSatisfy(\.isLetter) {
                subtags.append(part.prefix(1).uppercased() + part.dropFirst().lowercased())   // script
            } else {
                subtags.append(part.lowercased())                       // "419", variants
            }
        }
        return ([primary] + subtags).joined(separator: "-")
    }

    /// "Dolby Digital+ 5.1", "AAC Stereo", "Dolby Atmos" (Atmos wins over the codec and layout,
    /// like the TV app). Nil when nothing is known.
    static func audioDetail(codec: String?, channels: Int?, atmos: Bool) -> String? {
        if atmos { return "Dolby Atmos" }
        let parts = [audioCodecName(codec), channelLayout(channels)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "Forced", "SDH", "Forced · SDH"; nil for a plain track.
    static func subtitleDetail(forced: Bool, sdh: Bool) -> String? {
        var parts: [String] = []
        if forced { parts.append(forcedLabel) }
        if sdh { parts.append(sdhLabel) }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    // MARK: - Beyond the contract

    /// `subtitleDetail(forced:sdh:)` plus the subtitle format ("Forced · SRT", "PGS").
    static func subtitleDetail(forced: Bool, sdh: Bool, codec: String?) -> String? {
        let parts = [subtitleDetail(forced: forced, sdh: sdh), subtitleCodecName(codec)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// The separator between a track's descriptors.
    static let separator = " \u{00B7} "

    /// A subtitle title that marks SDH / closed captions ("English SDH", "Français (SME)").
    static func looksSdh(_ title: String?) -> Bool {
        PlayerTrackSelectionKt.subtitleTextLooksSdh(text: title)
    }

    /// A title that marks Atmos ("English Atmos", "TrueHD 7.1 Atmos").
    static func looksAtmos(_ text: String?) -> Bool {
        guard let text = text?.lowercased() else { return false }
        return text.contains("atmos") || text.contains("joc")
    }

    /// The file's own track title when it says something the language name and the descriptors
    /// don't ("Commentary", "Signs & Songs", "Director's cut"), else nil. A title that is only a
    /// language name, a release tag, "Forced"/"SDH" or a codec repeats the row and is dropped.
    static func titleDescriptor(_ title: String?, language: String?) -> String? {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        if let titleTag = normalizedTag(title) {
            let titleBase = titleTag.split(separator: "-").first.map(String.init)
            let languageBase = normalizedTag(language)?.split(separator: "-").first.map(String.init)
            if languageBase == nil || titleBase == languageBase { return nil }
        }
        let words = title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if !words.isEmpty, words.allSatisfy({ redundantTitleWords.contains($0) }) { return nil }
        if let languageTitle = languageName(language), title.caseInsensitiveCompare(languageTitle) == .orderedSame {
            return nil
        }
        return title
    }

    // MARK: - Private

    private static let forcedLabel = String(localized: "player.track.forced", defaultValue: "Forced",
                                            comment: "Subtitle track descriptor: forced (signs and foreign dialogue only).")
    private static let sdhLabel = String(localized: "player.track.sdh", defaultValue: "SDH",
                                         comment: "Subtitle track descriptor: subtitles for the deaf and hard of hearing.")

    /// Codes the normalizer can return that are not languages (settings options, ISO "undetermined").
    private static let nonLanguageCodes: Set<String> = [
        "und", "unk", "mul", "mis", "zxx", "qaa", "none", "off", "forced", "default", "device", "original",
        "sdh", "cc", "vo", "vost", "track",
    ]

    private static let redundantTitleWords: Set<String> = [
        "forced", "force", "forces", "forcé", "forcés", "sdh", "cc", "hi", "sme", "full", "complete", "default",
        "srt", "subrip", "ass", "ssa", "pgs", "sup", "vobsub", "webvtt", "vtt", "text",
        "vff", "vfq", "vfi", "vf", "vf2", "vof", "truefrench",
        "aac", "ac3", "eac3", "dd", "ddp", "dts", "truehd", "atmos", "flac", "opus", "stereo", "mono",
        "1", "2", "5", "6", "7", "8", "0", "ch",
    ]

    private static func isLanguageSubtag(_ value: String) -> Bool {
        (2...3).contains(value.count) && value.allSatisfy { $0.isASCII && $0.isLetter }
    }

    private static func capitalizedFirst(_ value: String, locale: Locale) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased(with: locale) + value.dropFirst()
    }

    private static func audioCodecName(_ codec: String?) -> String? {
        guard let raw = codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        if raw.contains("truehd") || raw == "mlp" { return "Dolby TrueHD" }
        if raw.hasPrefix("eac3") || raw.hasPrefix("e-ac-3") || raw == "ec-3" || raw == "ec3" || raw == "ddp"
            || raw.contains("dolby digital plus") {
            return "Dolby Digital+"
        }
        if raw.hasPrefix("ac3") || raw == "ac-3" || raw == "a52" || raw.contains("dolby digital") {
            return "Dolby Digital"
        }
        if raw.hasPrefix("dts") || raw.hasPrefix("dca") {
            if raw.contains("dts:x") || raw.contains("dtsx") || raw.contains("dts-x") { return "DTS:X" }
            if raw.contains("ma") { return "DTS-HD MA" }
            if raw.contains("hra") || raw.contains("hi res") || raw.contains("hr") { return "DTS-HD HRA" }
            if raw.contains("express") { return "DTS Express" }
            return "DTS"
        }
        if raw.hasPrefix("aac") || raw == "mp4a" || raw.contains("he-aac") { return "AAC" }
        if raw.hasPrefix("opus") { return "Opus" }
        if raw.hasPrefix("vorbis") { return "Vorbis" }
        if raw.hasPrefix("flac") { return "FLAC" }
        if raw.hasPrefix("alac") { return "ALAC" }
        if raw.hasPrefix("mp3") { return "MP3" }
        if raw.hasPrefix("mp2") { return "MP2" }
        if raw.hasPrefix("pcm") || raw == "lpcm" { return "PCM" }
        return raw.uppercased()
    }

    private static func channelLayout(_ channels: Int?) -> String? {
        guard let channels, channels > 0 else { return nil }
        switch channels {
        case 1: return String(localized: "player.track.mono", defaultValue: "Mono",
                              comment: "Audio track descriptor: one channel.")
        case 2: return String(localized: "player.track.stereo", defaultValue: "Stereo",
                              comment: "Audio track descriptor: two channels.")
        case 3: return "2.1"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    private static func subtitleCodecName(_ codec: String?) -> String? {
        guard let raw = codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "subrip", "srt": return "SRT"
        case "ass": return "ASS"
        case "ssa": return "SSA"
        case "webvtt", "vtt": return "WebVTT"
        case "hdmv_pgs_subtitle", "pgs", "pgssub": return "PGS"
        case "dvd_subtitle", "vobsub": return "VobSub"
        case "dvb_subtitle": return "DVB"
        case "mov_text", "tx3g": return "Timed Text"
        case "eia_608", "cea-608", "cc_dec": return "CEA-608"
        case "ttml", "stpp": return "TTML"
        default: return raw.uppercased()
        }
    }
}

/// Swift side of the shared `SubtitleLanguageLabeler` seam (LANG-03): addon subtitle labels
/// ("Français (OpenSubtitles)") read as language names instead of upper-cased codes. Called from a
/// Kotlin background dispatcher, hence nonisolated.
nonisolated final class TrackLanguageLabeler: NSObject, BlockingSubtitleLanguageLabeler {
    func label(code: String?) -> String {
        if let name = TrackLabelFormatter.languageName(code) { return name }
        return code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    }
}
