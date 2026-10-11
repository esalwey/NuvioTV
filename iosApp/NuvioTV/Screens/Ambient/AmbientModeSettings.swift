import Combine
import Foundation

/// Ambient Mode: after a stretch with no Siri Remote input, Nuvio fills the screen with slowly moving
/// artwork from the user's catalogs, the way the Apple TV screen saver does with its aerials. It is
/// off by default (the system screen saver already covers an idle Apple TV), so the one thing a user
/// who turns it on has to get right is the delay: shorter than the system's, or the system wins.
///
/// The choices are device-local, like the other Home Screen display preferences: a living-room
/// Apple TV decides this for itself, so nothing here goes through the shared profile sync.
struct AmbientModeSettings: Equatable {
    /// Delay choices, in minutes (the Android TV list).
    static let timeoutOptionsMinutes = [1, 2, 5, 10, 15, 30]
    static let defaultTimeoutMinutes = 5
    /// How many catalogs may feed the slideshow.
    static let maxCatalogs = 3

    var enabled = false
    var timeoutMinutes = AmbientModeSettings.defaultTimeoutMinutes
    /// Home catalog keys (`HomeCatalogSection.key`) the artwork comes from, in the order picked.
    /// Empty means "same as the Home hero".
    var catalogKeys: [String] = []

    /// The idle time before the slideshow starts, in seconds.
    var timeout: TimeInterval {
        TimeInterval(Self.clampedMinutes(timeoutMinutes)) * 60
    }

    static func clampedMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 1), 30)
    }

    /// Distinct keys, in order, cut to `maxCatalogs`.
    static func normalizedKeys(_ keys: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in keys where !key.isEmpty && seen.insert(key).inserted {
            result.append(key)
            if result.count == maxCatalogs { break }
        }
        return result
    }

    /// "5 minutes", in the viewer's language and plural rules.
    static func timeoutLabel(minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.minutes], width: .wide))
    }
}

/// Persistence for `AmbientModeSettings`: plain `UserDefaults`, one key per field. The catalog keys
/// are a JSON array string (the shape the Android TV store uses), so a malformed value reads as "none".
enum AmbientModeStore {
    static let enabledKey = "ambient_mode_enabled"
    static let timeoutKey = "ambient_mode_timeout_minutes"
    static let catalogsKey = "ambient_mode_catalog_keys"

    static func load(_ defaults: UserDefaults = .standard) -> AmbientModeSettings {
        var settings = AmbientModeSettings()
        settings.enabled = defaults.bool(forKey: enabledKey)
        if defaults.object(forKey: timeoutKey) != nil {
            settings.timeoutMinutes = AmbientModeSettings.clampedMinutes(defaults.integer(forKey: timeoutKey))
        }
        settings.catalogKeys = decodeKeys(defaults.string(forKey: catalogsKey))
        return settings
    }

    static func save(_ settings: AmbientModeSettings, to defaults: UserDefaults = .standard) {
        defaults.set(settings.enabled, forKey: enabledKey)
        defaults.set(AmbientModeSettings.clampedMinutes(settings.timeoutMinutes), forKey: timeoutKey)
        defaults.set(encodeKeys(settings.catalogKeys), forKey: catalogsKey)
    }

    static func decodeKeys(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return AmbientModeSettings.normalizedKeys(keys)
    }

    static func encodeKeys(_ keys: [String]) -> String {
        let limited = AmbientModeSettings.normalizedKeys(keys)
        guard let data = try? JSONEncoder().encode(limited), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }
}

/// The live settings, shared by the Settings page (writes) and the idle controller (reads).
@MainActor
final class AmbientModeSettingsModel: ObservableObject {
    static let shared = AmbientModeSettingsModel()

    @Published private(set) var settings: AmbientModeSettings
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = AmbientModeStore.load(defaults)
    }

    func setEnabled(_ enabled: Bool) {
        update { $0.enabled = enabled }
    }

    func setTimeoutMinutes(_ minutes: Int) {
        update { $0.timeoutMinutes = AmbientModeSettings.clampedMinutes(minutes) }
    }

    func setCatalogKeys(_ keys: [String]) {
        update { $0.catalogKeys = AmbientModeSettings.normalizedKeys(keys) }
    }

    /// Turns one catalog on or off. Refused (returns false) when it would pass `maxCatalogs`.
    @discardableResult
    func setCatalog(_ key: String, selected: Bool) -> Bool {
        var keys = settings.catalogKeys
        if selected {
            guard keys.contains(key) || keys.count < AmbientModeSettings.maxCatalogs else { return false }
            if !keys.contains(key) { keys.append(key) }
        } else {
            keys.removeAll { $0 == key }
        }
        setCatalogKeys(keys)
        return true
    }

    private func update(_ change: (inout AmbientModeSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        AmbientModeStore.save(next, to: defaults)
    }
}
