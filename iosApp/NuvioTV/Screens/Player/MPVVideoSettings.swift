import Foundation

// Video tuning of the mpv engine (Settings > Playback > Video): tone mapping, hardware decoding,
// HDR peak detection, debanding, motion interpolation and picture adjustments. Device-local
// UserDefaults values like the buffer knobs (hardware-dependent, never synced), read when the
// player starts, so a change applies to the next video. The native player renders through
// AVFoundation and ignores all of it. Every default equals what the player did before these
// settings existed.

/// mpv's `tone-mapping`: how HDR highlights are fitted to the display.
nonisolated enum VideoToneMapping: String, CaseIterable, Identifiable, Sendable {
    case auto
    case bt2390 = "bt.2390"
    case mobius
    case reinhard
    case hable
    case gamma
    case clip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return String(localized: "Automatic")
        case .bt2390: return "BT.2390"
        case .mobius: return "Mobius"
        case .reinhard: return "Reinhard"
        case .hable: return "Hable"
        case .gamma: return "Gamma"
        case .clip: return String(localized: "Clip")
        }
    }
}

/// mpv's `hwdec`: where video is decoded.
nonisolated enum VideoHardwareDecoding: String, CaseIterable, Identifiable, Sendable {
    case hardware = "videotoolbox"
    case compatibility = "videotoolbox-copy"
    case software = "no"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hardware: return String(localized: "Hardware")
        case .compatibility: return String(localized: "Hardware (Compatibility)")
        case .software: return String(localized: "Software")
        }
    }

    var detail: String {
        switch self {
        case .hardware:
            return String(localized: "Decode with the Apple TV's video hardware. The smoothest playback with the least heat.")
        case .compatibility:
            return String(localized: "Decode in hardware but copy the frames back to memory. Try it when a video shows glitches or green frames.")
        case .software:
            return String(localized: "Decode on the processor. Only for files the hardware cannot play; high bitrates may stutter.")
        }
    }
}

/// One of mpv's picture properties.
nonisolated enum PictureAdjustment: String, CaseIterable, Identifiable, Sendable {
    case brightness, contrast, saturation, gamma

    var id: String { rawValue }

    var title: String {
        switch self {
        case .brightness: return String(localized: "Brightness")
        case .contrast: return String(localized: "Contrast")
        case .saturation: return String(localized: "Saturation")
        case .gamma: return String(localized: "Gamma")
        }
    }
}

nonisolated struct MPVVideoSettings: Equatable, Sendable {
    var toneMapping = VideoToneMapping.auto
    var hardwareDecoding = VideoHardwareDecoding.hardware
    /// mpv's `hdr-compute-peak`: measure each scene's brightness for better tone mapping.
    var hdrPeakDetection = true
    var deband = false
    /// Smooth motion: resample frames to the display's refresh rate.
    var interpolation = false
    /// mpv's picture properties, each from -100 to 100 (0 = untouched).
    var brightness = 0
    var contrast = 0
    var saturation = 0
    var gamma = 0

    /// The values the picture pickers offer.
    static let pictureChoices = Array(stride(from: -50, through: 50, by: 10))

    var isDefault: Bool { self == MPVVideoSettings() }

    func value(for adjustment: PictureAdjustment) -> Int {
        switch adjustment {
        case .brightness: return brightness
        case .contrast: return contrast
        case .saturation: return saturation
        case .gamma: return gamma
        }
    }

    mutating func set(_ value: Int, for adjustment: PictureAdjustment) {
        switch adjustment {
        case .brightness: brightness = value
        case .contrast: contrast = value
        case .saturation: saturation = value
        case .gamma: gamma = value
        }
    }

    // MARK: Storage

    static var current: MPVVideoSettings {
        let defaults = UserDefaults.standard
        func flag(_ key: String, default value: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? value : defaults.bool(forKey: key)
        }
        func picture(_ key: String) -> Int {
            min(max(defaults.integer(forKey: key), -100), 100)
        }
        var settings = MPVVideoSettings()
        settings.toneMapping = defaults.string(forKey: PlayerTuning.videoToneMappingKey)
            .flatMap(VideoToneMapping.init(rawValue:)) ?? .auto
        settings.hardwareDecoding = defaults.string(forKey: PlayerTuning.videoHardwareDecodingKey)
            .flatMap(VideoHardwareDecoding.init(rawValue:)) ?? .hardware
        settings.hdrPeakDetection = flag(PlayerTuning.videoHdrPeakKey, default: true)
        settings.deband = flag(PlayerTuning.videoDebandKey, default: false)
        settings.interpolation = flag(PlayerTuning.videoInterpolationKey, default: false)
        settings.brightness = picture(PlayerTuning.videoBrightnessKey)
        settings.contrast = picture(PlayerTuning.videoContrastKey)
        settings.saturation = picture(PlayerTuning.videoSaturationKey)
        settings.gamma = picture(PlayerTuning.videoGammaKey)
        return settings
    }

    func store() {
        let defaults = UserDefaults.standard
        defaults.set(toneMapping.rawValue, forKey: PlayerTuning.videoToneMappingKey)
        defaults.set(hardwareDecoding.rawValue, forKey: PlayerTuning.videoHardwareDecodingKey)
        defaults.set(hdrPeakDetection, forKey: PlayerTuning.videoHdrPeakKey)
        defaults.set(deband, forKey: PlayerTuning.videoDebandKey)
        defaults.set(interpolation, forKey: PlayerTuning.videoInterpolationKey)
        defaults.set(brightness, forKey: PlayerTuning.videoBrightnessKey)
        defaults.set(contrast, forKey: PlayerTuning.videoContrastKey)
        defaults.set(saturation, forKey: PlayerTuning.videoSaturationKey)
        defaults.set(gamma, forKey: PlayerTuning.videoGammaKey)
    }

    // MARK: mpv values

    /// Everything mpv takes before it starts (`mpv_set_option_string`). Options left at their mpv
    /// default are not sent.
    func startupOptions() -> [(String, String)] {
        var options: [(String, String)] = [
            ("hwdec", hardwareDecoding.rawValue),
            ("tone-mapping", toneMapping.rawValue),
            ("hdr-compute-peak", hdrPeakDetection ? "yes" : "no"),
        ]
        if deband {
            options.append(("deband", "yes"))
        }
        if interpolation {
            // Interpolation needs frames paced to the display, not to the audio clock.
            options.append(("video-sync", "display-resample"))
            options.append(("interpolation", "yes"))
        }
        for adjustment in PictureAdjustment.allCases where value(for: adjustment) != 0 {
            options.append((adjustment.rawValue, "\(value(for: adjustment))"))
        }
        return options
    }

    /// Short value for the Settings row: whether anything differs from the defaults.
    var summary: String {
        isDefault ? String(localized: "Default") : String(localized: "Custom")
    }

    static func pictureTitle(_ value: Int) -> String {
        value == 0 ? String(localized: "Default") : (value > 0 ? "+\(value)" : "\(value)")
    }
}
