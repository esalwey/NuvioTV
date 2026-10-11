import AVFAudio
import Foundation

// Audio tuning of the mpv engine: the output layout (Settings > Playback > Audio) and the two
// remembered boosts of the player's Audio menu (volume boost, dialogue boost). Device-local
// UserDefaults values, like the other hardware knobs. The native player follows tvOS's own Audio
// Format setting and its Enhance Dialogue button instead, so none of this reaches it.

/// Audio Output: the channel layout mpv asks the audio output for.
nonisolated enum AudioOutputMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case stereo
    case surround51
    case surround71

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return String(localized: "Automatic")
        case .stereo: return String(localized: "Stereo")
        case .surround51: return String(localized: "5.1 Surround")
        case .surround71: return String(localized: "7.1 Surround")
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return String(localized: "Use the layout the connected TV or receiver accepts.")
        case .stereo:
            return String(localized: "Mix every track down to two channels, for TV speakers and headphones.")
        case .surround51:
            return String(localized: "Send up to 5.1 channels. Larger layouts are mixed down.")
        case .surround71:
            return String(localized: "Send up to 7.1 channels. Needs a receiver that accepts them.")
        }
    }

    /// mpv's `audio-channels`: the layouts it may use, in order of preference. A surround choice
    /// falls back to the next smaller layout the output accepts.
    var mpvChannels: String {
        switch self {
        case .auto: return "auto"
        case .stereo: return "stereo"
        case .surround51: return "5.1,stereo"
        case .surround71: return "7.1,5.1,stereo"
        }
    }

    /// A layout that mixes tracks down is normalised, so the downmix cannot clip or fall quiet.
    var normalizesDownmix: Bool { self != .auto }

    /// Channels to ask tvOS for; nil leaves the session as it is.
    var preferredChannelCount: Int? {
        switch self {
        case .auto: return nil
        case .stereo: return 2
        case .surround51: return 6
        case .surround71: return 8
        }
    }

    static var current: AudioOutputMode {
        UserDefaults.standard.string(forKey: PlayerTuning.audioOutputKey).flatMap(AudioOutputMode.init(rawValue:)) ?? .auto
    }

    func store() {
        UserDefaults.standard.set(rawValue, forKey: PlayerTuning.audioOutputKey)
    }
}

/// The values of the player's Audio menu and what they become in mpv.
nonisolated struct MPVAudioSettings: Equatable, Sendable {
    /// Volume boost choices in dB (0 = off).
    static let gainChoices = [0, 3, 6, 10]
    /// Dialogue boost choices in dB (0 = off): Low, Medium, High.
    static let dialogueChoices = [0, 3, 6, 9]
    /// mpv's `volume-max` (percent): headroom for the largest boost (+10 dB is 316 %).
    static let volumeMaxPercent = 400

    var output: AudioOutputMode = .auto
    var gainDb = 0
    var dialogueDb = 0

    static var current: MPVAudioSettings {
        let defaults = UserDefaults.standard
        return MPVAudioSettings(
            output: .current,
            gainDb: nearest(defaults.integer(forKey: PlayerTuning.audioGainDbKey), in: gainChoices),
            dialogueDb: nearest(defaults.integer(forKey: PlayerTuning.dialogueBoostDbKey), in: dialogueChoices))
    }

    func storeBoosts() {
        let defaults = UserDefaults.standard
        defaults.set(gainDb, forKey: PlayerTuning.audioGainDbKey)
        defaults.set(dialogueDb, forKey: PlayerTuning.dialogueBoostDbKey)
    }

    private static func nearest(_ value: Int, in choices: [Int]) -> Int {
        choices.min { abs($0 - value) < abs($1 - value) } ?? 0
    }

    // MARK: mpv values

    /// mpv's software `volume` (percent) for a boost in dB: 100 % is unity.
    static func volumePercent(gainDb: Int) -> Double {
        100 * pow(10, Double(gainDb) / 20)
    }

    /// Linear weight of the centre channel in a stereo downmix. swresample's own default is
    /// 1/sqrt(2) (-3 dB); the boost multiplies it.
    static func centerMixLevel(dialogueDb: Int) -> Double {
        (0.5).squareRoot() * pow(10, Double(dialogueDb) / 20)
    }

    /// mpv's `af` for a dialogue boost, "" for none: the tracks are mixed to stereo with a heavier
    /// centre channel (where speech sits), the matrix normalised so nothing clips. Stereo and mono
    /// sources pass through unchanged. `stereoOutput` is false when the output takes surround and
    /// has a centre speaker of its own: the filter would flatten it, so there is no boost.
    static func audioFilter(dialogueDb: Int, stereoOutput: Bool) -> String {
        guard dialogueDb > 0, stereoOutput else { return "" }
        let level = String(format: "%.3f", centerMixLevel(dialogueDb: dialogueDb))
        return "lavfi=[aresample=out_chlayout=stereo:center_mix_level=\(level):rematrix_maxval=1.0]"
    }

    /// Whether the audio goes out as stereo: asked for, or all the connected output accepts. The
    /// Audio menu offers the dialogue boost only then.
    static func isStereoOutput(_ mode: AudioOutputMode) -> Bool {
        switch mode {
        case .stereo: return true
        case .surround51, .surround71: return false
        case .auto: return AVAudioSession.sharedInstance().maximumOutputNumberOfChannels <= 2
        }
    }

    /// Everything mpv takes before it starts (`mpv_set_option_string`).
    func startupOptions() -> [(String, String)] {
        var options: [(String, String)] = [
            ("audio-channels", output.mpvChannels),
            ("volume-max", "\(Self.volumeMaxPercent)"),
        ]
        if output.normalizesDownmix {
            options.append(("audio-normalize-downmix", "yes"))
        }
        if gainDb > 0 {
            options.append(("volume", String(format: "%.2f", Self.volumePercent(gainDb: gainDb))))
        }
        let filter = Self.audioFilter(dialogueDb: dialogueDb, stereoOutput: Self.isStereoOutput(output))
        if !filter.isEmpty {
            options.append(("af", filter))
        }
        return options
    }

    /// Asks tvOS for the channel count of a chosen layout before the audio output opens; without it
    /// the session keeps handing out stereo. Auto leaves the session untouched.
    static func prepareSession(for mode: AudioOutputMode) {
        guard let channels = mode.preferredChannelCount else { return }
        let session = AVAudioSession.sharedInstance()
        if channels > 2 {
            try? session.setSupportsMultichannelContent(true)
        }
        try? session.setPreferredOutputNumberOfChannels(min(channels, max(session.maximumOutputNumberOfChannels, 2)))
    }
}

/// Menu titles of the boosts.
nonisolated enum MPVAudioBoostTitle {
    static func gain(_ db: Int) -> String {
        db == 0 ? String(localized: "Off") : String(localized: "+\(db) dB")
    }

    static func dialogue(_ db: Int) -> String {
        switch db {
        case 0: return String(localized: "Off")
        case ...3: return String(localized: "Low")
        case ...6: return String(localized: "Medium")
        default: return String(localized: "High")
        }
    }
}
