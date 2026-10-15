import AVFoundation
import Foundation
import UIKit

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
///    a scrub, how the clicks in a row add up;
///  - the system player's own view tree (class, frame, alpha, label text and font, image, running
///    animations) shortly after the bar appears, after it has settled, and after every rate change (pause,
///    resume, scan). If the controls are drawn in this process the dump names the glyph, its place and its
///    size; if they are drawn out of process it comes back nearly empty, and an HDMI capture is the only
///    way to read them. Class names are read, never used.
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
    private weak var playerRoot: UIView?

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
                self?.dumpPlayerViews(after: 0.2, label: String(format: "after rate %.2f", new))
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
    func transportBar(visible: Bool, root: UIView? = nil) {
        guard Self.isEnabled else { return }
        if let root { playerRoot = root }
        let now = ProcessInfo.processInfo.systemUptime
        if let changed = barChangedAt {
            log(String(format: "transport bar %@ (%.2f s after the last change)", visible ? "SHOWN" : "HIDDEN", now - changed))
        } else {
            log("transport bar \(visible ? "SHOWN" : "HIDDEN")")
        }
        barChangedAt = now
        if visible {
            dumpPlayerViews(after: 0.05, label: "bar appearing")
            dumpPlayerViews(after: 0.6, label: "bar settled")
        }
    }

    // MARK: - View tree

    /// Logs the system player's view tree `delay` seconds from now.
    func dumpPlayerViews(after delay: TimeInterval, label: String) {
        guard Self.isEnabled else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, let root = self.playerRoot else { return }
            self.log(String(format: "view tree, %@ (+%.2f s)", label, delay))
            self.dump(root, depth: 0)
        }
    }

    private func dump(_ view: UIView, depth: Int) {
        var line = String(repeating: "  ", count: depth) + String(describing: type(of: view))
        let f = view.frame
        line += String(format: " x=%.0f y=%.0f w=%.0f h=%.0f a=%.2f", f.origin.x, f.origin.y, f.size.width, f.size.height, view.alpha)
        if view.isHidden { line += " hidden" }
        if let label = view as? UILabel {
            line += " text=\"\(label.text ?? "")\" font=\(label.font.fontName) \(label.font.pointSize)"
        }
        if let image = view as? UIImageView {
            line += " image=\(image.image.map { String(describing: $0) } ?? "nil")"
        }
        if let keys = view.layer.animationKeys(), !keys.isEmpty { line += " anim=\(keys)" }
        print("[SpecProbe]   " + line)
        guard depth < 8 else { return }
        for sub in view.subviews { dump(sub, depth: depth + 1) }
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
