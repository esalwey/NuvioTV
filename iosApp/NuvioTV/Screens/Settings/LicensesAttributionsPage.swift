import SwiftUI

/// "Licenses & Attributions": who Nuvio's data comes from, and the licences of what ships in the
/// app. Ported from the mobile app's page of the same name (texts kept, the service list extended
/// with the debrid providers this build supports). A pushed sub-page of About, so Menu pops back.
///
/// Static information, but every entry is focusable (`LicenseEntryRow`): a native `List` only
/// scrolls as far as focus can travel, and a link cannot be opened from the couch, so the entries
/// carry the address as plain text.
struct LicensesAttributionsPage: View {
    var body: some View {
        List {
            SettingsSection(String(localized: "App License")) {
                LicenseEntryRow(
                    title: String(localized: "Nuvio"),
                    detail: String(localized: "Source code and license terms are available in the project repository."),
                    license: String(localized: "Licensed under the GNU General Public License v3.0."),
                    address: "github.com/esalwey/NuvioMobile"
                )
            }

            SettingsSection(String(localized: "Data & Services")) {
                ForEach(Self.services, id: \.title) { service in
                    LicenseEntryRow(title: service.title, detail: service.detail, address: service.address)
                }
            }

            SettingsSection(String(localized: "Playback")) {
                LicenseEntryRow(
                    title: String(localized: "MPVKit"),
                    detail: String(localized: "Used for playback of formats Apple\u{2019}s player cannot open."),
                    license: String(localized: "MPVKit source alone is licensed under LGPL v3.0. MPVKit bundles, including libmpv and FFmpeg libraries, are also licensed under LGPL v3.0."),
                    address: "github.com/mpvkit/MPVKit"
                )
            }

            SettingsSection(String(localized: "Typeface")) {
                LicenseEntryRow(
                    title: String(localized: "Open Sans"),
                    detail: String(localized: "Optional interface typeface."),
                    license: String(localized: "Licensed under the SIL Open Font License 1.1."),
                    address: "scripts.sil.org/OFL"
                )
            }
        }
        .navigationTitle(String(localized: "Licenses & Attributions"))
    }

    private struct Service {
        let title: String
        let detail: String
        let address: String
    }

    private static var services: [Service] {
        [
            Service(
                title: String(localized: "The Movie Database (TMDB)"),
                detail: String(localized: "Nuvio uses the TMDB API for movie and TV metadata, artwork, trailers, cast, production details, collections, and recommendations. This product uses the TMDB API but is not endorsed or certified by TMDB."),
                address: "themoviedb.org"
            ),
            Service(
                title: String(localized: "IMDb Non-Commercial Datasets"),
                detail: String(localized: "Nuvio uses IMDb Non-Commercial Datasets, including title.ratings.tsv.gz, for IMDb ratings and vote counts. Information courtesy of IMDb (https://www.imdb.com). Used with permission. IMDb data is for personal and non-commercial use under IMDb\u{2019}s terms."),
                address: "developer.imdb.com/non-commercial-datasets"
            ),
            Service(
                title: String(localized: "Trakt"),
                detail: String(localized: "Nuvio connects to Trakt for account authentication, watched history, progress sync, library data, ratings, lists, and comments. Nuvio is not affiliated with or endorsed by Trakt."),
                address: "trakt.tv"
            ),
            Service(
                title: String(localized: "Simkl"),
                detail: String(localized: "Nuvio connects to Simkl for account authentication, watchlists, watched history, playback progress, and scrobbling. Movie, TV, and anime tracking data is provided by Simkl. Nuvio is not affiliated with or endorsed by Simkl."),
                address: "simkl.com"
            ),
            Service(
                title: String(localized: "Premiumize"),
                detail: String(localized: "Nuvio connects to Premiumize for account authentication, cloud library access, cache checks, and cloud playback features. Nuvio is not affiliated with or endorsed by Premiumize."),
                address: "premiumize.me"
            ),
            Service(
                title: String(localized: "TorBox"),
                detail: String(localized: "Nuvio connects to TorBox for account authentication, cloud library access, cache checks, and cloud playback features. Nuvio is not affiliated with or endorsed by TorBox."),
                address: "torbox.app"
            ),
            Service(
                title: String(localized: "Real-Debrid and AllDebrid"),
                detail: String(localized: "Nuvio connects to Real-Debrid and AllDebrid for account authentication, cache checks, and cloud playback features. Nuvio is not affiliated with or endorsed by Real-Debrid or AllDebrid."),
                address: "real-debrid.com \u{00B7} alldebrid.com"
            ),
            Service(
                title: String(localized: "MDBList"),
                detail: String(localized: "Nuvio uses MDBList for ratings, watched history and playback tracking. Nuvio is not affiliated with or endorsed by MDBList."),
                address: "mdblist.com"
            ),
            Service(
                title: String(localized: "IntroDB"),
                detail: String(localized: "Nuvio uses the IntroDB API for community-provided intro, recap, credits, and preview timestamps used by skip controls. Nuvio is not affiliated with or endorsed by IntroDB."),
                address: "introdb.app"
            ),
        ]
    }
}

/// One entry of the page: name, what it is used for, optional licence line and the address as
/// plain text. Focusable so the list can scroll through it; Select does nothing.
private struct LicenseEntryRow: View {
    let title: String
    let detail: String
    var license: String?
    let address: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(SettingsRowFont.title)
            Text(detail)
                .font(SettingsRowFont.subtitle)
                .foregroundStyle(.secondary)
            if let license, !license.isEmpty {
                Text(license)
                    .font(SettingsRowFont.subtitle)
                    .foregroundStyle(.secondary)
            }
            Text(address)
                .font(SettingsRowFont.subtitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .focusable()
    }
}
