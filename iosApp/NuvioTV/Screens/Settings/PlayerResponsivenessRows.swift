import Combine
import SwiftUI

/// Developer > Player Responsiveness: what `MainThreadStallMonitor` recorded while a player was on
/// screen. After playing a very large stream, the longest main-thread stall and the libmpv call that
/// was in flight during it tell whether the UI ever stopped, and who stopped it. "libmpv calls on the
/// main thread" must read 0: the main thread never calls libmpv synchronously.
struct PlayerResponsivenessRows: View {
    @State private var report = MainThreadStallMonitor.shared.snapshot()

    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            SettingsValueRow(
                title: String(localized: "settings.developer.responsiveness.longest", defaultValue: "Longest UI Stall",
                              comment: "Developer readout: the longest time the player screen stopped answering"),
                value: report.longestStallMs > 0
                    ? "\(report.longestStallMs) ms"
                    : String(localized: "settings.developer.responsiveness.none", defaultValue: "None",
                             comment: "Developer readout: no stall was recorded")
            )
            SettingsValueRow(
                title: String(localized: "settings.developer.responsiveness.during", defaultValue: "libmpv Call During It",
                              comment: "Developer readout: the player-core call that was running during the longest stall"),
                value: report.longestStallMs > 0 ? report.longestStallDuring : "\u{2014}"
            )
            SettingsValueRow(
                title: String(localized: "settings.developer.responsiveness.count", defaultValue: "Stalls Over 250 ms",
                              comment: "Developer readout: how many stalls longer than a quarter of a second were recorded"),
                value: "\(report.stallCount)"
            )
            SettingsValueRow(
                title: String(localized: "settings.developer.responsiveness.slowest", defaultValue: "Slowest libmpv Call",
                              comment: "Developer readout: the slowest call made into the player core"),
                value: report.slowestCallMs > 0 ? "\(report.slowestCallName) \u{00B7} \(report.slowestCallMs) ms" : "\u{2014}"
            )
            SettingsValueRow(
                title: String(localized: "settings.developer.responsiveness.mainCalls", defaultValue: "libmpv Calls on Main Thread",
                              comment: "Developer readout: calls into the player core made on the main thread, which should be none"),
                value: report.mainThreadCalls == 0
                    ? "0"
                    : "\(report.mainThreadCalls) \u{00B7} \(report.firstMainThreadCall)"
            )
            SettingsActionRow(
                title: String(localized: "settings.developer.responsiveness.reset", defaultValue: "Reset Readout",
                              comment: "Developer button: clears the player responsiveness readout"),
                systemImage: "arrow.counterclockwise"
            ) {
                MainThreadStallMonitor.shared.reset()
                report = MainThreadStallMonitor.shared.snapshot()
            }
        }
        .onReceive(refresh) { _ in
            let latest = MainThreadStallMonitor.shared.snapshot()
            if latest != report { report = latest }
        }
        .onAppear { report = MainThreadStallMonitor.shared.snapshot() }
    }
}
