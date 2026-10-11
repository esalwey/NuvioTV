import Foundation

// Subtitle files are notoriously not UTF-8: a Russian SRT is Windows-1251, an Arabic one
// Windows-1256, a Chinese one GBK or Big5, a Japanese one Shift-JIS, a Korean one EUC-KR. The
// native engine converts add-on subtitles itself (`SubtitleVTT`), and the mpv engine reads them
// through its own `sub-codepage` option; both come here for the choice of the legacy code page.
//
// What decides it, in this order:
//  1. A byte-order mark, or UTF-16 without one (ASCII timing lines give it away), then valid UTF-8.
//  2. The subtitle's language, which add-ons state: it names the code page the language is written
//     in (`legacyCandidates`). A single-byte code page is only trusted when the decoded letters
//     really are in the language's script, so a French file offered as "Russian" does not turn
//     into Cyrillic noise.
//  3. With no usable language, the double-byte code pages are tried by the shape of the bytes
//     (`guessDoubleByte`): Hangul in EUC-KR, kana in Shift-JIS, Big5's low trail bytes against
//     GBK's. Single-byte code pages cannot be told apart without a language; those fall through.
//  4. Windows-1252, then Latin-1: what the files that are neither tend to be.
//
// The code pages are looked up by their IANA names, so an encoding the OS does not know is simply
// skipped.

nonisolated enum SubtitleCharset {

    // MARK: - Decoding

    /// The text of a subtitle file, or nil for no data. `languageHint` is the subtitle's language as
    /// the add-on states it ("rus", "ru", "zh-TW"...); nil or unknown leaves the choice to the
    /// bytes.
    static func decode(_ data: Data, languageHint: String? = nil) -> String? {
        guard !data.isEmpty else { return nil }
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.index(after: data.startIndex)]
            if (b0 == 0xFF && b1 == 0xFE) || (b0 == 0xFE && b1 == 0xFF) {
                return String(data: data, encoding: b0 == 0xFF ? .utf16LittleEndian : .utf16BigEndian)
                    .map { $0.hasPrefix("\u{FEFF}") ? String($0.dropFirst()) : $0 }
            }
        }
        if let utf16 = bomlessUTF16(data) { return utf16 }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }

        let language = TrackLabelFormatter.normalizedTag(languageHint)
        for candidate in legacyCandidates(forLanguage: language) {
            if let text = decode(data, as: candidate) { return text }
        }
        if let guessed = guessDoubleByte(data), let text = decode(data, as: guessed) { return text }
        return String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// UTF-16 with no byte-order mark: the timing lines are ASCII, so every other byte is zero.
    /// The side of the zeros says the byte order.
    static func bomlessUTF16(_ data: Data) -> String? {
        let sample = data.prefix(512)
        guard sample.count >= 8 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for (offset, byte) in sample.enumerated() where byte == 0 {
            if offset % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
        }
        let half = sample.count / 2
        let threshold = half * 3 / 10
        if oddZeros > threshold, evenZeros == 0 {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if evenZeros > threshold, oddZeros == 0 {
            return String(data: data, encoding: .utf16BigEndian)
        }
        return nil
    }

    // MARK: - Candidates

    /// The scripts a hinted code page is checked against.
    nonisolated enum Script: Equatable {
        case cyrillic, arabic, hebrew, greek, thai, han, kana, hangul

        func contains(_ scalar: UInt32) -> Bool {
            switch self {
            case .cyrillic: return (0x0400...0x04FF).contains(scalar) || (0x0500...0x052F).contains(scalar)
            case .arabic: return (0x0600...0x06FF).contains(scalar) || (0x0750...0x077F).contains(scalar)
                || (0xFB50...0xFDFF).contains(scalar) || (0xFE70...0xFEFF).contains(scalar)
            case .hebrew: return (0x0590...0x05FF).contains(scalar) || (0xFB1D...0xFB4F).contains(scalar)
            case .greek: return (0x0370...0x03FF).contains(scalar) || (0x1F00...0x1FFF).contains(scalar)
            case .thai: return (0x0E00...0x0E7F).contains(scalar)
            case .han: return (0x4E00...0x9FFF).contains(scalar) || (0x3400...0x4DBF).contains(scalar)
                || (0xF900...0xFAFF).contains(scalar) || (0x20000...0x2A6DF).contains(scalar)
            // Full-width kana only: Chinese text read as Shift-JIS turns into half-width katakana.
            case .kana: return (0x3040...0x30FF).contains(scalar) || (0x31F0...0x31FF).contains(scalar)
            case .hangul: return (0xAC00...0xD7A3).contains(scalar) || (0x1100...0x11FF).contains(scalar)
                || (0x3130...0x318F).contains(scalar)
            }
        }
    }

    /// A legacy code page, by IANA name (the first the OS knows is used), with the scripts one of
    /// which most of the decoded letters must be in. nil = no script to check (Latin alphabets).
    nonisolated struct Candidate: Equatable {
        let ianaNames: [String]
        let scripts: [Script]?
    }

    /// The code pages a subtitle in `language` (a normalized BCP 47 tag, or nil) is likely in.
    static func legacyCandidates(forLanguage language: String?) -> [Candidate] {
        guard let language else { return [] }
        let parts = language.lowercased().split(separator: "-").map(String.init)
        guard let primary = parts.first else { return [] }
        switch primary {
        case "ru", "uk", "bg", "be", "sr", "mk", "kk", "mn", "tg", "ky":
            return [Candidate(ianaNames: ["windows-1251"], scripts: [.cyrillic])]
        case "ar", "fa", "ur", "ps", "ku":
            return [Candidate(ianaNames: ["windows-1256"], scripts: [.arabic])]
        case "he", "yi":
            return [Candidate(ianaNames: ["windows-1255"], scripts: [.hebrew])]
        case "el":
            return [Candidate(ianaNames: ["windows-1253"], scripts: [.greek])]
        case "th":
            return [Candidate(ianaNames: ["windows-874"], scripts: [.thai])]
        case "tr", "az":
            return [Candidate(ianaNames: ["windows-1254"], scripts: nil)]
        case "pl", "cs", "sk", "hu", "ro", "hr", "sl", "sq", "bs":
            return [Candidate(ianaNames: ["windows-1250"], scripts: nil)]
        case "et", "lv", "lt":
            return [Candidate(ianaNames: ["windows-1257"], scripts: nil)]
        case "vi":
            return [Candidate(ianaNames: ["windows-1258"], scripts: nil)]
        case "ja":
            return [Candidate(ianaNames: ["windows-31j", "Shift_JIS"], scripts: [.kana, .han])]
        case "ko":
            return [Candidate(ianaNames: ["EUC-KR", "ks_c_5601-1987"], scripts: [.hangul, .han])]
        case "zh":
            let traditional = parts.contains("tw") || parts.contains("hk") || parts.contains("mo")
                || parts.contains("hant")
            let gbk = Candidate(ianaNames: ["GB18030", "GBK"], scripts: [.han])
            let big5 = Candidate(ianaNames: ["Big5"], scripts: [.han])
            return traditional ? [big5, gbk] : [gbk, big5]
        default:
            return []
        }
    }

    /// The `sub-codepage` value for an mpv side-load of a subtitle in `language`: UTF-8 first, the
    /// language's legacy code page when the file is not UTF-8. nil = leave mpv's own detection.
    static func mpvCodepage(forLanguage language: String?) -> String? {
        guard let tag = TrackLabelFormatter.normalizedTag(language),
              let primary = tag.lowercased().split(separator: "-").first.map(String.init) else { return nil }
        let parts = tag.lowercased().split(separator: "-").map(String.init)
        let legacy: String
        switch primary {
        case "ru", "uk", "bg", "be", "sr", "mk", "kk", "mn": legacy = "cp1251"
        case "ar", "fa", "ur": legacy = "cp1256"
        case "he": legacy = "cp1255"
        case "el": legacy = "cp1253"
        case "th": legacy = "cp874"
        case "tr", "az": legacy = "cp1254"
        case "pl", "cs", "sk", "hu", "ro", "hr", "sl", "sq", "bs": legacy = "cp1250"
        case "et", "lv", "lt": legacy = "cp1257"
        case "vi": legacy = "cp1258"
        case "ja": legacy = "cp932"
        case "ko": legacy = "cp949"
        case "zh":
            legacy = parts.contains("tw") || parts.contains("hk") || parts.contains("mo") || parts.contains("hant")
                ? "big5" : "gb18030"
        default: return nil
        }
        return "utf-8:\(legacy)"
    }

    // MARK: - Decoding with a code page

    /// The text under `candidate`, when the bytes are valid in it and the letters are in its script.
    static func decode(_ data: Data, as candidate: Candidate) -> String? {
        guard let encoding = candidate.ianaNames.lazy.compactMap({ stringEncoding(ianaName: $0) }).first,
              let text = String(data: data, encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value == 0xFFFD }) else { return nil }
        if let scripts = candidate.scripts, scriptShare(of: text, in: scripts) < 0.6 { return nil }
        return text
    }

    /// Share of the letters of `text` that are in one of `scripts` (0 for no letters).
    static func scriptShare(of text: String, in scripts: [Script]) -> Double {
        var letters = 0, inScript = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if scripts.contains(where: { $0.contains(scalar.value) }) { inScript += 1 }
        }
        return letters == 0 ? 0 : Double(inScript) / Double(letters)
    }

    private static func stringEncoding(ianaName: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
        guard cf != CFStringEncoding(UInt32.max) else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    // MARK: - Double-byte guess (no language)

    /// The double-byte code page the bytes look like, or nil (single-byte text, or nothing fits).
    /// Hangul in EUC-KR first (Chinese read as EUC-KR is never mostly Hangul), then kana in
    /// Shift-JIS, then Chinese: Big5 when a good share of the trail bytes are below 0x80 (GB2312
    /// text has none), GBK otherwise.
    static func guessDoubleByte(_ data: Data) -> Candidate? {
        var high = 0, letterLike = 0
        for byte in data {
            if byte >= 0x80 {
                high += 1
                letterLike += 1
            } else if (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) {
                letterLike += 1
            }
        }
        guard letterLike > 0, Double(high) / Double(letterLike) >= 0.4 else { return nil }

        let korean = Candidate(ianaNames: ["EUC-KR", "ks_c_5601-1987"], scripts: [.hangul])
        if let text = decode(data, as: korean), scriptShare(of: text, in: [.hangul]) >= 0.85 {
            return Candidate(ianaNames: korean.ianaNames, scripts: [.hangul, .han])
        }
        let japanese = Candidate(ianaNames: ["windows-31j", "Shift_JIS"], scripts: nil)
        if let text = decode(data, as: japanese), scriptShare(of: text, in: [.kana]) >= 0.15 {
            return Candidate(ianaNames: japanese.ianaNames, scripts: [.kana, .han])
        }
        let gbk = Candidate(ianaNames: ["GB18030", "GBK"], scripts: [.han])
        let big5 = Candidate(ianaNames: ["Big5"], scripts: [.han])
        let big5Valid = decode(data, as: big5).map { scriptShare(of: $0, in: [.han]) >= 0.85 } ?? false
        if let text = decode(data, as: gbk), scriptShare(of: text, in: [.han]) >= 0.85 {
            return big5Valid && lowTrailShare(data) >= 0.15 ? big5 : gbk
        }
        return big5Valid ? big5 : nil
    }

    /// Share of the double-byte pairs whose second byte is in 0x40...0x7E.
    static func lowTrailShare(_ data: Data) -> Double {
        let bytes = [UInt8](data)
        var pairs = 0, low = 0, index = 0
        while index < bytes.count - 1 {
            if bytes[index] >= 0x81 {
                pairs += 1
                if (0x40...0x7E).contains(bytes[index + 1]) { low += 1 }
                index += 2
            } else {
                index += 1
            }
        }
        return pairs == 0 ? 0 : Double(low) / Double(pairs)
    }
}
