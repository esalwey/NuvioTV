import SwiftUI
import Combine
import AVFoundation
import AVKit
import SharedCore

/// A looping, controls-free trailer surface behind the Detail hero, backed by **AVPlayer**. Starts
/// muted and follows the shared `HeroTrailerAudioState` (same singleton the mobile app's hero
/// trailer uses) from then on, so the user's mute/unmute choice persists across titles for the
/// session. The Siri Remote's play/pause button controls mute/unmute.
///
/// This replaced an earlier libmpv/Vulkan implementation: a second Vulkan (MoltenVK) context running
/// alongside an interactive SwiftUI screen asserts on the tvOS simulator whenever Detail re-renders
/// (e.g. toggling "In Library"). AVPlayer renders through Metal/CoreAnimation natively, coexists with
/// SwiftUI, and simply shows nothing (never crashes) if a stream fails. It needs an AVPlayer-friendly
/// URL — the shared resolver now provides `TrailerPlaybackSource.progressiveUrl` (H.264/MP4 or HLS).
///
/// `onFailure` fires if the trailer can't start, so the host removes it and keeps the static backdrop.
/// It carries a `TrailerFailureReport` (BUG-46/B2) so the host can tell a transient playback failure
/// from "this title genuinely has nothing to play" when it decides what to remember.

/// A UIView hosting an `AVPlayerLayer` as a managed SUBLAYER.
///
/// BUG-59 (reveal-gate wave, pixel-oracle finding): the player layer used to be the view's
/// BACKING layer (`layerClass`), with the measured letterbox zoom applied to that layer's affine
/// transform — and a hosted view's backing-layer transform/frame belong to SwiftUI, which
/// re-asserts them on every layout pass. The zoom was silently neutralized: every `[TrailerZoom]`
/// line said `applied=1.343` while the rendered pixels kept their bars. That is why UX-9/BUG-59
/// kept "passing" every log-based gate (the Wave 7 sim soak, the 08-18 device pass read the log
/// stream, not pixels) while the reporter kept counting bars on beta.12 — the measurement was
/// fixed; the RENDERING never was. The 2026-08-19 cold-dwell screenshot oracle caught it: playing
/// tiles showed their 12.8 % bars with a 1.343 interim already logged.
///
/// A sublayer's transform is ours alone. `layoutSubviews` re-asserts bounds, position AND the
/// crop zoom together, so no layout pass can ever split them again — and the view's
/// `clipsToBounds` genuinely crops the overscaled sublayer at the tile edge (a parent mask clips
/// composited children after their own transforms, unlike a backing layer masking its own
/// content).
final class TrailerPlayerUIView: UIView {
    let playerLayer = AVPlayerLayer()

    /// The measured crop zoom (UX-9/BUG-59). Stored so every layout pass re-applies it; set it
    /// through `setCropZoom(_:animated:)`.
    private var cropZoom: CGFloat = 1

    /// BUG-92 concentricity check (Wave F item C): what the last `layer` probe line reported, so
    /// `logLayerIfNeeded()` only logs when the zoom or the bounds actually changed instead of on
    /// every layout pass (this view's `layoutSubviews` fires far more often than the crop does).
    private var lastLoggedZoom: CGFloat?
    private var lastLoggedBoundsSize: CGSize?

    /// Phase 0 (BUG-46): ground truth for the live-pipeline leak probe, independent of the
    /// `Coordinator.attach`/`teardown()` bookkeeping — a `liveViews` count that climbs while
    /// browsing proves the leak even if some future attach/teardown accounting drifts.
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(playerLayer)
        if TrailerProbe.enabled {
            let snap = TrailerPipelineCounters.shared.viewCreated()
            NSLog("[TrailerPipeline] view created live=%d players=%d", snap.liveViews, snap.livePlayers)
        }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(playerLayer)
        if TrailerProbe.enabled {
            let snap = TrailerPipelineCounters.shared.viewCreated()
            NSLog("[TrailerPipeline] view created live=%d players=%d", snap.liveViews, snap.livePlayers)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Non-animated on purpose: layout runs mid-morph (UX-4a width animation), and letting the
        // implicit layer animations fire here would trail the SwiftUI-driven frame.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.bounds = bounds
        playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        playerLayer.setAffineTransform(CGAffineTransform(scaleX: cropZoom, y: cropZoom))
        CATransaction.commit()
        logLayerIfNeeded()
    }

    /// The one write path for the crop zoom (probe interim/final/persisted). Render-only: bounds
    /// and position are untouched, so UX-4a's morph geometry and BUG-29's expansion scroll never
    /// see it.
    func setCropZoom(_ zoom: CGFloat, animated: Bool) {
        cropZoom = zoom
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.25) }
        playerLayer.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
        CATransaction.commit()
        // A zoom change alone doesn't always invalidate layout (bounds/position are unchanged),
        // so nudge one so `logLayerIfNeeded()` (in `layoutSubviews`) actually runs and the BUG-92
        // concentricity check gets a fresh `dx=`/`dy=` reading close to when the crop changed.
        setNeedsLayout()
    }

    /// BUG-92 concentricity check: `dx`/`dy` are the player layer's centre offset from this view's
    /// own centre. `layoutSubviews` always re-centres the layer by construction (see above), so a
    /// non-zero reading here means something OTHER than this transform is pushing the video off
    /// centre — expected `dx=0.00 dy=0.00` on every sample.
    private func logLayerIfNeeded() {
        guard lastLoggedZoom != cropZoom || lastLoggedBoundsSize != bounds.size else { return }
        lastLoggedZoom = cropZoom
        lastLoggedBoundsSize = bounds.size
        let frame = playerLayer.frame
        let dx = frame.midX - bounds.midX
        let dy = frame.midY - bounds.midY
        TrailerZoomProbe.log(String(format: "layer bounds=%.0fx%.0f zoom=%.3f dx=%.2f dy=%.2f",
                                     bounds.width, bounds.height, cropZoom, dx, dy))
    }

    deinit {
        if TrailerProbe.enabled {
            let snap = TrailerPipelineCounters.shared.viewDestroyed()
            NSLog("[TrailerPipeline] view destroyed live=%d players=%d", snap.liveViews, snap.livePlayers)
        }
    }
}

/// What a failing trailer surface hands its host (BUG-46/B2).
///
/// The Phase 0 `TrailerFailureCause` alone can't answer the two questions the inline card's negative
/// cache has to ask — "was this an HTTP 404?" and "was it OUR loopback playlist server that 404'd?"
/// — because the status code lives in `AVPlayerItem.errorLog()`, never on the `NSError` for HLS
/// playback. Rather than reshape the Phase 0 enum (whose classification is deliberately
/// observation-only, and whose `logSuffix` output the soak harness greps), the coordinator reports
/// the cause *together with* the two extra facts it already reads for the `[TrailerPipeline] fail`
/// line.
struct TrailerFailureReport {
    let cause: TrailerFailureCause
    /// `AVPlayerItemErrorLogEvent.errorStatusCode` of the last error-log event, when there was one.
    let httpStatus: Int?
    /// The URL this surface was attached to — the raw string, so it is present even for `.badURL`.
    let urlString: String?
}

struct TrailerHeroPlayer: UIViewRepresentable {
    let urlString: String
    var onFailure: (TrailerFailureReport) -> Void = { _ in }
    /// BUG-59: identity the measured zoom is remembered under — the TITLE (`type:id`, the same
    /// key `TrailerResolutionCache` uses), not the playback URL. Loopback repack URLs change per
    /// process (port) and per re-extraction (token), so a URL-keyed memo forgot everything it
    /// learned on every relaunch. `nil` falls back to the URL (unit tests / callers without a
    /// title).
    var zoomKey: String? = nil
    /// BUG-81: the YouTube video id this surface's stream was extracted from
    /// (`TrailerPlaybackSource.videoId`), when the caller still holds it. It is the only identifier
    /// of "which trailer is this" that survives a re-extraction, so the letterbox probe keys its
    /// persisted-zoom VERIFY comparison on it. `nil` is fine and common — the probe then looks the
    /// URL up in `TrailerVideoIdRegistry` (which the resolver populates for every surface,
    /// including the ones that replay a memoized URL with no source in scope) and falls back to the
    /// URL-derived identity from there.
    var videoId: String? = nil
    /// `true` (the default, and what the Detail hero uses) keeps the endless `AVPlayerLooper` this
    /// view was written for. `false` plays the item exactly once and reports the end through
    /// `onPlaybackEnded` — the inline catalog card uses that to collapse itself back to a poster
    /// instead of looping a trailer under the user's focus forever.
    var loops: Bool = true
    /// Only ever fires when `loops == false`; main-queue.
    var onPlaybackEnded: (() -> Void)? = nil
    /// BUG-92 (beta.18): the tile's INNER corner radius (`InlineTrailerTileGeometry.inner(...).radius`
    /// for the inline card), applied directly to the hosted view's own `CALayer` so the video is
    /// clipped by its own layer — see `makeUIView` below. Defaults to 0 (a plain rectangular clip,
    /// i.e. no visible rounding), which is exactly what the Detail hero loop wants (its surface is
    /// the full-bleed hero backdrop, never rounded) and what every existing caller that doesn't pass
    /// this parameter keeps getting.
    var cornerRadius: CGFloat = 0

    /// UX-9: our YouTube trailer encodes bake letterboxing directly into the frame (2.39:1 film
    /// inside a 16:9 container), so `.resizeAspectFill` alone still shows black bars — it fills the
    /// *container* while the bars stay part of the *image*. Upstream Compose hides them with a flat
    /// parity scale on the trailer surface (DetailHero.kt:145–153, `scaleX = scaleY = 1.08f`), and
    /// this constant mirrors it exactly.
    ///
    /// It is now the **floor**, not the answer: a flat 1.08 leaves most of a 2.39:1 bar on screen,
    /// while the ~1.33 crop that would undo one exactly would eat >20% of a genuinely-16:9 trailer.
    /// Neither was ever knowable from metadata (innertube's coded dimensions, our synthesized
    /// `RESOLUTION=`, and `presentationSize` all read 1920x1080 for a bars-baked-into-16:9 encode —
    /// the bars *are* the picture as far as AVFoundation is concerned), so `TrailerLetterboxProbe`
    /// measures the decoded luma instead and every surface renders at `max(measured, parityZoom)`.
    /// A source with no bars therefore still renders byte-identically to what shipped before.
    static let parityZoom: CGFloat = 1.08

    func makeUIView(context: Context) -> TrailerPlayerUIView {
        let view = TrailerPlayerUIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        // Never set before UX-9: once the trailer surface is scaled past fill (see `parityZoom`
        // above) to hide baked-in letterbox bars, the overscaled edges must not bleed past this
        // view's bounds into whatever sits around it. With the zoom on the player SUBLAYER now
        // (see `TrailerPlayerUIView`), this genuinely clips it — a parent mask crops composited
        // children after their transforms — with the inline tile's `.clipShape`
        // (InlineTrailerCard) and the screen edges (Detail hero / full-screen) as the outer
        // clips.
        view.clipsToBounds = true
        // BUG-92: rounds the HOST view's own layer (the one `clipsToBounds` above already crops
        // against), independent of whatever SwiftUI `.clipShape` mask the caller draws over this
        // representable. A SwiftUI mask alone left a rectangular sliver of the video showing past
        // the tile's rounded corners — a mask composites AFTER the platform draws the hosted
        // UIKit content, and on some focus/depth-effect frames that composite pass lands a half
        // pixel outside the mask's own anti-aliased edge. Rounding the layer that actually holds
        // the pixels removes the seam at the source instead of relying on a second, independently
        // laid-out shape to line up with it exactly.
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        view.playerLayer.videoGravity = .resizeAspectFill
        context.coordinator.attach(to: view, urlString: urlString, loops: loops, zoomKey: zoomKey, videoId: videoId)
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerUIView, context: Context) {
        // BUG-92: `cornerRadius` can change across re-renders (Poster Style → Corners is a live
        // Settings toggle) even while a tile keeps playing — `makeUIView` alone would leave a
        // stale radius on screen until the next expand/collapse recreated the view.
        guard uiView.layer.cornerRadius != cornerRadius else { return }
        uiView.layer.cornerRadius = cornerRadius
    }

    static func dismantleUIView(_ uiView: TrailerPlayerUIView, coordinator: Coordinator) {
        coordinator.teardown()
        // BUG-46/B1 belt-and-braces: `teardown()` detaches through its own weak handle on the view,
        // which is already nil on the deinit-driven path. The layer is right here on this one, so
        // detach it directly too — an AVPlayerLayer still pointing at a player is a live decode
        // pipeline no matter who else let go.
        uiView.playerLayer.player = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFailure: onFailure, onPlaybackEnded: onPlaybackEnded)
    }

    /// Owns the AVPlayer, looping, and failure detection.
    final class Coordinator {
        private let onFailure: (TrailerFailureReport) -> Void
        private let onPlaybackEnded: (() -> Void)?
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private var statusObservation: NSKeyValueObservation?
        private var failureObserver: NSObjectProtocol?
        private var endObserver: NSObjectProtocol?
        private var watchdog: Timer?
        private var audioWatcher: FlowWatcher?
        private var started = false
        private var failed = false
        private var ended = false
        /// The URL `attach()` was handed. Phase 0 logs it (redacted) in `teardown()`; B2 reports it
        /// with a failure so the host can tell a loopback-repack URL from a direct googlevideo one.
        private var attachedURLString: String?
        /// BUG-46/B1: the view whose `AVPlayerLayer` this coordinator's player is wired into, so
        /// `teardown()` can unwire it. Weak — the view owns nothing here and outlives nothing.
        private weak var attachedView: TrailerPlayerUIView?
        /// UX-9: measures the baked-in letterbox bars off the decoded frames and drives the layer's
        /// zoom. Lives for exactly one attach, like everything else here.
        private var letterboxProbe: TrailerLetterboxProbe?
        /// Instrumentation pairing guard: `teardown()` runs twice per lifecycle (explicit
        /// `dismantleUIView` + `deinit`), so the counter must decrement exactly once per counted
        /// `attach()` or the live-pipeline gauge undercounts (Codex round 1).
        private var attachCounted = false

        init(onFailure: @escaping (TrailerFailureReport) -> Void, onPlaybackEnded: (() -> Void)? = nil) {
            self.onFailure = onFailure
            self.onPlaybackEnded = onPlaybackEnded
        }

        func attach(to view: TrailerPlayerUIView, urlString: String, loops: Bool = true, zoomKey: String? = nil,
                    videoId: String? = nil) {
            attachedURLString = urlString
            attachedView = view
            guard let url = URL(string: urlString) else { fail(.badURL); return }

            if TrailerProbe.enabled {
                attachCounted = true
                let snap = TrailerPipelineCounters.shared.attach()
                NSLog("[TrailerPipeline] attach live=%d views=%d url=%@", snap.livePlayers, snap.liveViews, TrailerProbe.redactedHost(urlString))
            }

            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.allowsExternalPlayback = false

            // Seed with the shared preference's current value (rather than always hardcoding muted)
            // so re-attaching (e.g. returning to a title after unmuting) doesn't flash muted first.
            let audioState = HeroTrailerAudioState.shared
            queue.isMuted = (audioState.muted.value_ as? KotlinBoolean)?.boolValue ?? true
            audioWatcher = FlowWatcherKt.watch(audioState.muted) { [weak self] emitted in
                guard let self, let boxed = emitted as? KotlinBoolean else { return }
                self.player?.isMuted = boxed.boolValue
            }

            if loops {
                looper = AVPlayerLooper(player: queue, templateItem: item)
            } else {
                // Single pass: no looper, and the end-of-item notification is the signal the host
                // waits on. (`AVPlayerLooper` swallows this notification by design, which is why
                // the two paths can't share an install.)
                queue.insert(item, after: nil)
                endObserver = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self] _ in self?.finish() }
            }
            view.playerLayer.player = queue
            player = queue

            statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
                switch observed.status {
                case .failed: self?.fail(.itemFailed(observed.error as NSError?), item: observed)
                case .readyToPlay:
                    self?.started = true
                    #if DEBUG
                    // UX-4c verification: log the actual resolved stream resolution. With the
                    // master-playlist bug the presentationSize sat at ~854x480; the pinned
                    // top-resolution variant should report ~1920x1080. presentationSize can be
                    // .zero at the readyToPlay edge, so log a beat later.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak observed] in
                        guard let item = observed else { return }
                        let size = item.presentationSize
                        // NSLog (not print): lands in unified logging, so `log show` can read it
                        // even when no console pty is attached.
                        NSLog("[TrailerQuality] presentationSize=%dx%d", Int(size.width), Int(size.height))
                    }
                    #endif
                default: break
                }
            }
            failureObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self?.fail(.failedToPlayToEnd(error), item: item)
            }

            queue.play()

            // UX-9: start measuring the baked-in bars. Anchored to `play()`, not `readyToPlay`, for
            // the same reason the presentationSize probe below is — and the probe reads
            // `player.currentItem` on every sample rather than capturing `item`, so the `loops`
            // path measures the copies `AVPlayerLooper` actually plays.
            //
            // Trailer Diagnostics surface naming: `loops == true` is the Detail hero's endless
            // background loop (`hero`); `loops == false` is the catalog inline preview tile
            // (`inline`, `InlineTrailerCard`'s only caller) — the two share this one representable,
            // so the surface name has to come from which mode the caller asked for.
            letterboxProbe = TrailerLetterboxProbe(view: view, player: queue, urlString: urlString, zoomKey: zoomKey, videoId: videoId, surface: loops ? "hero" : "inline")
            letterboxProbe?.start()

            #if DEBUG
            // UX-4c verification: log the resolved stream's actual resolution. Anchored to
            // play() rather than the readyToPlay KVO case above, because that observation
            // (options: [.new]) demonstrably never fires for this item (the watchdog below
            // only survives via timeControlStatus) — see BUG notes in the beta.9 batch.
            // Read the QUEUE's current item, not the template `item`: with loops == true the
            // AVPlayerLooper plays copies of the template, whose own presentationSize stays 0x0.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak queue] in
                guard let current = queue?.currentItem else { return }
                let size = current.presentationSize
                NSLog("[TrailerQuality] presentationSize=%dx%d", Int(size.width), Int(size.height))
            }
            #endif

            // Insurance: if nothing is playing within a few seconds, give up (static fallback).
            let timer = Timer(timeInterval: 6, repeats: false) { [weak self] _ in
                guard let self else { return }
                if !self.started && self.player?.timeControlStatus != .playing {
                    self.fail(.watchdogTimeout)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }

        /// Phase 0 classified the failure so the log line reads as a diagnosis; B2 now also *reports*
        /// it, so the host's negative cache can distinguish "this stream broke" from "this title has
        /// nothing to play". The HTTP status is read unconditionally now (it used to be probe-gated):
        /// it is the only channel that surfaces an evicted-token 404 from the loopback repack server,
        /// and B2's invalidation has to work on a tester's release sideload with the knob off.
        private func fail(_ cause: TrailerFailureCause, item: AVPlayerItem? = nil) {
            guard !failed, !ended else { return }
            failed = true
            let httpStatus = item?.errorLog()?.events.last?.errorStatusCode
            if TrailerProbe.enabled {
                let snap = TrailerPipelineCounters.shared.failure(cause: cause.tag)
                NSLog("[TrailerPipeline] fail cause=%@ %@ live=%d", cause.tag, cause.logSuffix(httpStatus: httpStatus), snap.livePlayers)
            }
            let report = TrailerFailureReport(cause: cause, httpStatus: httpStatus, urlString: attachedURLString)
            DispatchQueue.main.async { self.onFailure(report) }
        }

        /// Non-looping playback reached the end of the item — once only, and never after a failure.
        private func finish() {
            guard !failed, !ended else { return }
            ended = true
            guard let onPlaybackEnded else { return }
            DispatchQueue.main.async { onPlaybackEnded() }
        }

        func teardown() {
            if TrailerProbe.enabled, attachCounted {
                attachCounted = false
                let snap = TrailerPipelineCounters.shared.teardown()
                NSLog("[TrailerPipeline] teardown live=%d views=%d url=%@", snap.livePlayers, snap.liveViews, attachedURLString.map(TrailerProbe.redactedHost) ?? "-")
            }
            watchdog?.invalidate()
            watchdog = nil
            statusObservation?.invalidate()
            statusObservation = nil
            if let failureObserver {
                NotificationCenter.default.removeObserver(failureObserver)
                self.failureObserver = nil
            }
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            audioWatcher?.cancel()
            audioWatcher = nil
            letterboxProbe?.stop()
            letterboxProbe = nil
            player?.pause()
            // BUG-46/B1: pausing and dropping our reference is NOT enough to end the decode
            // pipeline. The queue still holds its items, the looper still holds its copies of the
            // template, and — the one that actually keeps the pipeline alive — the view's
            // AVPlayerLayer still points at the player. `FullScreenTrailerSurface.dismantleUIView`
            // has always done the layer detach, and it has never leaked; this is exact parity with
            // it. Order matters: disable the looper first (it re-enqueues items as they drain, so
            // draining the queue underneath a live looper is a race), then empty the queue, then
            // unwire the layer.
            looper?.disableLooping()
            looper = nil
            player?.removeAllItems()
            attachedView?.playerLayer.player = nil
            attachedView = nil
            player = nil
        }

        deinit { teardown() }
    }
}

/// Full-screen trailer playback with sound — presented from either the Detail action row's
/// "Watch Trailer" button (the hero trailer, already resolved for the muted background loop) or a
/// "Trailers & Extras" row item (resolved on demand). The presenting `fullScreenCover` handles
/// Menu-to-dismiss; the Siri Remote's play/pause button toggles pause; playback end reports out so
/// the host can dismiss instead of resting on a black end frame.
///
/// UX-9: this replaced an `AVPlayerViewController`. Our YouTube encodes bake letterbox bars into
/// the frame (see `TrailerHeroPlayer.parityZoom`), and the standard controller exposes no way to
/// overscale its video layer without also scaling the transport chrome — so full-screen trailers
/// were the one surface that still showed bars. A raw `AVPlayerLayer` gets the same
/// aspect-fill + measured-zoom treatment as every other trailer surface (`TrailerLetterboxProbe`
/// drives the layer transform; full-screen and ignoring the safe area, the screen edges do the
/// clipping). Trade-off, accepted deliberately: no scrub
/// bar — trailers are 1-2 minute clips and Back already exits. The controller swap also retires
/// BUG-18's display-criteria workaround by construction: a bare layer never renegotiates HDMI.
/// Deliberately a separate `AVPlayer` instance from `TrailerHeroPlayer` above (always unmuted —
/// FEAT-11's default only governs the background loop) — the two never run concurrently, so
/// there's no doubled decode/audio, and each keeps its own simple, single-purpose lifecycle.
struct FullScreenTrailerPlayer: View {
    let urlString: String
    var onPlaybackEnded: () -> Void = {}
    /// BUG-59: see `TrailerHeroPlayer.zoomKey`.
    var zoomKey: String? = nil
    /// BUG-81: see `TrailerHeroPlayer.videoId`.
    var videoId: String? = nil
    /// FEAT-32: called when the presenting cover STARTS dismissing (see
    /// `TrailerBridgeCoverObserver`). The surface is blanked first so the cover, whose background
    /// the host clears, reveals the description underneath at once.
    var onWillDismiss: () -> Void = {}

    /// Stable across body re-evals (@State keeps the instance); bridges the play/pause command
    /// to the representable's player without making the surface observable.
    @State private var control = FullScreenTrailerControl()

    var body: some View {
        // UX-9: no `.scaleEffect` any more — the zoom is measured per stream and applied to the
        // player layer itself (`TrailerLetterboxProbe`), with `parityZoom` as its floor, so this
        // surface still renders exactly as before for a bar-free 16:9 source.
        FullScreenTrailerSurface(urlString: urlString, zoomKey: zoomKey, videoId: videoId, control: control, onPlaybackEnded: onPlaybackEnded)
            .ignoresSafeArea()
            .background(TrailerBridgeCoverObserver {
                control.hideSurface()
                onWillDismiss()
            })
            .onPlayPauseCommand { control.togglePause() }
    }
}

/// Holds a weak handle to the full-screen player so the SwiftUI layer can toggle pause.
final class FullScreenTrailerControl {
    weak var player: AVPlayer?
    /// FEAT-32: the surface view, so the bridge can blank it the instant the cover starts
    /// dismissing (the cover keeps rendering its content until the dismissal ends).
    weak var surface: UIView?

    func hideSurface() {
        surface?.isHidden = true
    }

    func togglePause() {
        guard let player else { return }
        if player.timeControlStatus == .paused {
            player.play()
        } else {
            player.pause()
        }
    }
}

private struct FullScreenTrailerSurface: UIViewRepresentable {
    let urlString: String
    let zoomKey: String?
    let videoId: String?
    let control: FullScreenTrailerControl
    let onPlaybackEnded: () -> Void

    func makeUIView(context: Context) -> TrailerPlayerUIView {
        let view = TrailerPlayerUIView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        // UX-9: matches the inline/hero representable — clips the sublayer's measured zoom at the
        // view's bounds (see the note in `TrailerHeroPlayer.makeUIView`), with the screen edges
        // as the outer clip.
        view.clipsToBounds = true
        // BUG-94: policy-driven, not hardcoded — `TrailerSurfaceZoomPolicy.decide(surface: "full", …)`
        // always answers `.resizeAspect` regardless of `cached` (there's nothing cache-dependent to
        // read yet at `makeUIView` time), so this is the single source of truth `start()` below
        // will also consult, rather than a `.resizeAspectFill` literal that could drift from it.
        view.playerLayer.videoGravity = TrailerSurfaceZoomPolicy.decide(surface: "full", cached: nil).gravity
        if let url = URL(string: urlString) {
            let player = AVPlayer(url: url)
            player.isMuted = false
            view.playerLayer.player = player
            control.player = player
            control.surface = view
            context.coordinator.observeEnd(of: player, onEnded: onPlaybackEnded)
            context.coordinator.startLetterboxProbe(view: view, player: player, urlString: urlString, zoomKey: zoomKey, videoId: videoId)
            // Phase 0 (BUG-46): full-screen plays share `TrailerPipelineCounters` with the
            // inline/hero surfaces (`TrailerHeroPlayer.Coordinator`) so a full-screen "Watch
            // Trailer" doesn't misread as a leak in the inline/hero attach/teardown numbers.
            if TrailerProbe.enabled {
                let snap = TrailerPipelineCounters.shared.attach()
                NSLog("[TrailerPipeline] attach(full) live=%d views=%d url=%@", snap.livePlayers, snap.liveViews, TrailerProbe.redactedHost(urlString))
            }
            player.play()
        }
        return view
    }

    func updateUIView(_ uiView: TrailerPlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: TrailerPlayerUIView, coordinator: Coordinator) {
        coordinator.teardown()
        uiView.playerLayer.player?.pause()
        uiView.playerLayer.player = nil
        if TrailerProbe.enabled {
            let snap = TrailerPipelineCounters.shared.teardown()
            NSLog("[TrailerPipeline] teardown(full) live=%d views=%d", snap.livePlayers, snap.liveViews)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var endObserver: NSObjectProtocol?
        private var letterboxProbe: TrailerLetterboxProbe?

        func observeEnd(of player: AVPlayer, onEnded: @escaping () -> Void) {
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { _ in onEnded() }
        }

        /// UX-9: same probe the inline/hero surfaces use, so all three get their zoom from one
        /// implementation (and share its per-URL session cache — a title watched full-screen right
        /// after its inline preview starts already measured).
        func startLetterboxProbe(view: TrailerPlayerUIView, player: AVPlayer, urlString: String, zoomKey: String?,
                                 videoId: String?) {
            letterboxProbe = TrailerLetterboxProbe(view: view, player: player, urlString: urlString, zoomKey: zoomKey, videoId: videoId, surface: "full")
            letterboxProbe?.start()
        }

        func teardown() {
            if let endObserver {
                NotificationCenter.default.removeObserver(endObserver)
                self.endObserver = nil
            }
            letterboxProbe?.stop()
            letterboxProbe = nil
        }

        deinit { teardown() }
    }
}

// MARK: - BUG-94: full-screen "never crop" policy

/// BUG-94 (beta.18, product decision): the full-screen trailer surface (`surface == "full"` —
/// `FullScreenTrailerSurface` / its `Coordinator.startLetterboxProbe` below) must always play
/// UNCROPPED at zoom 1.0 with letterbox bars, the way the official Nuvio app does — never the
/// measured/cached crop the Detail hero loop and inline poster surfaces apply. Before this fix
/// `surface` was a log label only: `TrailerLetterboxProbe.start()` applied whatever
/// `TrailerZoomCache` had under `zoomKey` (title-keyed, and shared with the hero loop —
/// `DetailView.swift`'s hero and full-screen presenters pass the SAME key, so the full surface
/// inherited the hero loop's measured crop), `maxZoom`/`parityZoom` applied to every surface alike,
/// and both `makeUIView`s hardcoded `.resizeAspectFill`.
///
/// A pure, testable policy so "is this the full surface" is decided in exactly one place instead of
/// being sprinkled through `start()`, `finish()` and both representables' `makeUIView`.
enum TrailerSurfaceZoomPolicy {
    struct Decision {
        /// The zoom to apply immediately. Only consulted when `measure` is `false` — on the
        /// hero/inline path the existing ladder derives and applies its own zoom regardless of this
        /// value (see `measure`'s doc below).
        let zoom: CGFloat
        /// `.resizeAspect` never crops — this is what "never crop" actually requires:
        /// `.resizeAspectFill` at zoom 1.0 still crops a non-16:9 stream to fill the container,
        /// because it fills the box, not the picture. `.resizeAspectFill` is today's hero/inline
        /// treatment, unchanged.
        let gravity: AVLayerVideoGravity
        /// Whether `TrailerLetterboxProbe` may run its sampling ladder at all. `false` for the full
        /// surface: it never attaches a video output, never arms the tick timer, never reads or
        /// writes `TrailerZoomCache` — `start()` applies `zoom`/`gravity` once and returns. `true`
        /// for hero/inline: `start()`'s existing cache-read → parity-floor → interim → final ladder
        /// runs exactly as it did before this fix; this policy's `zoom` is never consulted there.
        let measure: Bool
        /// Whether a completed measurement may write `TrailerZoomCache`. Always `false` for the full
        /// surface (which never measures far enough to ask); `true` for hero/inline, unchanged.
        let persist: Bool
    }

    /// `cached` is accepted (not merely `nil`-defaulted) so a caller can prove the full branch is
    /// unconditional — a matching cached entry must not change the answer (see
    /// `TrailerZoomProbeTests.fullSurfaceAlwaysPlaysAtOne*`).
    static func decide(surface: String, cached: TrailerZoomCache.Entry?) -> Decision {
        if surface == "full" {
            return Decision(zoom: 1.0, gravity: .resizeAspect, measure: false, persist: false)
        }
        // hero/inline: unchanged. The values here document today's floor/gravity contract; the
        // actual zoom that ends up on screen still comes from `start()`'s existing ladder.
        return Decision(zoom: TrailerHeroPlayer.parityZoom, gravity: .resizeAspectFill, measure: true, persist: true)
    }
}

// MARK: - UX-9: measured letterbox zoom

/// BUG-59 (beta.13): the measured zoom is remembered per TITLE and PERSISTED — the beta.12 memo was
/// per playback URL and process-lifetime, and every loopback repack URL carries the process's port
/// and the extraction's token, so a relaunch or a re-extraction forgot everything: nearly every
/// focus started at the 1.08 floor and the ~90% letterbox the reporter counted is exactly that.
///
/// What is stored: `{zoom, token, at}` under the title key, capped at 300 entries (LRU by `at`),
/// as one JSON blob in `UserDefaults` under `storageKey` (`trailerZoom.v2` as of the C1 fix below).
/// Reads CLAMP every value into `[1.0, TrailerLetterboxProbe.maxZoom]`, drop entries older than 30
/// days, and drop the whole blob if its `version` differs — that last rule is the escape hatch for
/// the "every trailer was extremely zoomed until I reinstalled" report: a bad blob can never
/// outlive a version bump. The `token` (`TrailerLocalHLS` repack token, nil for direct URLs) says
/// WHICH stream the zoom was measured on: a match applies it immediately and arms the probe in
/// VERIFY mode (C1, 2026-08-30 investigation — see `TrailerLetterboxProbe.start()`); a mismatch
/// applies the parity floor, conceals, and re-measures from scratch.
///
/// NSLock-guarded rather than `@MainActor`, matching `TrailerPipelineCounters`: the probe reads it
/// from `TrailerHeroPlayer.Coordinator.attach`, which is not actor-isolated. Writes to
/// `UserDefaults` are coalesced (one encode per store; the blob is a few KB).
final class TrailerZoomCache: @unchecked Sendable {
    static let shared = TrailerZoomCache()

    struct Entry: Codable {
        let zoom: CGFloat
        let token: String?
        let at: TimeInterval
        /// C1 (2026-08-30) VERIFY-mode miss counter — BUG-81 item 2. `nil` for every entry written
        /// before this field existed (blob `version` stays 2; a missing key just decodes to `nil`,
        /// same as any other optional `Codable` property) and for a fresh cold-path `store()`, which
        /// has no verify history yet. Only the VERIFY path (`finish()`'s `insufficient` guard) ever
        /// increments it, and only `verify-confirmed`/`verify-corrected` ever reset it to 0 — a
        /// stream that keeps re-verifying cleanly never accumulates misses just from being watched.
        var verifyMisses: Int?
    }
    private struct Blob: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    static let storageKey = "trailerZoom.v2"
    static let version = 2
    /// C1 (2026-08-30 investigation): the pre-fix key, kept only so `loadIfNeeded()` can delete it.
    /// A `repack:<token>` identity is content-stable across app releases (the loopback repack token
    /// derives from the extracted stream, not the process), so a bad entry measured under betas ≤16
    /// — where a token MATCH applied and returned before the probe could ever re-check it (see
    /// `start()`) — would otherwise keep applying for up to `maxAge` (30 days) even after this fix
    /// ships, simply by surviving the app upgrade under the old key. Bumping `storageKey`/`version`
    /// is the hard reset: nothing written under `legacyStorageKey` is ever read again, and
    /// `loadIfNeeded()` deletes the dead blob outright on first launch of the fixed build instead of
    /// leaving it to rot in `UserDefaults`.
    private static let legacyStorageKey = "trailerZoom.v1"
    private static let capacity = 300
    private static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private let lock = NSLock()
    private var values: [String: Entry] = [:]
    private var loaded = false
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Test seam: an isolated instance over a throwaway suite.
    static func makeIsolated(suiteName: String) -> TrailerZoomCache {
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)
        return TrailerZoomCache(defaults: suite)
    }

    func entry(for key: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return values[key]
    }

    /// Kept for callers that only have a URL (and as the shape the pre-BUG-59 probe used).
    func zoom(for key: String) -> CGFloat? { entry(for: key)?.zoom }

    /// `verifyMisses` defaults to `nil` (a fresh cold-path measurement — no verify history yet);
    /// the VERIFY paths (`finish()`'s `verify-confirmed`/`verify-corrected` branches) pass `0`
    /// explicitly to reset a stream's miss count the moment it re-verifies cleanly.
    func store(_ zoom: CGFloat, for key: String, token: String, verifyMisses: Int? = nil) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        values[key] = Entry(zoom: Self.sanitized(zoom), token: token, at: Date().timeIntervalSince1970, verifyMisses: verifyMisses)
        if values.count > Self.capacity {
            let overflow = values.count - Self.capacity
            for (key, _) in values.sorted(by: { $0.value.at < $1.value.at }).prefix(overflow) {
                values[key] = nil
            }
        }
        persist()
    }

    /// Everything we remember, gone — the device pass's reset button (`defaults delete`-equivalent
    /// from inside the app) and what a future version bump does implicitly.
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll()
        loaded = true
        defaults.removeObject(forKey: Self.storageKey)
    }

    /// BUG-81 item 1: evicts one entry outright — the VERIFY path's `final-clamped` escape used to
    /// leave a bad cached crop untouched for up to `maxAge` (30 days); this is what lets it demand
    /// a fresh cold measurement on the next play instead. A no-op (still persists nothing) when the
    /// key isn't cached.
    func remove(for key: String) {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard values[key] != nil else { return }
        values[key] = nil
        persist()
    }

    /// BUG-81 item 2: the VERIFY path's `insufficient` outcome (too few/too-close samples to
    /// re-verify the cached crop) — three of these in a row on the same entry is a stream that
    /// simply can't re-verify, so it's evicted the same way `remove(for:)` evicts a clamped one.
    /// Returns the miss count AFTER this call (post-eviction, when it fires, so the log line still
    /// reads the count that triggered it). `0` when the key isn't cached — nothing to note a miss
    /// against.
    @discardableResult
    func noteVerifyMiss(for key: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        guard let existing = values[key] else { return 0 }
        let misses = (existing.verifyMisses ?? 0) + 1
        if misses >= 3 {
            values[key] = nil
        } else {
            values[key] = Entry(zoom: existing.zoom, token: existing.token, at: existing.at, verifyMisses: misses)
        }
        persist()
        return misses
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return values.count
    }

    /// Clamp into the only range a real measurement can produce; anything else is corruption.
    static func sanitized(_ zoom: CGFloat) -> CGFloat {
        guard zoom.isFinite else { return TrailerHeroPlayer.parityZoom }
        return min(max(zoom, 1.0), TrailerLetterboxProbe.maxZoom)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // C1 (2026-08-30 investigation): purge the pre-fix blob unconditionally, every launch that
        // still finds it — see `legacyStorageKey`'s doc comment for why it can never be trusted.
        if defaults.object(forKey: Self.legacyStorageKey) != nil {
            defaults.removeObject(forKey: Self.legacyStorageKey)
        }
        guard let data = defaults.data(forKey: Self.storageKey) else {
            TrailerZoomProbe.log("store loaded n=0 version=\(Self.version) (empty)")
            return
        }
        guard let blob = try? JSONDecoder().decode(Blob.self, from: data), blob.version == Self.version else {
            // Unknown/older shape: never trust it (see the type doc), start clean.
            defaults.removeObject(forKey: Self.storageKey)
            TrailerZoomProbe.log("store loaded n=0 version=\(Self.version) (dropped stale blob)")
            return
        }
        let cutoff = Date().timeIntervalSince1970 - Self.maxAge
        var kept: [String: Entry] = [:]
        for (key, entry) in blob.entries where entry.at >= cutoff && entry.zoom.isFinite {
            // `verifyMisses` carried over unchanged — this loop only sanitizes/expires the zoom
            // and drops stale rows, it must not silently reset a stream's miss count on every
            // cold load.
            kept[key] = Entry(zoom: Self.sanitized(entry.zoom), token: entry.token, at: entry.at, verifyMisses: entry.verifyMisses)
        }
        values = kept
        TrailerZoomProbe.log("store loaded n=\(kept.count) version=\(Self.version) (dropped \(blob.entries.count - kept.count) expired)")
    }

    private func persist() {
        let blob = Blob(version: Self.version, entries: values)
        if let data = try? JSONEncoder().encode(blob) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

/// UX-9: measures the letterbox/pillarbox bars **baked into the decoded frames** of a trailer and
/// turns them into the zoom its player layer needs to crop them away.
///
/// Why pixels, and not metadata: a 2.39:1 film letterboxed inside a 16:9 encode reports 1920x1080
/// through every channel we have (innertube's `adaptiveFormats[].width/height`, the `RESOLUTION=` we
/// synthesize from them in `TrailerLocalHLS`, `AVPlayerItem.presentationSize`) — the bars *are* the
/// picture as far as AVFoundation is concerned. A natively 2.39:1-*coded* stream, meanwhile, already
/// fills a 16:9 layer under `.resizeAspectFill` and needs no zoom at all. The two cases are
/// indistinguishable except in the decoded luma, which is why this exists at all.
///
/// One-shot per stream: five samples, a measurement, the output detached, timer gone. Everything
/// after that is a cache read.
///
/// BUG-59 (beta.13) — why it measures EARLIER and applies PARTIAL results now: the beta.12 probe
/// could not produce a number before ~2–3.5 s (first sample at 1.0 s, 0.5 s ticks, ≥3 samples) and
/// the inline focus tile is usually gone by then — `stop()` logged "abandoned … floor kept, not
/// cached" and the next visit started at 1.08 again, on ~90 % of titles by the reporter's count.
/// Now: the video output is attached eagerly, sampling starts at 0.25 s on 0.25 s ticks, an
/// INTERIM zoom is applied after the 2nd usable sample, and the FINAL zoom (the one that gets
/// remembered) still requires ≥3 samples spanning ≥1 s of item time. Safe because the min-across-
/// samples rule below can only make a bar *thinner* and dark-centred frames are never samples: a
/// fade-in can cost a false negative (bar=0 → floor) but never an over-zoom.
///
/// BUG-59 (reveal gate) — the probe also owns WHEN the video becomes visible. Early-and-interim
/// still left a structural window: on the first-ever play of a title the surface was revealed at
/// the 1.08 floor and only zoomed ~0.5–1.5 s later, so a letterboxed trailer *showed its bars,
/// then cropped them* — once per title, i.e. on nearly every fresh dwell of a browsing session,
/// which is what the reporter keeps filming. The invariant is now structural: **an unzoomed
/// letterboxed frame can never reach the screen**, because a surface with no persisted entry for
/// its title starts at `alpha = 0` (the static art / backdrop behind it stays up) and is revealed
/// only when its crop is decided — persisted hit (immediately, match or mismatch), the interim or
/// final measurement, or a cap of ~3 s of DELIVERED frames that produced no usable sample (a dark
/// opening or a long fade — dark frames have no bars to hide). The cap counts frames, never wall
/// clock: playback startup routinely exceeds 3 s, and a wall-clock cap would reveal before the
/// first frame, whose bars would then sit unzoomed until the interim (Codex, Wave 13 round 2). A
/// stream that never delivers a frame stays concealed until the 6 s startup watchdog removes the
/// surface. Every reveal logs `[TrailerZoom] reveal reason=…` so the soak's log oracle can assert
/// the ordering.
final class TrailerLetterboxProbe {
    /// Ceiling on the measured zoom. DERIVED, not tuned: the widest format anyone bakes into a 16:9
    /// container is ~2.55:1, and 2.55 / (16/9) = 1.435. (The 2.39:1 scope trailers UX-9 was filed
    /// over land at 1.344.) Anything past this is a measurement gone wrong, not a real bar.
    static let maxZoom: CGFloat = 1.45
    /// Every trailer surface is 16:9: the inline tile by construction (UX-4a sizes it
    /// `posterHeight * 16/9`), the Detail hero and full-screen surfaces because they are the screen.
    private static let cardAspect: Double = 16.0 / 9.0

    private static let sampleTarget = 5
    /// BUG-59: sample from the first quarter second (was 1.0 s — see the type doc). Black opening
    /// frames are rejected as samples anyway, so starting early costs nothing.
    private static let firstSampleSeconds: Double = 0.25
    private static let tickInterval: TimeInterval = 0.25
    /// Give up after this many ticks (12s) if playback never delivers enough frames — the surface
    /// keeps whatever it has (interim, else the `parityZoom` floor), and nothing is cached, so a
    /// later play measures again.
    private static let maxTicks = 48
    /// BUG-59: apply an interim zoom after this many usable samples; keep sampling for the final.
    private static let interimSampleCount = 2
    /// The final (persisted) measurement needs at least this many samples…
    private static let finalMinSamples = 3
    /// …spanning at least this much item time, so two adjacent frames of one shot can never be
    /// remembered as the answer for the whole trailer. 0.95 rather than 1.0: four 0.25 s ticks
    /// legitimately span "1.0 s" of item time that reads 0.9999 (sim run 2026-08-18: five
    /// samples, `span=1.00s`, refused).
    private static let finalMinSpanSeconds: Double = 0.95
    /// Mean 8-bit luma at or below this reads as a black bar. Well above sensor/encoder noise on a
    /// true black bar, well below any real picture content. Internal (not private) so
    /// `ArtworkLetterbox` scans static key art with the exact same thresholds — one definition of
    /// "black bar" for the whole trailer tile.
    static let blackLuma: Double = 16
    /// No plausible baked bar eats more than a quarter of the frame per edge (the 2.55:1 worst case
    /// is ~15%), so the scan stops there rather than walking into the picture on a dark shot.
    static let maxBarFraction: Double = 0.25
    /// Bars thinner than this are encoder rounding, not letterboxing.
    static let minBarFraction: Double = 0.01
    /// BUG-59 (reveal gate): a concealed surface is force-revealed after this many FRAME-BEARING
    /// ticks (≈3 s of delivered video) with no measurement — content whose decoded frames keep
    /// getting rejected as samples is dark (a black opening, a long fade), and dark frames have no
    /// bars to hide. Deliberately counts ticks that produced a pixel buffer, NEVER wall-clock
    /// ticks (Codex, Wave 13 round 2): playback startup routinely exceeds 3 s (the loopback repack
    /// alone is 2–3 s on the sim), and a wall-clock cap would reveal *before the first frame* —
    /// whose bars would then sit unzoomed until the interim, recreating the exact defect this
    /// gate exists to prevent. A stream that never delivers frames at all stays concealed until
    /// the coordinator's 6 s startup watchdog fails it and the surface is removed.
    private static let revealCapFrameTicks = 12

    /// Bar thickness per edge, as a fraction of the frame.
    private struct Bars {
        let top: Double
        let bottom: Double
        let left: Double
        let right: Double
    }

    private weak var view: TrailerPlayerUIView?
    private weak var player: AVPlayer?
    private let urlString: String
    /// BUG-59: what the measurement is remembered under (the title key, else the URL).
    private let zoomKey: String
    /// Stream identity stored with the measurement so a persisted entry knows whether it was
    /// measured on THIS stream: the YouTube video id when one is known (BUG-81), else the
    /// `TrailerLocalHLS` repack token for loopback URLs, else a stable digest of a direct URL
    /// (`streamIdentity(of:videoId:)`). Never nil, so two different direct streams of one title
    /// (hero trailer vs a Trailers & Extras pick) can't read as "a match".
    private let token: String
    /// `hero` (inline card + Detail hero) or `full` — log disambiguation only.
    private let surface: String

    private var output: AVPlayerItemVideoOutput?
    private weak var sampledItem: AVPlayerItem?
    private var timer: Timer?
    private var ticks = 0
    /// Ticks that actually copied a decoded frame (sample-worthy or not) — the reveal cap's clock.
    private var frameTicks = 0
    private var samples: [Bars] = []
    /// Item time (seconds) of each entry in `samples`, for the final-measurement span guard.
    private var sampleTimes: [Double] = []
    private var frameSize: CGSize = .zero
    /// One measurement per probe: `tick()` can reach the sample target and the tick ceiling in the
    /// same pass, and a second `finish()` would re-log and re-animate an identical zoom.
    private var finished = false
    /// BUG-59: whatever early zoom THIS stream's own samples have produced ahead of the final
    /// measurement. Log/teardown state only — never seeded from a persisted entry, even a
    /// different-stream one (see the token-mismatch handling in `start()`): a value this field
    /// didn't measure itself would misreport what's actually on screen if the probe aborts.
    private var interimZoom: CGFloat?
    /// BUG-59: true once THIS stream's own samples produced an interim.
    private var interimMeasured = false
    /// BUG-59 (reveal gate): whether the surface is visible. Starts true and stays true on every
    /// persisted-hit path (the zoom is already right, or near enough); flips false only when
    /// `start()` conceals a cold surface, and back only through `reveal(reason:)`.
    private var revealed = true
    /// C1 (2026-08-30 investigation): true for the remainder of this probe's lifetime once `start()`
    /// took the token-MATCH branch. A token match still applies the cached zoom immediately and
    /// un-concealed (unchanged UX for a good entry — `revealed` never flips false on this path), but
    /// the probe now arms behind it instead of trusting the entry forever. Sampling and `finish()`
    /// run exactly as on the cold path EXCEPT: `applyInterim()` never fires (an interim correction
    /// mid-playback would look like drifting zoom for a surface that's already showing something
    /// reasonable — only `finish()`'s final verdict may adjust it), and `finish()` compares its
    /// result against `verifyAppliedZoom` instead of unconditionally persisting+applying.
    private var verifyMode = false
    /// The cached zoom `start()` applied on the token-match branch — `finish()`'s verify-mode
    /// comparison baseline. Set once, alongside `verifyMode = true`, never touched by sampling.
    private var verifyAppliedZoom: CGFloat?
    /// BUG-94: whether `finish()` may write `TrailerZoomCache`, decided once in `start()` from
    /// `TrailerSurfaceZoomPolicy.Decision.persist`. Defaults `true` (today's hero/inline behavior)
    /// so a probe that somehow reached `finish()` without ever calling `start()` fails open rather
    /// than silently going mute. Belt-and-braces on the full surface: its `measure == false` early
    /// return in `start()` never reaches `finish()`/any `store()` call site at all, so this guard
    /// is a second, independent reason the full surface can never write the cache, not the only one.
    private var persistAllowed = true

    init(view: TrailerPlayerUIView, player: AVPlayer, urlString: String, zoomKey: String? = nil,
         videoId: String? = nil, surface: String) {
        self.view = view
        self.player = player
        self.urlString = urlString
        self.zoomKey = zoomKey ?? urlString
        self.token = Self.streamIdentity(of: urlString, videoId: videoId)
        self.surface = surface
    }

    /// Content identity for a loopback repack URL when the local server still knows it; else its
    /// raw repack token. For a direct progressive/HLS URL, the `id` query item alone, else the
    /// whole URL.
    ///
    /// BUG-81 item 3 (Wave F design correction ii): this used to key a direct URL on
    /// `host+path+id+itag`, and googlevideo rotates the CDN HOST per extraction (see
    /// `TrailerLocalHLS.stableIdentity(_:)`'s own doc comment — the repack token already learned
    /// this lesson and drops the host) — so on a device that plays direct URLs (no loopback repack
    /// in the path), every single play read as a brand-new stream identity, the VERIFY branch in
    /// `start()` could never trigger (token never matched), and every play cold-re-measured at the
    /// `parityZoom` floor. `itag` is dropped too: it names a format-ladder rung the extractor can
    /// legitimately pick differently between requests for the exact same video, and the crop a
    /// given video needs doesn't depend on which rung serves it.
    ///
    /// BUG-81 investigation follow-up: the fix above never reached the REPACK path, which is what
    /// most YouTube trailers actually use. `TrailerLocalHLS`'s own `token(video:audio:)` hash is
    /// itag-sensitive by design (it exists to dedupe/evict playlists, not to describe a picture),
    /// so the extractor legitimately choosing a different AVC rung on every extraction meant every
    /// relaunch read `token=mismatch` in the `persisted-hit` log, VERIFY mode never armed, and a
    /// persisted zoom was never confirmed or corrected — a plausible mechanism for zoom that looks
    /// "stuck" across sessions. `TrailerLocalHLS.contentIdentity(forToken:)` strips the itag (and
    /// the byte-range/expiry plumbing) the same way this function already strips it for direct
    /// URLs; when the local server can't resolve the token (evicted, or a different process/run
    /// than the one that minted it) this falls back to the literal token, same as before.
    /// BUG-81 round three, the actual fix: prefer the YOUTUBE VIDEO ID over anything derived from
    /// the playback URL. The sim soak that closed out round two (2026-09-04, one video pinned with
    /// `-debug.trailerSmokeVideoId`, extracted three times) showed the googlevideo `id=` query item
    /// both branches below key on is a per-request token minted by the CDN — three extractions of
    /// ONE video produced `o-AJbEeBZ…`, `o-AMk-fCj…`, `o-APyRTSG…`, sharing not even a prefix. So
    /// `direct:id=` and `repack:<contentIdentity>` alike still read as a brand-new stream on every
    /// play, `persisted-hit … token=mismatch` fired on every relaunch, VERIFY mode never armed, and
    /// a persisted zoom was never confirmed OR corrected — which is the "zoom stuck across
    /// sessions" shape the tester reports.
    ///
    /// The video id has none of that: the shared Kotlin extractor parses it out of the trailer's
    /// own YouTube URL before it makes a single request (`TrailerPlaybackSource.videoId`, logged as
    /// `[TrailerExtract] video=…`), so it is identical on every extraction, on both transports, and
    /// across launches and app versions. `videoId` is the caller's own copy when a surface still
    /// holds the source; `TrailerVideoIdRegistry` covers the surfaces that replay a memoized URL.
    ///
    /// The URL-derived branches stay as the fallback for a stream with no video id: a non-YouTube
    /// source, or a registry entry evicted mid-session.
    static func streamIdentity(of urlString: String, videoId: String? = nil) -> String {
        // An empty string is not an id — normalize it away before the registry fallback, or a
        // caller that passed `""` would skip the registry AND the `yt:` branch both.
        let explicit = (videoId?.isEmpty == false) ? videoId : nil
        if let id = explicit ?? TrailerVideoIdRegistry.videoId(forPlaybackURL: urlString) {
            return "yt:\(id)"
        }
        if let token = TrailerLocalHLS.token(inPlaybackURL: urlString) {
            if let identity = TrailerLocalHLS.contentIdentity(forToken: token) {
                return "repack:\(identity)"
            }
            return "repack:\(token)"
        }
        guard let comps = URLComponents(string: urlString),
              let id = (comps.queryItems ?? []).first(where: { $0.name == "id" })?.value,
              !id.isEmpty else {
            return "url:\(urlString)"
        }
        return "direct:id=\(id)"
    }

    /// Applies the starting zoom and decides whether to measure. Main-thread only.
    ///
    /// * Persisted entry whose token matches this stream (or a direct URL with no token on either
    ///   side) → apply as final, no probe.
    /// * Persisted entry measured on a DIFFERENT stream of the same title (BUG-59 collision fix,
    ///   2026-08-28: `zoomKey` is title-keyed, so this is the hero trailer's cache entry read by
    ///   a Trailers & Extras clip, or vice versa) → treat exactly like no entry at all: parity
    ///   floor, concealed, re-measure from scratch. The old crop is not this stream's crop.
    /// * Nothing → parity floor, measure.
    func start() {
        logAttach()
        // BUG-94: the policy is decided from `cached: nil` — `TrailerSurfaceZoomPolicy.decide`'s
        // answer never actually depends on the cache's contents (see that type's doc: the full
        // branch is unconditional and the hero/inline branch doesn't inspect `cached` either) — so
        // this runs BEFORE any `TrailerZoomCache` read at all. That is what lets the full surface
        // avoid the cache entirely: it never even takes the read lock, not merely the write.
        let policy = TrailerSurfaceZoomPolicy.decide(surface: surface, cached: nil)
        persistAllowed = policy.persist
        guard policy.measure else {
            // BUG-94: the full surface never measures. It never conceals either — 1.0 is honest
            // from the very first frame, so there is nothing to hide while a measurement is
            // pending — which is why `revealed`/`view.alpha` are set directly here rather than
            // through `reveal(reason:)`: that helper's own `guard !revealed else { return }` would
            // silently swallow the very case this branch exists to make certain of if some future
            // caller ever left this surface concealed before calling `start()`. `persistAllowed`
            // was already latched to `false` above; this path also never reaches `armSamplingTimer()`
            // or `attachOutputIfNeeded()`, so `TrailerZoomCache` is never touched again either.
            revealed = true
            view?.alpha = 1
            apply(policy.zoom, animated: false)
            TrailerZoomProbe.log(String(format: "policy=uncropped surface=%@ zoom=%.3f key=%@", surface, policy.zoom, zoomKey))
            return
        }
        // Hero/inline only, from here on — the ONLY `TrailerZoomCache` read `start()` ever makes.
        if let cached = TrailerZoomCache.shared.entry(for: zoomKey) {
            // A blob entry with no token (never written by this build, but decodable) never matches.
            let tokenMatches = cached.token == token
            TrailerZoomProbe.log(String(
                format: "persisted-hit key=%@ zoom=%.3f token=%@ cached=%@ this=%@ surface=%@ cardFrame=%@",
                zoomKey, cached.zoom, tokenMatches ? "match" : "mismatch",
                Self.logToken(cached.token ?? "-"), Self.logToken(token), surface, cardFrameDescription()
            ))
            if tokenMatches {
                // Only a token MATCH may show the cached crop un-concealed: this exact stream is
                // what measured it, so it's known-good.
                apply(cached.zoom, animated: false)
                // C1 (2026-08-30 investigation): no longer a `return` here. A token match used to
                // apply-and-trust forever — but `repack:<token>` is content-stable across app
                // releases, so a bad entry measured under a build with a measurement bug (not just
                // a stale/mismatched token) would silently reapply for up to `maxAge` (30 days),
                // which is exactly what betas ≤16 hit. Arm the probe in VERIFY mode instead: the
                // applied crop stays on screen exactly as before (no conceal, no re-animation) while
                // `finish()` quietly checks it against a fresh measurement.
                verifyMode = true
                verifyAppliedZoom = cached.zoom
                attachOutputIfNeeded()
                armSamplingTimer()
                return
            }
            // BUG-59 collision (tester report, 2026-08-28): `zoomKey` is keyed by TITLE, not by
            // stream — every video on a Detail page (the hero trailer AND every Trailers & Extras
            // clip) shares one `TrailerZoomCache` entry. This branch used to apply the cached zoom
            // to the live layer UNCONDITIONALLY, before the token check below it even ran, and on
            // a mismatch left that wrong crop on screen (seeded into `interimZoom`, never
            // concealed) instead of re-measuring. Net effect: opening a 16:9 Behind-the-Scenes
            // clip right after the hero trailer inherited the hero's persisted 2.39:1 crop and
            // started visibly zoomed (~1.34) from the first frame, all the way until the probe's
            // interim landed 0.5–12s later. A token mismatch means THIS stream was never measured
            // — that's a cold start in every sense, so fall through to the exact same parity-floor
            // + conceal path as "no entry at all" below. Do NOT seed `interimZoom` with the stale
            // cached zoom: nothing of the old measurement is trustworthy for this stream, and
            // `interimZoom` exists purely to log what's actually on screen if the probe aborts —
            // seeding it with a value that was never applied here would make that log lie.
        }
        // Parity floor first, un-animated: until the measurement lands, every surface renders
        // exactly what it rendered before UX-9 — but CONCEALED now (reveal gate): with no
        // memory of this title (or, per the collision fix above, no memory of THIS stream), the
        // floor would show a letterboxed source's bars for the ~0.5–1.5 s until the interim lands,
        // once per title, on nearly every fresh dwell. The static art / backdrop behind the
        // surface stays up instead.
        apply(TrailerHeroPlayer.parityZoom, animated: false)
        conceal()
        // BUG-59: attach the output NOW rather than on the first tick, so the very first tick can
        // already read a frame (the item exists before `play()` on both surfaces).
        attachOutputIfNeeded()
        armSamplingTimer()
    }

    /// BUG-81 item 4/Trailer Diagnostics: one line per attach, before anything else runs, so a
    /// device photo has the full context (which surface, which title, the metadata language a
    /// French tester's device carries, and which identity branch `streamIdentity(of:)` produced)
    /// even if the probe never reaches a verdict.
    private func logAttach() {
        let (src, tok) = Self.sourceAndTokenPrefix(token)
        let lang = TmdbSettingsRepository.shared.snapshot().language
        TrailerZoomProbe.log(String(format: "attach surface=%@ clip=%@ lang=%@ src=%@ tok=%@", surface, zoomKey, lang, src, tok))
    }

    /// `src`/`tok` for the `attach` log line — `token` is one of `yt:<videoId>`, `repack:<hex>`,
    /// `direct:id=<id>`, or `url:<full url>` (`streamIdentity(of:videoId:)`); this reads the source
    /// kind off the prefix. `yt:` says the identity is the stable YouTube video id and reports the
    /// prefix in `tok` too, since that is the one distinction worth reading at a glance. `url:` (no
    /// `id` query item present) reads as `direct` — still a non-repack stream, just one
    /// `streamIdentity` couldn't shorten.
    private static func sourceAndTokenPrefix(_ identity: String) -> (src: String, tok: String) {
        if identity.hasPrefix("yt:") {
            return ("yt", logToken(identity))
        }
        if identity.hasPrefix("repack:") {
            return ("repack", tokenPrefix(String(identity.dropFirst("repack:".count))))
        }
        if identity.hasPrefix("direct:") {
            return ("direct", tokenPrefix(String(identity.dropFirst("direct:".count))))
        }
        if identity.hasPrefix("url:") {
            return ("direct", tokenPrefix(String(identity.dropFirst("url:".count))))
        }
        return ("direct", tokenPrefix(identity))
    }

    /// Short form of a stream identity for the `attach` and `persisted-hit` lines. A video-id
    /// identity KEEPS its `yt:` prefix (BUG-81 round three): a log reader has to be able to tell at
    /// a glance whether a `token=mismatch` was compared on the stable video id or on one of the
    /// URL-derived fallbacks, and the two answers mean very different things.
    private static func logToken(_ identity: String) -> String {
        if identity.hasPrefix("yt:") {
            return "yt:\(tokenPrefix(String(identity.dropFirst("yt:".count))))"
        }
        for prefix in ["repack:", "direct:", "url:"] where identity.hasPrefix(prefix) {
            return tokenPrefix(String(identity.dropFirst(prefix.count)))
        }
        return tokenPrefix(identity)
    }

    private static func tokenPrefix(_ value: String) -> String { String(value.prefix(8)) }

    /// Starts the 0.25s-tick sampling timer. Shared by the cold (no/mismatched entry) and VERIFY
    /// (C1, token-match) paths — sampling and `tick()` behave identically either way; only what
    /// `applyInterim()`/`finish()` do with the result differs (`verifyMode` gates both).
    private func armSamplingTimer() {
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Idempotent: stops sampling and detaches the video output. Called from every teardown path.
    func stop() {
        // UX-9 (beta.12, Codex gate 4-5): a probe torn down BEFORE it gathered enough samples
        // (focus left, surface dismantled) used to vanish silently — the fast-scrub soak's
        // many-pipeline-lines-zero-zoom-lines exactly. `timer != nil` keeps cache-hit surfaces
        // (probe never armed) quiet; `finished` is already true when `finish()` reaches here,
        // so a completed measurement never double-logs.
        if timer != nil, !finished {
            finished = true
            TrailerZoomProbe.log(String(
                format: "abandoned samples=%d ticks=%d interimApplied=%d revealed=%d verify=%d surface=%@ key=%@ — %@ kept, not cached",
                samples.count, ticks, interimZoom == nil ? 0 : 1, revealed ? 1 : 0, verifyMode ? 1 : 0,
                surface, zoomKey, keptDescription()
            ))
        }
        timer?.invalidate()
        timer = nil
        detachOutput()
    }

    /// C1 (2026-08-30 investigation): what's actually on screen if the probe never reaches a verdict
    /// — used by both the `abandoned` (stop-before-finish) and `insufficient` (finish-but-no-usable-
    /// samples) log lines so they can't disagree. Verify mode never touched `interimZoom` (it can't —
    /// `applyInterim()` is skipped in that mode), so it needs its own branch rather than falling into
    /// the floor/interim wording, which would misreport the cached crop as the parity floor.
    private func keptDescription() -> String {
        if verifyMode { return "verified-cached" }
        return interimZoom == nil ? "floor" : "interim"
    }

    // MARK: Sampling

    /// Re-attach on item changes rather than capturing one item: with `loops == true` the
    /// AVPlayerLooper plays *copies* of the template, so the item we were handed at attach
    /// never produces a frame (same trap the `[TrailerQuality]` probe documents).
    private func attachOutputIfNeeded() {
        guard let player, let item = player.currentItem else { return }
        guard sampledItem !== item else { return }
        detachOutput()
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
        self.output = output
        sampledItem = item
        samples.removeAll()
        sampleTimes.removeAll()
    }

    private func tick() {
        ticks += 1
        defer { if ticks >= Self.maxTicks { finish() } }
        attachOutputIfNeeded()
        guard let player, let item = player.currentItem, let output else { return }

        let time = item.currentTime()
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite, seconds >= Self.firstSampleSeconds else { return }
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }

        // Reveal cap: a decoded frame is on screen. After ~3 s of DELIVERED frames that still
        // produced no measurement, the content is dark/unsamplable — show it (dark frames carry
        // no bars; if bright barred frames follow, the interim lands within ~2 ticks of the first
        // usable sample, same as any fade-in did before the gate existed). Counted here, past the
        // pixel-buffer guard, so pre-roll/buffering never advances the cap (see
        // `revealCapFrameTicks`).
        frameTicks += 1
        if !revealed, frameTicks >= Self.revealCapFrameTicks { reveal(reason: "cap") }

        frameSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if let bars = Self.bars(in: buffer) {
            samples.append(bars)
            sampleTimes.append(seconds)
        }
        // C1 (2026-08-30 investigation): interim corrections never fire in VERIFY mode — the surface
        // is already showing the cached crop, and a mid-playback interim nudge would look like
        // drifting zoom rather than a deliberate correction. Only `finish()`'s final verdict may
        // adjust a verified stream.
        if samples.count >= Self.interimSampleCount, !interimMeasured, !verifyMode {
            applyInterim()
        }
        if samples.count >= Self.sampleTarget { finish() }
    }

    /// BUG-59: the zoom the samples so far imply, applied without being remembered. Skipped (and
    /// retried on the next sample) when the measurement is CLAMPED at `maxZoom`: two early frames
    /// of a fade-in read as huge bars, and the sim run that shipped this showed exactly that —
    /// `interim applied=1.450` settling to `final … 1.343`, a visible bounce. A capped reading is a
    /// fade signature, not a bar; the min-across-samples final will discard it anyway.
    private func applyInterim() {
        guard let result = Self.measure(samples), frameSize.width > 0 else { return }
        guard CGFloat(result.measured) < Self.maxZoom else { return }
        let zoom = result.zoom
        interimMeasured = true
        interimZoom = zoom
        apply(zoom, animated: true)
        let span = (sampleTimes.last ?? 0) - (sampleTimes.first ?? 0)
        TrailerZoomProbe.log(String(format: "interim samples=%d span=%.2fs applied=%.3f surface=%@ key=%@",
                                     samples.count, span, zoom, surface, zoomKey))
        // Reveal gate: the crop is decided (for now) — this is the earliest a cold surface may
        // appear, and it appears already zoomed. Logged after the interim line so the soak's
        // ordering oracle (`reveal` never precedes a measurement on the cold path) reads cleanly.
        reveal(reason: "interim")
    }

    /// The zoom a set of samples implies (nil when it implies nothing usable), plus the measured
    /// pre-clamp value for the log. Shared by the interim and final paths so they can never
    /// disagree about the formula.
    private static func measure(_ collected: [Bars]) -> (zoom: CGFloat, measured: Double)? {
        guard !collected.isEmpty else { return nil }
        // A bar counts only if it is present in EVERY sample — hence `min`, not an average. A single
        // frame can be letterboxed by its own content (a black-bordered shot, a fade), and averaging
        // would let that fake a permanent bar.
        func edge(_ keyPath: KeyPath<Bars, Double>) -> Double {
            let value = collected.map { $0[keyPath: keyPath] }.min() ?? 0
            return value >= minBarFraction ? value : 0
        }
        let top = edge(\.top), bottom = edge(\.bottom), left = edge(\.left), right = edge(\.right)
        let verticalContent = 1 - top - bottom
        let horizontalContent = 1 - left - right
        guard verticalContent > 0, horizontalContent > 0 else { return nil }
        // The zoom derives from the DETECTED BARS alone — never from the coded frame's aspect.
        // `.resizeAspectFill` already crops away any *native* aspect mismatch (a barless 1920×800
        // stream fills the card with zero help), so an aspect-ratio formula would over-crop
        // exactly those streams by up to ~35% (Codex round 3). Letterbox → 1/(1-top-bottom);
        // pillarbox → 1/(1-left-right); barless → 1.0 and the parity floor applies.
        let measured = max(1 / verticalContent, 1 / horizontalContent)
        let zoom = min(max(CGFloat(measured), TrailerHeroPlayer.parityZoom), maxZoom)
        return (zoom, measured)
    }

    /// Deliberately NOT requesting a downscaled (e.g. 160x90) output buffer: `AVPlayerItemVideoOutput`
    /// would fit the frame into whatever box we ask for, which for a natively-2.39:1 stream means
    /// *it* adds the very bars we are trying to detect. Native-size buffers with a sparse scan cost
    /// a few thousand byte reads per sample and are the only reading that can't lie.
    private static func bars(in buffer: CVPixelBuffer) -> Bars? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 32, height > 32, bytesPerRow >= width * 4 else { return nil }
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // BGRA, Rec.709 luma coefficients.
        func luma(_ x: Int, _ y: Int) -> Double {
            let p = pixels + y * bytesPerRow + x * 4
            return 0.0722 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.2126 * Double(p[2])
        }
        func isBlackRow(_ y: Int) -> Bool {
            let step = max(1, width / 32)
            var sum = 0.0
            var count = 0
            var x = step / 2
            while x < width { sum += luma(x, y); count += 1; x += step }
            return count > 0 && sum / Double(count) <= Self.blackLuma
        }
        func isBlackColumn(_ x: Int) -> Bool {
            let step = max(1, height / 32)
            var sum = 0.0
            var count = 0
            var y = step / 2
            while y < height { sum += luma(x, y); count += 1; y += step }
            return count > 0 && sum / Double(count) <= Self.blackLuma
        }

        // A frame that is black through its own middle is a fade or a cut to black, not a
        // letterboxed picture — it can't tell us anything, so it isn't a sample.
        guard !isBlackRow(height / 2), !isBlackColumn(width / 2) else { return nil }

        let rowLimit = Int(Double(height) * Self.maxBarFraction)
        let columnLimit = Int(Double(width) * Self.maxBarFraction)
        var top = 0
        while top < rowLimit, isBlackRow(top) { top += 1 }
        var bottom = 0
        while bottom < rowLimit, isBlackRow(height - 1 - bottom) { bottom += 1 }
        var left = 0
        while left < columnLimit, isBlackColumn(left) { left += 1 }
        var right = 0
        while right < columnLimit, isBlackColumn(width - 1 - right) { right += 1 }

        return Bars(
            top: Double(top) / Double(height),
            bottom: Double(bottom) / Double(height),
            left: Double(left) / Double(width),
            right: Double(right) / Double(width)
        )
    }

    // MARK: Measurement

    private func finish() {
        guard !finished else { return }
        finished = true
        let collected = samples
        let times = sampleTimes
        let size = frameSize
        let span = (times.last ?? 0) - (times.first ?? 0)
        stop()
        // Too few samples, or samples too close together, is a stream that stalled, stayed dark, or
        // was left too early: keep what is on screen (interim, else floor) and cache nothing, so the
        // next play of this title measures again.
        guard collected.count >= Self.finalMinSamples, span >= Self.finalMinSpanSeconds,
              size.width > 0, size.height > 0 else {
            // UX-9 (beta.12): this bail used to be SILENT even with the probe armed — a beta.12
            // soak produced 154 [TrailerPipeline] lines and zero [TrailerZoom] lines, with no way
            // to tell whether the measurement never ran or kept failing. A letterboxed source
            // whose measurement can't complete stays at the 1.08 floor (the reporter's Lucky
            // case), so the WHY has to be readable off a log pull.
            //
            // BUG-81 item 2: in VERIFY mode this IS a failed re-verify — note the miss (evicts at
            // 3 in a row, so a stream that structurally can never re-verify — always too short, or
            // stalls before the span floor — doesn't hold a possibly-bad crop for the full 30-day
            // cache lifetime). Cold-path misses aren't counted: there's no cache entry yet to note
            // one against.
            var verifyMisses = 0
            if verifyMode {
                verifyMisses = TrailerZoomCache.shared.noteVerifyMiss(for: zoomKey)
            }
            TrailerZoomProbe.log(String(
                format: "insufficient samples=%d span=%.2fs frame=%dx%d ticks=%d interimApplied=%d verify=%d verifyMisses=%d surface=%@ key=%@ — %@ kept, not cached",
                collected.count, span, Int(size.width), Int(size.height), ticks,
                interimZoom == nil ? 0 : 1, verifyMode ? 1 : 0, verifyMisses, surface, zoomKey, keptDescription()
            ))
            // Reveal gate: normally long since revealed (the 3 s cap fires at tick 12, this bail
            // at tick 48) — belt-and-braces so no path can end a live playback still concealed.
            // No-op in verify mode (already revealed at `start()`; nothing to compare, so the
            // cached entry is left exactly as it was — untouched, un-refreshed — and the next play
            // verifies again).
            reveal(reason: "insufficient")
            return
        }

        guard let result = Self.measure(collected) else {
            reveal(reason: "unmeasurable")
            return
        }
        let zoom = result.zoom
        let measured = result.measured

        // C2 (2026-08-30 investigation): mirrors `applyInterim()`'s clamp rationale — a FINAL
        // measurement that still hits the ceiling is the same fade/opaque-overlay signature (a
        // logo or title card, not real bars), not a trustworthy answer, and unlike the interim path
        // there is no next sample to retry with. Reveal (belt-and-braces on the cold path; a no-op
        // in verify mode, already revealed) but never persist or apply it — on the cold path that
        // means leaving whatever is already on screen (interim, else the parity floor); in verify
        // mode it means leaving the cached entry completely alone, including its timestamp, so an
        // entry this stream genuinely can't re-verify neither gets stomped by a bogus reading nor
        // silently ages out early.
        //
        // BUG-81 item 1: a clamped FINAL in verify mode means this play could not re-verify the
        // cached crop at all (the fresh measurement is unusable, not just different) — evict the
        // entry instead of leaving a possibly-bad crop cached for up to 30 more days. This play's
        // on-screen crop (the cached one, applied un-concealed back in `start()`) is untouched;
        // the NEXT play of this title starts cold and measures from scratch.
        guard CGFloat(measured) < Self.maxZoom else {
            var evicted = 0
            if verifyMode {
                TrailerZoomCache.shared.remove(for: zoomKey)
                evicted = 1
            }
            TrailerZoomProbe.log(String(format: "final-clamped key=%@ measured=%.3f verify=%d evicted=%d surface=%@",
                                         zoomKey, measured, verifyMode ? 1 : 0, evicted, surface))
            reveal(reason: "clamped")
            return
        }

        if verifyMode {
            // C1 (2026-08-30 investigation): the applied-and-trusted-forever behavior this fix
            // replaces. `verifyAppliedZoom` is always set on this path (see `start()`); the `?? zoom`
            // fallback only guards a theoretical future call ordering and, if it ever hit, would
            // correctly read as "nothing to correct."
            let appliedZoom = verifyAppliedZoom ?? zoom
            if abs(zoom - appliedZoom) > 0.02 {
                // `verifyMisses: 0` — a stream that just re-verified (however the comparison came
                // out) starts its miss count clean; misses only ever come from `insufficient`.
                // BUG-94: `persistAllowed` guards every `store()` call — see its doc comment. This
                // branch is unreachable on the full surface today (verify mode is never armed
                // there), but the guard is here anyway rather than trusted to that structural fact.
                if persistAllowed {
                    TrailerZoomCache.shared.store(zoom, for: zoomKey, token: token, verifyMisses: 0)
                }
                apply(zoom, animated: true)
                TrailerZoomProbe.log(String(format: "verify-corrected key=%@ old=%.3f new=%.3f surface=%@",
                                             zoomKey, appliedZoom, zoom, surface))
            } else {
                // Confirmed good: re-store the SAME zoom purely to refresh `Entry.at`, so a title
                // that's still being watched correctly never ages out of the 30-day cache just
                // because its crop hasn't needed to change. Nothing on screen moves.
                if persistAllowed {
                    TrailerZoomCache.shared.store(appliedZoom, for: zoomKey, token: token, verifyMisses: 0)
                }
                TrailerZoomProbe.log(String(format: "verify-confirmed key=%@ zoom=%.3f surface=%@", zoomKey, appliedZoom, surface))
            }
            reveal(reason: "final") // No-op: verify mode is revealed from `start()` onward.
            return
        }

        let bars = collected.reduce(Bars(top: 1, bottom: 1, left: 1, right: 1)) { acc, next in
            Bars(top: min(acc.top, next.top), bottom: min(acc.bottom, next.bottom),
                 left: min(acc.left, next.left), right: min(acc.right, next.right))
        }

        // BUG-94: guarded like the two verify-mode `store()` calls above — unreachable on the full
        // surface today (it never gets this far), guarded anyway rather than trusted to that fact.
        if persistAllowed {
            TrailerZoomCache.shared.store(zoom, for: zoomKey, token: token)
        }
        apply(zoom, animated: true)
        reveal(reason: "final")

        TrailerZoomProbe.log(String(
            format: "final frame=%dx%d bars top=%.3f bottom=%.3f left=%.3f right=%.3f samples=%d span=%.2fs measured=%.3f applied=%.3f persisted=1 surface=%@ key=%@ cardFrame=%@",
            Int(size.width), Int(size.height), bars.top, bars.bottom, bars.left, bars.right, collected.count,
            span, measured, zoom, surface, zoomKey, cardFrameDescription()
        ))
    }

    // MARK: Applying

    /// Render-only, by construction: the zoom lives on the player SUBLAYER's transform (see
    /// `TrailerPlayerUIView` — never the SwiftUI-owned backing layer, whose transform every
    /// layout pass re-asserts, which is how beta.12 logged `applied=1.343` while rendering the
    /// bars anyway) and touches no layout, which is what makes it safe for UX-4a's morph
    /// geometry and BUG-29's expansion scroll.
    private func apply(_ zoom: CGFloat, animated: Bool) {
        view?.setCropZoom(zoom, animated: animated)
    }

    /// Reveal gate: hide the surface until its crop is decided. `view.alpha`, not a layer opacity
    /// animation of our own, so it composes multiplicatively with whatever opacity the hosting
    /// SwiftUI transition (`.opacity` insertion on both the inline tile and the Detail hero) is
    /// running — and, like `apply(_:animated:)`, it is render-only: no layout is touched, so
    /// UX-4a's morph geometry and BUG-29's expansion scroll stay intact. Main-thread only (called
    /// from `start()`/the tick timer, both main).
    private func conceal() {
        guard let view else { return }
        revealed = false
        view.alpha = 0
    }

    /// Idempotent flip back to visible, fading over the static art behind the surface. Every call
    /// site names WHY (`persisted` paths never conceal, so the reasons are: `interim`, `final`,
    /// `cap`, `insufficient`, `unmeasurable`) — the log line is the soak's ordering oracle.
    private func reveal(reason: String) {
        guard !revealed else { return }
        revealed = true
        TrailerZoomProbe.log(String(format: "reveal reason=%@ ticks=%d frameTicks=%d surface=%@ key=%@", reason, ticks, frameTicks, surface, zoomKey))
        guard let view else { return }
        UIView.animate(withDuration: 0.25) { view.alpha = 1 }
    }

    private func detachOutput() {
        if let output, let sampledItem { sampledItem.remove(output) }
        output = nil
        sampledItem = nil
    }

    /// Window coordinates of the surface, so the UX-9 measurement protocol's screenshot sampling
    /// knows exactly which rect to read.
    private func cardFrameDescription() -> String {
        guard let view else { return "{-}" }
        let rect = view.convert(view.bounds, to: nil)
        return String(format: "{%.0f,%.0f,%.0f,%.0f}", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    deinit { stop() }
}
