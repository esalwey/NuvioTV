import Foundation
import SharedCore

// D5 of the hybrid player: external subtitles on the native path. Addon subtitles arrive as SRT
// (occasionally VTT) URLs in `PlaybackContext.externalSubtitles`; the native player exposes them as
// WebVTT SUBTITLES renditions in the synthesized HLS master, so AVPlayer's built-in subtitle menu,
// styling and accessibility settings all apply. `LocalHLSServer` serves `sub-N.m3u8` (single-segment
// VOD playlist) + `sub-N.vtt` (downloaded and converted just-in-time, cached per session).
//
// Cue timing needs no offset bookkeeping: SRT times are relative to the file start, which is exactly
// the playlist origin, and a lone VTT segment at playlist t=0 with no X-TIMESTAMP-MAP is interpreted
// on the playlist timeline directly.

/// One subtitle rendition offered in the master playlist — an addon/stream-attached file served as
/// a single VTT, or a text track EMBEDDED in the source (info-panel W2), produced by the remux worker
/// as per-segment WebVTT files aligned to the video segment map (`EmbeddedSubtitleSink`).
nonisolated struct SubtitleRendition: Sendable {
    enum Source: Sendable {
        case remote(URL)                 // sub-<index>.m3u8 → one whole-file sub-<index>.vtt
        case embedded(sink: Int)         // esub-<sink>.m3u8 → esub-<sink>-NNNNN.vtt per segment
    }
    let index: Int          // position in the master's SUBTITLES group
    let name: String        // menu display name (unique within the group)
    let language: String?   // RFC 5646-ish tag when known
    let source: Source
    var forced: Bool = false
    var hearingImpaired: Bool = false

    var isEmbedded: Bool { if case .embedded = source { return true }; return false }
    var sourceURL: URL? { if case .remote(let url) = source { return url }; return nil }
    var playlistName: String {
        switch source {
        case .remote: return "sub-\(index).m3u8"
        case .embedded(let sink): return "esub-\(sink).m3u8"
        }
    }
    /// Whole-file VTT name (remote source only).
    var fileName: String { "sub-\(index).vtt" }
    /// Per-segment VTT name for an embedded rendition (`esub-<sink>-NNNNN.vtt`).
    static func embeddedSegmentName(sink: Int, segment: Int) -> String {
        String(format: "esub-%d-%05d.vtt", sink, segment)
    }
    /// Parse `esub-<sink>-NNNNN.vtt` → (sink, segment).
    static func parseEmbeddedSegmentName(_ name: String) -> (sink: Int, segment: Int)? {
        guard name.hasPrefix("esub-"), name.hasSuffix(".vtt") else { return nil }
        let core = name.dropFirst(5).dropLast(4)
        let parts = core.split(separator: "-")
        guard parts.count == 2, let sink = Int(parts[0]), let seg = Int(parts[1]) else { return nil }
        return (sink, seg)
    }
}

/// Master-playlist flags for one subtitle rendition, decided by the coordinator's language plan
/// (AUTOSELECT: may the system pick it automatically; DEFAULT: start with it on).
nonisolated struct SubtitleRenditionFlags: Sendable, Equatable {
    let autoselect: Bool
    let isDefault: Bool
    /// Legacy behaviour (no plan): AUTOSELECT=YES, DEFAULT=NO.
    static let legacy = SubtitleRenditionFlags(autoselect: true, isDefault: false)
}

/// A source language code resolved by the caller (LANG-07): the normalized BCP 47 tag (`fre` →
/// `fr`, `pt-br` → `pt-BR`) the master's `LANGUAGE` attribute carries, and the localized language
/// name the menus show. Resolved on the main actor through `TrackLabelFormatter` and handed in as a
/// plain value, so this nonisolated converter never calls it.
nonisolated struct SubtitleLanguageLabel: Sendable, Equatable {
    let tag: String?
    let name: String?
}

nonisolated enum SubtitleVTT {
    /// Most addon/stream subtitle renditions one master carries (LANG-05: at most 4 per language,
    /// 24 in total, after the caller's ranking).
    static let maxAddonRenditions = 24

    /// Build the rendition list from the addon-provided files: parse language tags, synthesize
    /// unique menu names, drop duplicates, cap the count (a debrid title can carry dozens).
    /// `labels` maps a file's raw language value to its normalized tag/name (LANG-07); a value with
    /// no entry keeps the local parsing.
    static func renditions(from subs: [SubtitleFile],
                           labels: [String: SubtitleLanguageLabel] = [:],
                           maxCount: Int = maxAddonRenditions) -> [SubtitleRendition] {
        var seenURLs = Set<String>()
        var seenNames = Set<String>()
        var out: [SubtitleRendition] = []
        for sub in subs {
            guard out.count < maxCount else { break }
            guard let url = URL(string: sub.url), !sub.url.isEmpty, seenURLs.insert(sub.url).inserted else { continue }
            let label = labels[sub.language]
            let tag = label?.tag ?? languageTag(sub.language)
            var name = displayName(name: sub.name, language: sub.language, tag: tag, label: label)
            if !seenNames.insert(name).inserted {
                var n = 2
                while !seenNames.insert("\(name) \(n)").inserted { n += 1 }
                name = "\(name) \(n)"
            }
            out.append(SubtitleRendition(index: out.count, name: name, language: tag, source: .remote(url)))
        }
        return out
    }

    /// Renditions for the source's embedded TEXT subtitle tracks (in `tracks` order = sink index),
    /// numbered after `existing` (the addon renditions) and named uniquely against them:
    /// "English", "English (SDH)", "English (Forced)", "English · Commentary".
    static func embeddedRenditions(tracks: [RemuxSubtitleTrack], availableSinks: Set<Int>,
                                   after existing: [SubtitleRendition],
                                   labels: [String: SubtitleLanguageLabel] = [:]) -> [SubtitleRendition] {
        var seenNames = Set(existing.map(\.name))
        var out: [SubtitleRendition] = []
        var sink = -1
        for track in tracks where track.isText {
            sink += 1
            guard availableSinks.contains(sink) else { continue }   // no decoder → no rendition
            let label = track.language.flatMap { labels[$0] }
            let tag = label?.tag ?? track.language.flatMap { languageTag($0) }
            var base: String
            if let localized = label?.name ?? tag.flatMap({ Locale.current.localizedString(forIdentifier: $0) }) {
                base = localized.prefix(1).uppercased() + localized.dropFirst()
            } else {
                base = String(localized: "Subtitles")
            }
            if let title = track.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
               title.lowercased() != base.lowercased() {
                // "English (SDH)" / "English Commentary" already name the language — use as-is;
                // "Commentary" / "Signs & Songs" get the language prefixed.
                base = title.lowercased().hasPrefix(base.lowercased())
                    ? String(title.prefix(48))
                    : base + " \u{00B7} \(String(title.prefix(40)))"
            }
            if track.hearingImpaired, !base.localizedCaseInsensitiveContains("SDH") { base += " (SDH)" }
            if track.forced, !base.localizedCaseInsensitiveContains("forced") { base += " (\(String(localized: "Forced")))" }
            var name = base
            if !seenNames.insert(name).inserted {
                var n = 2
                while !seenNames.insert("\(base) \(n)").inserted { n += 1 }
                name = "\(base) \(n)"
            }
            out.append(SubtitleRendition(index: existing.count + out.count, name: name, language: tag,
                                         source: .embedded(sink: sink),
                                         forced: track.forced, hearingImpaired: track.hearingImpaired))
        }
        return out
    }

    /// WebVTT timestamp for a playlist time in seconds.
    static func vttTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let total = Int(clamped)
        let millis = Int(((clamped - Double(total)) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", total / 3600, (total % 3600) / 60, total % 60, min(millis, 999))
    }

    /// Cue text from a plain-text subtitle rectangle (`AVSubtitleRect.text`): markup cleanup and
    /// WebVTT escaping only — no ASS field split (plain sentences may contain any number of commas).
    /// `stripSdh` = Settings → Playback → Strip SDH Subtitles (SDH stripping, native path — the mpv
    /// path sets `sub-filter-sdh` instead): the shared filter runs AFTER markup cleanup (Codex
    /// round 4: an override/tag before a speaker label — `{\an8}JOHN:` — hid the label from the
    /// regexes when filtering raw text) and before VTT escaping; a cue that filters to nothing
    /// returns "" (callers skip empty cues).
    static func vttCueText(fromPlainText raw: String, stripSdh: Bool = false) -> String {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cleaned = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { cleanCueText(String($0)) }
            .joined(separator: "\n")
        if stripSdh {
            guard let kept = SubtitleSdhFilter.shared.filter(text: cleaned) else { return "" }
            cleaned = kept
        }
        return escapeVTT(cleaned)
    }

    private static func escapeVTT(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "-->", with: "→")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cue text from a decoded ASS dialogue line as libavcodec's subtitle decoders emit it in
    /// `AVSubtitleRect.ass` ("ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"):
    /// take the Text field, unescape ASS line breaks, strip `{\override}` blocks and `<font>`, and
    /// escape the two characters WebVTT reserves. `stripSdh`: see `vttCueText(fromPlainText:stripSdh:)`.
    static func vttCueText(fromASSLine line: String, stripSdh: Bool = false) -> String {
        // The text is everything after the 8th comma (Text itself may contain commas).
        var text = line
        var commas = 0
        var cut = line.startIndex
        for i in line.indices where line[i] == "," {
            commas += 1
            if commas == 8 { cut = line.index(after: i); break }
        }
        if commas >= 8 { text = String(line[cut...]) }
        text = text.replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: "\u{00A0}")
        var cleaned = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { cleanCueText(String($0)) }
            .joined(separator: "\n")
        if stripSdh {
            // SDH stripping, native path (mpv path sets sub-filter-sdh instead). Runs AFTER
            // cleanCueText (Codex round 4): an ASS override before a label — `{\an8}JOHN: Hello`
            // — hid the label from the shared regexes when filtering the raw text.
            guard let kept = SubtitleSdhFilter.shared.filter(text: cleaned) else { return "" }
            cleaned = kept
        }
        return escapeVTT(cleaned)
    }

    /// A usable RFC 5646-ish tag ("en", "eng", "pt-BR") or nil when the value is a display word.
    private static func languageTag(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 11 else { return nil }
        let parts = trimmed.split(separator: "-")
        guard (1...2).contains(parts.count),
              let first = parts.first, (2...3).contains(first.count),
              parts.allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isNumber } }) else { return nil }
        return parts.count == 2
            ? "\(first.lowercased())-\(parts[1].uppercased())"
            : first.lowercased()
    }

    private static func displayName(name: String?, language: String, tag: String?,
                                    label: SubtitleLanguageLabel? = nil) -> String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            // A "name" that is only the language code again ("fre", "pt-br") reads as a raw code
            // in the menu (LANG-07): show the language name instead.
            let isBareCode = trimmed.caseInsensitiveCompare(language.trimmingCharacters(in: .whitespaces)) == .orderedSame
                || (tag != nil && languageTag(trimmed) == tag)
            if !isBareCode { return String(trimmed.prefix(48)) }
        }
        if let localized = label?.name ?? tag.flatMap({ Locale.current.localizedString(forIdentifier: $0) }) {
            return localized.prefix(1).uppercased() + localized.dropFirst()
        }
        let lang = language.trimmingCharacters(in: .whitespaces)
        return lang.isEmpty ? String(localized: "Subtitles") : String(lang.prefix(48))
    }

    // MARK: - Conversion

    /// Decode a downloaded subtitle file and return WebVTT text, or nil when it is unusable.
    /// Accepts SRT (converted) and WebVTT (passed through after cleanup).
    /// `stripSdh` = Settings → Playback → Strip SDH Subtitles (SDH stripping, native path — the mpv
    /// path sets `sub-filter-sdh` instead): cue PAYLOAD lines run through the shared filter before
    /// markup cleanup; header/timing lines are never touched. A payload line that filters to nothing
    /// is dropped (a cue whose lines all drop keeps its timing line and renders empty — harmless).
    static func webVTT(from data: Data, stripSdh: Bool = false, offsetMs: Int = 0) -> String? {
        guard let base = convert(data, stripSdh: stripSdh) else { return nil }
        return offsetMs == 0 ? base : shift(base, offsetMs: offsetMs)
    }

    private static func convert(_ data: Data, stripSdh: Bool) -> String? {
        guard var text = decode(data) else { return nil }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        if text.hasPrefix("WEBVTT") { return stripSdh ? stripSdhFromCuePayloads(text) : text }

        var lines = [String]()
        var previousBlank = true                     // file start behaves like after-a-blank
        var inCue = false                            // between a timing line and the next blank
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if let cueTiming = vttTiming(from: line) {
                // A bare SRT cue counter directly above the timing line must not become a VTT cue
                // identifier that LOOKS like content — drop it for cleanliness.
                if let last = lines.last, !previousBlank, Int(last.trimmingCharacters(in: .whitespaces)) != nil {
                    lines.removeLast()
                }
                lines.append(cueTiming)
                previousBlank = false
                inCue = true
            } else {
                let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
                if blank { inCue = false }
                if stripSdh, inCue {
                    if let kept = SubtitleSdhFilter.shared.filter(text: line) {
                        lines.append(cleanCueText(kept))
                    }
                    previousBlank = false
                } else {
                    lines.append(cleanCueText(line))
                    previousBlank = blank
                }
            }
        }
        let body = lines.joined(separator: "\n")
        // A subtitle file with no timing lines at all converted to nothing useful — treat as bad.
        guard body.contains("-->") else { return nil }
        return "WEBVTT\n\n" + body
    }

    // MARK: - Re-timing (subtitle delay, native engine)

    /// Shift every cue of a WebVTT document by `offsetMs` (positive = subtitles appear LATER).
    /// Header lines — `WEBVTT`, `X-TIMESTAMP-MAP`, `NOTE`/`STYLE`/`REGION` blocks — pass through
    /// untouched; a cue whose END lands at or before zero is dropped entirely (it can never be shown
    /// on a playlist whose origin is zero), a cue that straddles zero is clamped to start at 0 so it
    /// is still visible for its remaining span. Cue settings after the end timestamp
    /// (`line:90% align:middle`) are preserved verbatim.
    ///
    /// Cues are addressed as blank-line-separated blocks, which is how both our SRT conversion and
    /// every real-world VTT are laid out; a block with no timing line is copied through.
    static func shift(_ vtt: String, offsetMs: Int) -> String {
        guard offsetMs != 0 else { return vtt }
        let lines = vtt.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var block: [String] = []

        func flush() {
            defer { block = [] }
            guard let timingIdx = block.firstIndex(where: { $0.contains("-->") }) else {
                out.append(contentsOf: block)
                return
            }
            guard let shifted = shiftTiming(block[timingIdx], offsetMs: offsetMs) else { return } // cue dropped
            var kept = block
            kept[timingIdx] = shifted
            out.append(contentsOf: kept)
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                out.append(line)
            } else {
                block.append(line)
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    /// `HH:MM:SS.mmm --> HH:MM:SS.mmm[ settings]` shifted by `offsetMs`, or nil when the whole cue
    /// falls off the front of the timeline. A line that doesn't parse is returned unchanged.
    private static func shiftTiming(_ line: String, offsetMs: Int) -> String? {
        let sides = line.components(separatedBy: "-->")
        guard sides.count == 2 else { return line }
        let startToken = sides[0].trimmingCharacters(in: .whitespaces)
        let tail = sides[1].trimmingCharacters(in: .whitespaces)
        // The end timestamp is the first whitespace-delimited token; anything after it is cue settings.
        // WebVTT allows a space OR a tab between the end timestamp and the settings.
        let endToken = tail.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        let settings = tail.dropFirst(endToken.count).trimmingCharacters(in: .whitespaces)
        guard let start = millis(fromVTTTimestamp: startToken), let end = millis(fromVTTTimestamp: endToken) else {
            return line
        }
        let newEnd = end + offsetMs
        guard newEnd > 0 else { return nil }
        let newStart = max(0, start + offsetMs)
        let rendered = "\(vttTime(Double(newStart) / 1000)) --> \(vttTime(Double(max(newStart, newEnd)) / 1000))"
        return settings.isEmpty ? rendered : rendered + " " + settings
    }

    /// `[HH:]MM:SS.mmm` → milliseconds. Tolerates a comma decimal separator (SRT leftovers).
    static func millis(fromVTTTimestamp raw: String) -> Int? {
        let normalized = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let secComps = (parts.last ?? "").split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let sec = Int(secComps.first ?? "") else { return nil }
        let millisText = secComps.count > 1 ? String((secComps[1] + "000").prefix(3)) : "000"
        guard let ms = Int(millisText) else { return nil }
        var hour = 0, minute = 0
        if parts.count == 3 {
            guard let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
            hour = h; minute = m
        } else {
            guard let m = Int(parts[0]) else { return nil }
            minute = m
        }
        return ((hour * 60 + minute) * 60 + sec) * 1000 + ms
    }

    /// SDH stripping for a file that is already WebVTT (passed through otherwise untouched): run the
    /// shared filter over cue payload lines only — the header, NOTE/STYLE/REGION blocks, cue
    /// identifiers and timing lines pass through verbatim. A payload line that filters to nothing is
    /// dropped entirely (its cue keeps the timing line and renders empty when all lines drop).
    private static func stripSdhFromCuePayloads(_ text: String) -> String {
        var out = [String]()
        var inCue = false                            // between a timing line and the next blank
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                inCue = false
                out.append(line)
            } else if line.contains("-->") {
                inCue = true
                out.append(line)
            } else if inCue {
                if let kept = SubtitleSdhFilter.shared.filter(text: line) { out.append(kept) }
            } else {
                out.append(line)                     // header / block / cue-identifier line
            }
        }
        return out.joined(separator: "\n")
    }

    /// `HH:MM:SS,mmm --> HH:MM:SS,mmm[ position hints]` → `HH:MM:SS.mmm --> HH:MM:SS.mmm`.
    /// Tolerates dot-separated millis and missing hour fields; drops SRT coordinate suffixes.
    private static func vttTiming(from line: String) -> String? {
        guard line.contains("-->") else { return nil }
        let sides = line.components(separatedBy: "-->")
        guard sides.count == 2,
              let start = vttTimestamp(sides[0]), let end = vttTimestamp(sides[1]) else { return nil }
        return "\(start) --> \(end)"
    }

    private static func vttTimestamp(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        let normalized = token.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        let secondsPart = parts.last ?? ""
        let secComps = secondsPart.split(separator: ".").map(String.init)
        guard let sec = Int(secComps.first ?? ""), sec < 60 else { return nil }
        let millis = secComps.count > 1 ? String((secComps[1] + "000").prefix(3)) : "000"
        guard Int(millis) != nil else { return nil }
        var hour = 0, minute = 0
        if parts.count == 3 {
            guard let h = Int(parts[0]), let m = Int(parts[1]), m < 60 else { return nil }
            hour = h; minute = m
        } else {
            guard let m = Int(parts[0]), m < 60 else { return nil }
            minute = m
        }
        return String(format: "%02d:%02d:%02d.%@", hour, minute, sec, millis)
    }

    /// Strip markup AVPlayer's WebVTT renderer doesn't understand: `{\ass tags}` and `<font …>`.
    /// `<i>/<b>/<u>` are valid VTT and pass through.
    private static func cleanCueText(_ line: String) -> String {
        var out = ""
        out.reserveCapacity(line.count)
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "{", let close = line[i...].firstIndex(of: "}") {
                i = line.index(after: close)
                continue
            }
            if ch == "<", let close = line[i...].firstIndex(of: ">") {
                let tag = line[line.index(after: i)..<close].lowercased()
                if tag.hasPrefix("font") || tag.hasPrefix("/font") {
                    i = line.index(after: close)
                    continue
                }
            }
            out.append(ch)
            i = line.index(after: i)
        }
        return out
    }

    /// Subtitle files are notoriously non-UTF-8: BOM-sniff UTF-16, then UTF-8, then Windows-1252,
    /// then Latin-1 — in that order, best effort.
    private static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.index(after: data.startIndex)]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                return String(data: data, encoding: b0 == 0xFF ? .utf16LittleEndian : .utf16BigEndian)
                    .map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }
}
