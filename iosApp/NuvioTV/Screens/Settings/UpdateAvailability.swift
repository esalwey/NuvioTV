import Combine
import Foundation

/// Read-only "is a newer version out" check for About.
///
/// tvOS cannot install an update from inside an app (this build is sideloaded or signed through
/// tvsign), so there is no updater, no channel picker and no download: the row only says whether
/// the newest stable release is newer than the running build. "Stable" means a GitHub release of
/// the tvOS repository tagged `tvos-v<version>` that is neither a draft nor a prerelease (the tag
/// convention of `.github/workflows/tvos-device-ipa.yml`).
///
/// One unauthenticated GitHub API request per check, remembered for `cacheLifetime` so reopening
/// About does not spend the anonymous rate limit. Any failure leaves the row hidden.
@MainActor
final class UpdateAvailability: ObservableObject {
    enum Status: Equatable {
        case unknown
        case checking
        case upToDate
        case available(version: String)
    }

    @Published private(set) var status: Status = .unknown

    nonisolated static let repository = "esalwey/NuvioTV"
    nonisolated static let tagPrefix = "tvos-v"
    private static let cacheLifetime: TimeInterval = 6 * 60 * 60
    private static let latestKey = "update_latest_stable_version"
    private static let checkedAtKey = "update_latest_checked_at"

    /// Refreshes `status` for the running `currentVersion` (CFBundleShortVersionString).
    func refresh(currentVersion: String) async {
        let defaults = UserDefaults.standard
        if let cached = defaults.string(forKey: Self.latestKey),
           Date().timeIntervalSince1970 - defaults.double(forKey: Self.checkedAtKey) < Self.cacheLifetime {
            status = Self.status(latest: cached, current: currentVersion)
            return
        }
        guard status != .checking else { return }
        status = .checking
        guard let latest = await Self.fetchLatestStableVersion() else {
            status = .unknown
            return
        }
        defaults.set(latest, forKey: Self.latestKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.checkedAtKey)
        status = Self.status(latest: latest, current: currentVersion)
    }

    // MARK: - Pure logic

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft
            case prerelease
        }
    }

    nonisolated static func status(latest: String, current: String) -> Status {
        isNewer(latest, than: current) ? .available(version: latest) : .upToDate
    }

    /// The highest `tvos-v<version>` stable release in a GitHub "list releases" payload, as the bare
    /// version ("0.4.0"), or nil when there is none.
    nonisolated static func latestStableVersion(in data: Data) -> String? {
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { return nil }
        let versions = releases.compactMap { release -> String? in
            guard !release.draft, !release.prerelease, release.tagName.hasPrefix(tagPrefix) else { return nil }
            let version = String(release.tagName.dropFirst(tagPrefix.count))
            return components(of: version) == nil ? nil : version
        }
        return versions.max { isNewer($1, than: $0) }
    }

    /// Dotted numeric versions ("0.4", "1.2.3"); anything else (a suffix like "-beta.2") is not a
    /// stable version and yields nil.
    nonisolated private static func components(of version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let number = Int(part) else { return nil }
            numbers.append(number)
        }
        return numbers
    }

    /// True when `candidate` is a higher dotted version than `current`. A running build whose
    /// version cannot be read ("dev", "") never reports an update.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(of: candidate), let old = components(of: current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let lhs = index < new.count ? new[index] : 0
            let rhs = index < old.count ? old[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    // MARK: - Network

    nonisolated private static func fetchLatestStableVersion() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=30") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return latestStableVersion(in: data)
        } catch {
            return nil
        }
    }
}
