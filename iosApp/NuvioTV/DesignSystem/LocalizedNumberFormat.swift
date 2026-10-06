import Foundation

/// Numbers shown to the viewer (file sizes, bitrates, frame rates, delays, ratings), formatted in
/// the viewer's locale: French reads "1,5 Go" and "12,3 Mbit/s", English "1.5 GB" and
/// "12.3 Mb/s". Never build these with `String(format: "%.1f")` — that always prints a dot.
///
/// Values sent to mpv, logs and other machine-readable text keep `String(format:)`.
nonisolated enum LocalizedNumberFormat {

    /// The viewer's locale, kept up to date when the region changes.
    static var locale: Locale { .autoupdatingCurrent }

    /// A plain decimal with a fixed number of fraction digits: 1.5 -> "1,5" in French.
    static func decimal(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.never)
                .locale(locale)
        )
    }

    /// Up to `maxFractionDigits` digits, trailing zeros dropped: 23.976 -> "23,976", 25 -> "25".
    static func compactDecimal(_ value: Double, maxFractionDigits: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(0...maxFractionDigits))
                .grouping(.never)
                .locale(locale)
        )
    }

    /// A signed value with a fixed number of fraction digits: "+1,50", "-0,25", "0,00".
    static func signedDecimal(_ value: Double, fractionDigits: Int) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .sign(strategy: .always(includingZero: false))
                .grouping(.never)
                .locale(locale)
        )
    }

    /// A file size in the viewer's locale and units: "1,5 Go", "740 Mo", "2.3 GB".
    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// A network rate from bytes per second: "4,2 Mo/s".
    static func transferRate(bytesPerSecond: Double) -> String {
        let size = fileSize(Int64(bytesPerSecond.rounded()))
        return String(
            localized: "format.rate.perSecond",
            defaultValue: "\(size)/s",
            comment: "Player stream info: a download speed. %@ is a localized size such as 4.2 MB."
        )
    }

    /// A video bitrate from bits per second: "12,3 Mbit/s" (French), "12.3 Mb/s" (English).
    static func bitrate(bitsPerSecond: Double) -> String {
        let value = decimal(bitsPerSecond / 1_000_000, fractionDigits: 1)
        return String(
            localized: "format.bitrate.mbps",
            defaultValue: "\(value) Mb/s",
            comment: "Player stream info: a video bitrate in megabits per second. %@ is the localized number, e.g. 12.3."
        )
    }

    /// A frame rate: "23,976 fps".
    static func frameRate(_ fps: Double) -> String {
        let value = compactDecimal(fps, maxFractionDigits: 3)
        return String(
            localized: "format.frameRate",
            defaultValue: "\(value) fps",
            comment: "Player stream info: frames per second. %@ is the localized number, e.g. 23.976."
        )
    }

    /// A signed delay in seconds: "+1,50 s".
    static func signedSeconds(_ seconds: Double) -> String {
        if seconds == 0 { return "0 s" }
        return "\(signedDecimal(seconds, fractionDigits: 2)) s"
    }

    /// A playback speed: "1,25\u{00D7}", "2\u{00D7}".
    static func speed(_ rate: Double) -> String {
        "\(compactDecimal(rate, maxFractionDigits: 2))\u{00D7}"
    }
}
