import Foundation

// Two repairs for the text of add-on subtitles, applied to the WebVTT the native engine serves
// (`SubtitleVTT`; mpv's libass already shapes right-to-left text itself):
//  - mojibake: UTF-8 text that was read as Windows-1252 or Latin-1 somewhere along the way shows
//    "â™ª" for "♪" and "Ã©" for "é";
//  - right-to-left lines: a line whose first strong character is Latin (a name, a "- " dash, a
//    number) is laid out left to right, which puts the punctuation of an Arabic or Hebrew sentence
//    on the wrong side. Wrapping the line in a right-to-left embedding makes the whole line RTL,
//    with the Latin runs inside it staying left to right.
//
// Port of the Android TV player's `SubtitleMojibakeSanitizer` and `PlayerSubtitleRtlFix`: the
// mojibake repair reverses the mis-decoding instead of listing patterns (the list stays as a
// fallback), and the right-to-left fix uses the embedding for Hebrew too, since the Apple text
// layout runs the Unicode bidi algorithm that the Android subtitle view lacked.

nonisolated enum SubtitleTextNormalizer {

    // MARK: - WebVTT document

    /// `vtt` with every cue payload line repaired. Headers, cue identifiers, timing lines and
    /// NOTE/STYLE/REGION blocks are left alone.
    static func normalizeVTT(_ vtt: String) -> String {
        var out: [String] = []
        out.reserveCapacity(vtt.count / 24)
        var inPayload = false
        for line in vtt.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                inPayload = false
                out.append(line)
            } else if inPayload {
                out.append(normalizeLine(line))
            } else {
                if line.contains("-->") { inPayload = true }
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// One cue text line: mojibake repaired, then right-to-left wrapped when it needs it.
    static func normalizeLine(_ line: String) -> String {
        wrapRightToLeft(repairMojibake(line))
    }

    /// A whole cue text (lines joined by newlines), each line repaired on its own.
    static func normalizeCue(_ text: String) -> String {
        text.components(separatedBy: "\n").map(normalizeLine).joined(separator: "\n")
    }

    // MARK: - Mojibake

    /// UTF-8 read as Windows-1252, repaired: the line's characters are turned back into the bytes
    /// they were read from, and kept only if those bytes are UTF-8 that makes the line shorter.
    /// Lines that are not mojibake (nothing maps back, or the bytes are not UTF-8) come back as
    /// they were, then run through the known-pattern table.
    static func repairMojibake(_ line: String) -> String {
        guard hasMojibakeShape(line) else { return line }
        if let bytes = windows1252Bytes(of: line),
           let decoded = String(bytes: bytes, encoding: .utf8),
           decoded != line,
           decoded.unicodeScalars.count < line.unicodeScalars.count,
           !decoded.unicodeScalars.contains(where: { $0.value == 0xFFFD || ($0.value < 0x20 && $0 != "\t") }) {
            return decoded
        }
        return replacePatterns(in: line)
    }

    /// A UTF-8 lead byte (Â…ô) next to a continuation byte (U+0080…U+00BF, or a Windows-1252
    /// character standing for one) — what mojibake always contains.
    private static func hasMojibakeShape(_ line: String) -> Bool {
        var lead = false, continuation = false
        for scalar in line.unicodeScalars {
            let v = scalar.value
            if v < 0x80 { continue }
            if (0xC2...0xF4).contains(v) { lead = true }
            if (0x80...0xBF).contains(v) || windows1252Specials[v] != nil { continuation = true }
            if v == 0xFFFD { return true }
            if lead && continuation { return true }
        }
        return false
    }

    /// The Windows-1252 bytes `line` would have been read from, or nil when a character has none
    /// (it was never read as Windows-1252). ASCII and U+00A0…U+00FF are their own bytes, U+0080…U+009F
    /// too (the five bytes Windows-1252 leaves undefined included); the rest are in the table.
    private static func windows1252Bytes(of line: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(line.utf8.count)
        for scalar in line.unicodeScalars {
            let v = scalar.value
            if v < 0x100 {
                bytes.append(UInt8(v))
            } else if let byte = windows1252Specials[v] {
                bytes.append(byte)
            } else {
                return nil
            }
        }
        return bytes
    }

    /// The characters Windows-1252 puts at 0x80…0x9F (the five undefined bytes read as controls).
    private static let windows1252Specials: [UInt32: UInt8] = [
        0x20AC: 0x80, 0x201A: 0x82, 0x0192: 0x83, 0x201E: 0x84, 0x2026: 0x85, 0x2020: 0x86,
        0x2021: 0x87, 0x02C6: 0x88, 0x2030: 0x89, 0x0160: 0x8A, 0x2039: 0x8B, 0x0152: 0x8C,
        0x017D: 0x8E, 0x2018: 0x91, 0x2019: 0x92, 0x201C: 0x93, 0x201D: 0x94, 0x2022: 0x95,
        0x2013: 0x96, 0x2014: 0x97, 0x02DC: 0x98, 0x2122: 0x99, 0x0161: 0x9A, 0x203A: 0x9B,
        0x0153: 0x9C, 0x017E: 0x9E, 0x0178: 0x9F,
    ]

    /// The patterns of mojibake that survive when a line mixes it with text the reversal cannot
    /// take (a character that was never Windows-1252). Longer patterns first.
    private static let patterns: [(String, String)] = [
        ("\u{00E2}\u{2122}\u{00AA}", "\u{266A}"),         // â™ª → ♪
        ("\u{00E2}\u{2122}\u{00AB}", "\u{266B}"),         // â™« → ♫
        ("\u{00E2}\u{20AC}\u{2122}", "\u{2019}"),         // â€™ → ’
        ("\u{00E2}\u{20AC}\u{02DC}", "\u{2018}"),         // â€˜ → ‘
        ("\u{00E2}\u{20AC}\u{0153}", "\u{201C}"),         // â€œ → “
        ("\u{00E2}\u{20AC}\u{009D}", "\u{201D}"),         // â€<9D> → ”
        ("\u{00E2}\u{20AC}\u{201C}", "\u{2013}"),         // â€“ → –
        ("\u{00E2}\u{20AC}\u{201D}", "\u{2014}"),         // â€” → —
        ("\u{00E2}\u{20AC}\u{00A6}", "\u{2026}"),         // â€¦ → …
        ("\u{00C2}\u{00A0}", " "),                        // Â<nbsp> → space
        ("\u{00C2}\u{00BF}", "\u{00BF}"),                 // Â¿ → ¿
        ("\u{00C2}\u{00A1}", "\u{00A1}"),                 // Â¡ → ¡
        ("\u{00C2}\u{00AB}", "\u{00AB}"),                 // Â« → «
        ("\u{00C2}\u{00BB}", "\u{00BB}"),                 // Â» → »
        ("\u{FFFD}", ""),
    ]

    private static func replacePatterns(in line: String) -> String {
        var text = line
        for (pattern, replacement) in patterns where text.contains(pattern) {
            text = text.replacingOccurrences(of: pattern, with: replacement)
        }
        return text
    }

    // MARK: - Right-to-left

    private static let rightToLeftEmbedding: Character = "\u{202B}"
    private static let popDirectionalFormatting: Character = "\u{202C}"
    /// LRE, RLE, PDF, LRM, RLM: what an earlier pass (or the file) may already have put in.
    private static let directionalMarks: Set<Character> = ["\u{202A}", "\u{202B}", "\u{202C}", "\u{200E}", "\u{200F}"]

    /// `line` wrapped in a right-to-left embedding when it has a strong right-to-left letter
    /// (Hebrew, Arabic, Syriac, Thaana…), unchanged otherwise. Idempotent: marks already in the
    /// line are replaced by the one wrap.
    static func wrapRightToLeft(_ line: String) -> String {
        guard containsRightToLeftLetter(line) else { return line }
        let core = line.filter { !directionalMarks.contains($0) }
        guard !core.isEmpty else { return line }
        // A trailing CR (CRLF files) stays outside the embedding, or it would end the run.
        if core.hasSuffix("\r") {
            return String(rightToLeftEmbedding) + core.dropLast() + String(popDirectionalFormatting) + "\r"
        }
        return String(rightToLeftEmbedding) + core + String(popDirectionalFormatting)
    }

    /// A letter in a right-to-left script. Digits (Arabic-Indic ones too) and punctuation do not
    /// count: a line of numbers has no direction of its own.
    static func containsRightToLeftLetter(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where scalar.value >= 0x0590 {
            let v = scalar.value
            let inRightToLeftBlock = (0x0590...0x08FF).contains(v) || (0xFB1D...0xFDFF).contains(v)
                || (0xFE70...0xFEFF).contains(v) || (0x10800...0x10FFF).contains(v)
                || (0x1E800...0x1EFFF).contains(v)
            if inRightToLeftBlock, scalar.properties.isAlphabetic { return true }
        }
        return false
    }
}
