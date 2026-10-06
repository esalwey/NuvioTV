import SwiftUI
import SharedCore

/// CW legacy diagnosis (REMAINING_FIX #1): the Continue Watching report, for a reporter who has a
/// TV and no Mac console. A card launched from Home that stays on its old episode after a chain
/// of autoplayed episodes has three possible causes, and the report names each one:
/// `ALIAS?` (the same show stored under a TMDB and an IMDb id, so two cards), `FUTURE` (a row
/// dated ahead of the clock, which outranks every real one) and `xprof` (the progress was written
/// for another profile than the one Home reads).
///
/// Live, no relaunch: the report is a snapshot of the shared repository
/// (`WatchProgressRepository.continueWatchingDiagnosticLines`), taken when these rows appear, when
/// the switch is turned on, and on Refresh. The capture protocol is "turn on, play from the card,
/// come back here, press Refresh, photograph every page".
///
/// One child of `DeveloperSettingsPane`'s innermost `Group` (see that file's comments on the
/// 10-child @ViewBuilder ceiling); its rows join the enclosing List section like any other row.
/// VIS-01: it moved there from About with the other diagnostics, so it only shows once the hidden
/// Developer pane is unlocked; "Hide Developer Settings" also resets `debug.cwDiagnostics`.
struct ContinueWatchingDiagnosticsRows: View {
    @AppStorage("debug.cwDiagnostics") private var enabled = false
    @State private var lines: [String] = []

    var body: some View {
        SettingsToggleRow(
            title: String(localized: "Continue Watching Diagnostics"),
            subtitle: enabled
                ? String(localized: "Play from the card, come back here, press Refresh, then photograph every page")
                : String(localized: "Turn on if asked to capture why a Continue Watching card stays out of date"),
            isOn: $enabled
        )
        .onAppear { reload() }
        .onChange(of: enabled) { _, _ in reload() }

        if enabled {
            SettingsActionRow(title: String(localized: "Refresh")) { reload() }

            // Same paged rendering as Row Settle Diagnostics — one List row per page, each with a
            // no-op focusable anchor so the remote can scroll to it — but in the report's own
            // order (`PinnedRowSettleProbe.pages`, not `displayPages`): this is one snapshot, not
            // a log, and its header belongs on page 1.
            let pages = PinnedRowSettleProbe.pages(lines)
            ForEach(Array(pages.enumerated()), id: \.offset) { pageIndex, pageLines in
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Continue Watching Diagnostics · page \(pageIndex + 1)/\(pages.count)"))
                        .font(SettingsRowFont.subtitle)
                        .foregroundStyle(.secondary)
                    // `.truncationMode(.middle)` as in the other readouts: a row line starts with
                    // its id and ends with its markers, the two halves a reader needs.
                    ForEach(Array(pageLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .focusable()
                .accessibilityIdentifier(pageIndex == 0 ? "cw_diagnostics_lines" : "cw_diagnostics_page_\(pageIndex + 1)")
                .overlay(alignment: .topLeading) {
                    if pageIndex == 0 {
                        // Hidden single-Text blob, same pattern as `settle_probe_blob`: the whole
                        // report for a harness walk, which only sees the visible lines otherwise.
                        Text(lines.joined(separator: "\n"))
                            .font(.system(size: 4))
                            .opacity(0.011)
                            .accessibilityIdentifier("cw_diagnostics_blob")
                    }
                }
            }
        }
    }

    /// The shared call never throws (a failure comes back as the report's only line).
    private func reload() {
        lines = enabled ? WatchProgressRepository.shared.continueWatchingDiagnosticLines() : []
    }
}
