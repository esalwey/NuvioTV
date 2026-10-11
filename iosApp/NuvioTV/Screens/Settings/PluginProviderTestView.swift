import SwiftUI
import SharedCore

/// Settings › Content Sources › Plugins › Test Providers. One section per provider with a Test
/// button: it runs the provider on a fixed sample title (a movie, or S1E1 for a series-only
/// provider) through the same runtime the stream list uses, then lists what came back under the
/// button: the sample, how many streams, how long it took, the first few streams, the steps, or
/// the error. For finding out why a provider returns nothing without opening a title. Android TV
/// parity: `PluginManager.testScraper` and its diagnostics steps.
///
/// A pushed `List` like the other settings sub-pages: stock rows, no glass, a system spinner while
/// a test runs, and every state keeps at least one focusable row (the Test buttons).
struct PluginProviderTestView: View {
    @ObservedObject var plugins: PluginsViewModel

    var body: some View {
        List {
            if plugins.scrapers.isEmpty {
                // Keeps a focusable row, so the page can always be entered and left.
                SettingsSection(
                    title: nil,
                    footer: String(localized: "Install a plugin repository first. Its providers will be listed here.")
                ) {
                    SettingsActionRow(title: String(localized: "Refresh Plugins"), systemImage: "arrow.clockwise") {
                        plugins.refreshAll()
                    }
                }
            }
            ForEach(plugins.repositories, id: \.manifestUrl) { repo in
                ForEach(plugins.scrapers(in: repo), id: \.id) { scraper in
                    providerSection(scraper, repository: repo)
                }
            }
            if let failure = plugins.testFailure {
                SettingsSection(title: nil) {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(String(localized: "Test Providers"))
        .onAppear { plugins.start() }
    }

    private func providerSection(_ scraper: PluginScraper, repository: PluginRepositoryItem) -> some View {
        let isRunning = plugins.testingScraperId == scraper.id
        let report = plugins.testReports[scraper.id]
        return SettingsSection(title: scraper.name, footer: repository.name) {
            Button {
                plugins.testScraper(scraper)
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    SettingsRowLabel(
                        title: String(localized: "Test Provider"),
                        subtitle: summary(report, isRunning: isRunning),
                        systemImage: "play.circle"
                    )
                    Spacer(minLength: 0)
                    if isRunning { ProgressView() }
                }
            }
            // One test at a time: the others wait, the running one keeps focus.
            .disabled(plugins.testingScraperId != nil && !isRunning)

            if let report, !isRunning {
                reportRows(report)
            }
        }
    }

    /// The button's subtitle: what the last run found, or what a run does.
    private func summary(_ report: PluginTestReport?, isRunning: Bool) -> String {
        if isRunning { return String(localized: "Running\u{2026}") }
        guard let report else { return String(localized: "Run this provider on a sample title") }
        let error: String? = report.error
        if let error { return error }
        return resultLine(report)
    }

    private func resultLine(_ report: PluginTestReport) -> String {
        let count = Int(report.streamCount)
        let streams = count == 1 ? String(localized: "1 stream") : String(localized: "\(count) streams")
        return "\(streams) \u{00B7} \(Self.seconds(report.elapsedMs))"
    }

    @ViewBuilder
    private func reportRows(_ report: PluginTestReport) -> some View {
        SettingsValueRow(title: String(localized: "Sample"), value: report.sample)
        let error: String? = report.error
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(SettingsRowFont.subtitle)
                .foregroundStyle(.red)
        } else {
            SettingsValueRow(title: String(localized: "Result"), value: resultLine(report))
            ForEach(Array(report.streams.enumerated()), id: \.offset) { _, stream in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(stream.title)
                        .font(SettingsRowFont.subtitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    let detail: String = stream.detail
                    if !detail.isEmpty {
                        Text(detail)
                            .font(SettingsRowFont.sectionHeader)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if Int(report.streamCount) > report.streams.count {
                Text(String(localized: "and \(Int(report.streamCount) - report.streams.count) more"))
                    .font(SettingsRowFont.sectionHeader)
                    .foregroundStyle(.secondary)
            }
        }
        Text(report.steps.joined(separator: "\n"))
            .font(SettingsRowFont.sectionHeader)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text(String(localized: "Steps")))
            .accessibilityValue(Text(report.steps.joined(separator: ". ")))
    }

    private static func seconds(_ milliseconds: Int64) -> String {
        if milliseconds < 1000 { return "\(milliseconds) ms" }
        return String(format: "%.1f s", Double(milliseconds) / 1000)
    }
}
