import AVFoundation
import Foundation

/// Reads the system player's behaviour off a device, to replace the [MEASURE] stand-ins of
/// `PlayerSpec` with values (docs/player-spec.md, "Calibrating on a device").
///
/// Off unless `debug.playerSpecProbe` is set (Developer pane › Player Look › System Player Probe, or
/// the launch argument `-debug.playerSpecProbe YES`). On, the NATIVE engine — the system player itself
/// — prints `[SpecProbe]` lines to the console with the uptime they happened at:
///  - when the transport bar appears and disappears, and how long it stayed (the auto-hide delay
///    after a click, a touch, a skip, a pause);
///  - every change of the playback rate (a scan at 2x / 3x / 4x, a pause, a resume) with the position;
///  - every jump of the playhead that time alone does not explain: the size of a ±10 s skip, the target of
///    a scrub, how the clicks in a row add up.
/// Run the remote script of the document against a native-engine file, read the lines, write the numbers
/// into `PlayerSpec` and the document. Costs nothing when off.
@MainActor
final class SystemPlayerSpecProbe {
    static let shared = SystemPlayerSpecProbe()
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: PlayerTuning.specProbeKey) }

    private var player: AVPlayer?
    private var rateObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var startedAt: TimeInterval = 0
    private var barChangedAt: TimeInterval?
    private var lastSample: (position: Double, uptime: TimeInterval)?

    private init() {}

    /// Starts watching `player` (the native engine's). No-op unless the probe is on.
    func attach(to player: AVPlayer) {
        guard Self.isEnabled else { return }
        detach()
        self.player = player
        startedAt = ProcessInfo.processInfo.systemUptime
        rateObservation = player.observe(\.rate, options: [.old, .new]) { [weak self] observed, change in
            let old = change.oldValue ?? 0
            let new = change.newValue ?? 0
            let position = CMTimeGetSeconds(observed.currentTime())
            Task { @MainActor [weak self] in
                self?.log(String(format: "rate %.2f \u{2192} %.2f at %.2f s", old, new, position.isFinite ? position : -1))
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.sample(CMTimeGetSeconds(time)) }
        }
        log("attached \u{2014} perform the remote script now")
    }

    func detach() {
        rateObservation?.invalidate()
        rateObservation = nil
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player = nil
        barChangedAt = nil
        lastSample = nil
    }

    /// `AVPlayerViewControllerDelegate.willTransitionToVisibilityOfTransportBar`: the bar is about to appear
    /// or go away. A hide logs how long the bar had been up.
    func transportBar(visible: Bool) {
        guard Self.isEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let changed = barChangedAt {
            log(String(format: "transport bar %@ (%.2f s after the last change)", visible ? "SHOWN" : "HIDDEN", now - changed))
        } else {
            log("transport bar \(visible ? "SHOWN" : "HIDDEN")")
        }
        barChangedAt = now
    }

    // MARK: - Playhead

    /// Called at 10 Hz: a position that is not where time alone would have put it is a jump.
    private func sample(_ position: Double) {
        guard position.isFinite else { return }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastSample = (position, now) }
        guard let last = lastSample, let player else { return }
        let expected = last.position + (now - last.uptime) * Double(player.rate)
        let delta = position - expected
        if abs(delta) > 1.5 {
            log(String(format: "playhead jump %.2f \u{2192} %.2f s (%+.2f s), rate %.2f", last.position, position, position - last.position, player.rate))
        }
    }

    private func log(_ message: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
        print(String(format: "[SpecProbe] +%.3f %@", elapsed, message))
    }
}
