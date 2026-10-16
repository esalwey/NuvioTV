import SwiftUI

/// The behaviour and look of the tvOS system player (`AVPlayerViewController`, tvOS 26 / 27) that the
/// mpv chrome reproduces. docs/player-spec.md is the reference: every value here is cited there with
/// the source it comes from, and a change to one belongs in both places.
///
/// Source tags, as in the document:
///  - [doc]      Apple documentation (support guide, HIG, AVKit)
///  - [WWDC]     an Apple session or sample
///  - [observed] a third-party or user observation, with its URL in the document
///  - [observed: owner video 2026-10-16] measured frame by frame on the owner's phone recording of
///               the system player (NuvioTV's native engine on an Apple TV 4K, tvOS 26, French UI,
///               SDR episode of 22:35, 1920 x 1080, 60 fps container, 3532 frames). Times are good to
///               one frame (17 or 33 ms), clock readings to +/- 1 s, speeds to +/- 15 %, sizes to
///               +/- 5 % (the phone filmed the TV at an angle, so every size is the on-screen size
///               divided by the screen's own width, in points of a 1920 x 1080 canvas)
///  - [inferred] reasoned from the above, or from the native engine's behaviour on a device; the
///               video does not show it (the finger on the remote is never in the picture)
///
/// Nothing here is a guess dressed as a fact: a value that the video does not give says [inferred],
/// and the native engine (the system player itself) is the arbiter of all of them.
nonisolated enum PlayerSpec {

    /// One fade of the chrome: how long after its cause it starts, and how long it takes.
    struct Fade: Equatable {
        let delay: TimeInterval
        let duration: TimeInterval
    }

    // MARK: - Remote

    enum Remote {
        /// A click on the left or right edge skips this many seconds; another click skips another 10.
        /// [doc] "Press again to skip another 10 seconds." [observed: owner video 2026-10-16] eight
        /// clicks, each moving the elapsed label by 10 s (15:59 to 16:09, 16:31 to 16:21 ...) in the
        /// frame the glyph appears; no running total ("+20") is ever drawn. The seek is exact and keeps
        /// the play / pause state.
        static let skipSeconds: Double = 10

        /// An edge held at least this long is a hold (scan), not a click. [inferred] The video shows
        /// the picture freezing when the hold is recognised (45.2 s and 54.0 s) but never the finger,
        /// so the press-to-freeze delay cannot be read from it.
        static let holdThresholdSec: TimeInterval = 0.45

        /// Hold: how fast the head runs in each tier, in media seconds per second, and the digit the
        /// badge shows. [observed: owner video 2026-10-16] rewind 7.8 s/s (45.6 to 47.4 s, 14 s in
        /// 1.8 s), 23.5 s/s (47.6 to 49.6 s, 47 s in 2 s), 48 s/s (50.0 to 51.6 s, 78 s in 1.6 s);
        /// forward 8, 24 and 40 to 50 s/s. The ratio is 1 : 3 : 6. No tier above the third was ever
        /// reached (the longest hold lasted 7.4 s).
        static let scanRates: [Double] = [8, 24, 48]

        /// The digit beside the badge in each tier: none, "2", "3" (no multiplication sign; the
        /// owner expected x1 / x2 / x4, the system draws bare digits). [observed: owner video 2026-10-16]
        static let scanDigits: [Int?] = [nil, 2, 3]

        /// How long each tier lasts, counted from the moment the picture freezes. [observed: owner
        /// video 2026-10-16] tier 2 starts 2.33 s (rewind) and 2.5 s (forward) after the freeze, tier 3
        /// 4.73 s and 4.97 s after it.
        static let scanTierSec: TimeInterval = 2.4

        /// The head starts to run this long after the picture freezes. [observed: owner video
        /// 2026-10-16] rewind: freeze 45.2 s, first label change 45.6 s; forward: 54.0 s and 54.25 s.
        static let scanStartDelaySec: TimeInterval = 0.3

        /// The badge glyph appears this long after the freeze. [observed: owner video 2026-10-16]
        /// 0.3 s (rewind, one frame), 0.13 to 0.27 s (forward, fading in over four frames).
        static let scanBadgeDelaySec: TimeInterval = 0.2

        /// A tier change reaches its new speed within this time. [observed: owner video 2026-10-16]
        /// 100 to 200 ms (a plateau of up to three frames in the label at the change).
        static let scanRampSec: TimeInterval = 0.15

        /// The head never runs closer than this to the end of the file while scanning.
        static let scanEndMarginSec: Double = 1
    }

    // MARK: - Skip (click on an edge)

    enum Skip {
        /// The direction glyph beside the elapsed label (forward on its right, back on its left) lives
        /// this long, then fades out in `glyphFadeSec`. [observed: owner video 2026-10-16] 0.25 to
        /// 0.5 s over eight clicks (18.085 to 18.5, 23.088 to 23.45, 62.825 to 63.099 ...).
        static let glyphLifetimeSec: TimeInterval = 0.35
        static let glyphFadeSec: TimeInterval = 0.1

        /// Back skips closer together than this belong to one run. [inferred] the observed gaps are
        /// 1.2 to 1.9 s; the video has no longer one.
        static let runGapSec: TimeInterval = 3

        /// The third back skip of a run turns the subtitles on. [observed: owner video 2026-10-16]
        /// the clicks at 23.1 and 24.5 s showed no subtitle and no hint; the third, at 25.8 s, did
        /// (subtitles at 26.033 s, 0.23 s after the click).
        static let subtitlesFromClick = 3

        /// The hint under the remaining time says "Subtitles on for 11 seconds", a constant (it never
        /// counts down), and the subtitles go off by themselves after that long (still on at 36.0 s,
        /// off at 39.2 s; 25.8 + 11 = 36.8). [observed: owner video 2026-10-16]
        static let subtitlesWindowSec: Int = 11
    }

    // MARK: - Scrub (swipe while paused)

    enum Scrub {
        /// After the finger leaves, the head glides on: an exponential approach with this time
        /// constant. [observed: owner video 2026-10-16] flick 1 (15:43 to 16:40): +42 s in three
        /// frames, then 988, 990, 992, 994, 995, 996, 997 ... 1000 s (a tail of 15 s, 63 % of it in
        /// 0.2 s); flick 4 (18:14 to 17:19): -45 s in three frames, then a tail of -10 s.
        static let tailTimeConstantSec: TimeInterval = 0.22

        /// The tail adds this share of what the finger moved in its last tenth of a second.
        /// [observed: owner video 2026-10-16] tails are 20 to 35 % of the flick.
        static let tailShare: Double = 0.3

        /// ... and never more than this share of the duration: 15 s on a 22:35 file.
        /// [observed: owner video 2026-10-16]
        static let tailMaxShareOfDuration: Double = 0.011

        /// How far a swipe moves the head, as a share of the duration per full width of the touch
        /// surface, for a slow and for a fast swipe (in surface widths per second), smoothly in
        /// between. [inferred] the finger is not in the video; these give the measured outcome for a
        /// quick flick (a third of the surface in a tenth of a second moves the head 45 s on a 22:35
        /// file: flicks of 42 to 65 s in one to three frames) and a fine control for a slow one.
        static let gainSlow: Double = 0.02
        static let gainFast: Double = 0.12
        static let speedSlow: Double = 0.3
        static let speedFast: Double = 2.5

        /// The chrome answers a finger this long after it lands. [observed: owner video 2026-10-16]
        /// finger at 4.500 s, first frame of the fade at 4.567 s.
        static let touchReactionSec: TimeInterval = 0.07

        /// A finger resting on the surface for this long shows the knob; one that starts swiping
        /// sooner never does. [observed: owner video 2026-10-16] the resting finger shows it within
        /// 0.1 s (4.45 s), none of the twelve flicks does.
        static let knobDelaySec: TimeInterval = 0.1
        static let knobGrowSec: TimeInterval = 0.2
        static let knobShrinkSec: TimeInterval = 0.15

        /// A touch with no swipe after it hands the bar back to the full chrome after this long.
        /// [inferred] no touch rested for long in the video; the idle time of the chrome applies.
        static let idleReturnSec: TimeInterval = 5
    }

    // MARK: - Chrome

    enum Chrome {
        /// The chrome hides this long after the last interaction while playing; paused, scrubbing or
        /// scanning it stays until the viewer acts. [observed: owner video 2026-10-16] 5.03 s after
        /// the scrub commit (visible 15.633 s, gone 20.767 s), and every gap between two visible
        /// events in the 26 s run 39.6 to 66.1 s (at most 3.9 s) fits it. A +/-10 s click while the
        /// full chrome is up does not restart it (the chrome hid 0.72 s after a click).
        static let autoHideDelay: TimeInterval = 5

        /// The bar alone (a skip click with the chrome hidden) hides this long after the last click.
        /// [observed: owner video 2026-10-16] the series of clicks 21.9, 23.1, 24.5, 25.8 and 27.54 s
        /// kept it up until the swipe down at 29.5 s, 1.98 s after the last one; it hides no sooner
        /// than that. Each click restarts it. The upper bound is not in the video: the chrome's own
        /// idle time stands in.
        static let skimLifetime: TimeInterval = autoHideDelay

        /// Fade-out of the chrome, pure opacity with no slide (the old 16 pt slide is gone).
        /// [observed: owner video 2026-10-16] auto-hide 20.637 to 20.770 s: pills and bar lead by one
        /// frame, title and buttons follow, 4 to 5 frames in all.
        static let hideFadeSec: TimeInterval = 0.15

        /// The title, the buttons and the tab pills fade out when a finger lands on the surface of a
        /// paused player (the bar and its labels stay). [observed: owner video 2026-10-16] 4.567 to
        /// 4.667 s, 100 to 130 ms.
        static let touchFadeSec: TimeInterval = 0.115

        /// A pause with the chrome hidden: the picture freezes at once and the chrome follows after
        /// this delay. [observed: owner video 2026-10-16] freeze 1.600 s, first chrome 1.883 s.
        static let pauseRevealDelaySec: TimeInterval = 0.3

        /// Cascades of the parts' fade-in, relative to their cause. [observed: owner video
        /// 2026-10-16] after a pause (cause = the first chrome frame, 1.883 s): buttons 1.883 to
        /// 2.017 s, bar, labels and pause glyph 1.917 to 2.017 s, title and pills 2.15 to 2.283 s
        /// (the pills' glass lags their text by two frames). After a commit or any other show
        /// (cause = 15.618 s): buttons 15.618 to 15.652, title and pills 15.652 to 15.752 s, 167 ms in
        /// all, no slide. The bar alone (a skip click with the chrome hidden): 21.903 to 22.0 s.
        static let pauseButtons = Fade(delay: 0, duration: 0.13)
        static let pauseBar = Fade(delay: 0.03, duration: 0.1)
        static let pauseTitle = Fade(delay: 0.27, duration: 0.12)
        static let pausePills = Fade(delay: 0.27, duration: 0.15)
        static let showButtons = Fade(delay: 0, duration: 0.04)
        static let showBar = Fade(delay: 0, duration: 0.05)
        static let showTitle = Fade(delay: 0.033, duration: 0.07)
        static let showPills = Fade(delay: 0.033, duration: 0.1)
        static let skimBar = Fade(delay: 0, duration: 0.115)

        /// The captions move up (or down) in this time when the chrome or the tab view comes or goes.
        /// [observed: owner video 2026-10-16] 29.523 to 29.557 s, two frames, as a crossfade between the
        /// two positions when the tab view opens.
        static let captionsLiftSec: TimeInterval = 0.1

        /// The bar and its labels drop to this opacity while focus sits on a transport button.
        /// [observed: owner video 2026-10-16] 64.867 s, "bar and elapsed label dim".
        static let dimmedBarOpacity: Double = 0.4
    }

    // MARK: - Layout (points of a 1920 x 1080 canvas, measured from the screen's own edges)

    enum Layout {
        /// Side inset of the bar, the buttons and the pills. [observed: owner video 2026-10-16] 83 pt
        /// on the left and 78 pt on the right.
        static let sideInset: CGFloat = 82
        /// The pills' bottom edge above the bottom of the screen. [observed: owner video 2026-10-16]
        static let bottomInset: CGFloat = 47

        /// The round buttons: diameter and gap (pitch 89 pt, seven of them). [observed: owner video
        /// 2026-10-16] 55 px of a 1620 px wide screen, 20 px gap.
        static let buttonDiameter: CGFloat = 65
        static let buttonSpacing: CGFloat = 24

        /// The tab pills: height, gap and the text's size. [observed: owner video 2026-10-16]
        static let pillHeight: CGFloat = 64
        static let pillSpacing: CGFloat = 24
        static let pillPadding: CGFloat = 31
        static let pillFont: CGFloat = 27

        /// Title block: the title (bold) and the episode line above it. [observed: owner video
        /// 2026-10-16] cap height 33 px of a 1620 px wide screen, the width of "Rick et Morty" 294 px.
        static let titleFont: CGFloat = 57
        static let episodeFont: CGFloat = 26
        /// The title's capitals are centred 249 pt over the bottom edge and the episode line's 314 pt
        /// (65 pt apart), the buttons' centre 258 pt. A block laid out bottom-aligned with the buttons
        /// would put the title's centre 10.5 pt higher, so it is dropped by that much (`titleDrop`),
        /// with `episodeToTitle` between the two line boxes. [observed: owner video 2026-10-16]
        static let episodeToTitle: CGFloat = 15
        static let titleDrop: CGFloat = 10.5
        /// The labels under the bar. [observed: owner video 2026-10-16] digits 15 px tall.
        static let labelFont: CGFloat = 25
        static let hintFont: CGFloat = 22

        /// The bar: thickness at rest and while a finger or a scrub is on it, the gap between the
        /// buttons and the bar, the labels' centre under the bar, how much further down the knob
        /// pushes them, and the gap down to the pills. [observed: owner video 2026-10-16] 12.5 px at
        /// rest (full chrome), 16.5 px scrubbing, 19 px with the knob; labels 29 pt under the bar, 38
        /// pt with the knob.
        static let barThickness: CGFloat = 15
        static let barThicknessActive: CGFloat = 21
        static let titleRowToBar: CGFloat = 37.5
        static let labelOffset: CGFloat = 29
        static let labelKnobExtra: CGFloat = 11
        static let barToPills: CGFloat = 13
        static let scrubberRowHeight: CGFloat = 64

        /// The knob: a white disc with an indigo ring inside. [observed: owner video 2026-10-16]
        /// 43 px across (51 pt), ring 25 px (30 pt).
        static let knobDiameter: CGFloat = 51
        static let knobRingDiameter: CGFloat = 30

        /// The state glyphs beside the elapsed label: ring size and the gap to the label.
        /// [observed: owner video 2026-10-16] ring 21 px (25 pt), gap 16 px (19 pt).
        static let glyphDiameter: CGFloat = 26
        static let glyphGap: CGFloat = 18

        /// The tab view (swipe down): the content's top edge is 514 pt above the bottom of the screen
        /// (the Info card spans 264 to 515 pt, the chapter cards 297 to 529 pt, the episode stills
        /// 278 to 514 pt), the pills' centre 592 to 611 pt above it, 46 pt over the content. The
        /// content box is 300 pt tall (the episodes' stills and captions are the tallest), so its
        /// bottom edge is 214 pt above the bottom of the screen; the Info card's corner is 40 pt.
        /// [observed: owner video 2026-10-16]
        static let tabContentBottom: CGFloat = 214
        static let tabContentHeight: CGFloat = 300
        static let tabPillsToContent: CGFloat = 46
        static let tabCardRadius: CGFloat = 40
        /// A tab view that opens with the bar away slides up from the bottom edge by this much.
        static let tabSlideDistance: CGFloat = 160
    }

    // MARK: - Tab view

    enum Tabs {
        /// The tab view slides up from the bottom edge. [observed: owner video 2026-10-16] 29.557 to
        /// 29.8 s, about 230 ms, with a fade.
        static let openSec: TimeInterval = 0.23
        /// Back or a swipe up: the pills (with the title and the bar) go back down to the transport
        /// layout in this time, ease-out, while the content fades. [observed: owner video 2026-10-16]
        /// 39.3 to 39.6 s.
        static let closeSec: TimeInterval = 0.3
        /// The content crossfades when the selected pill changes. [observed: owner video 2026-10-16]
        /// 0.1 to 0.3 s, 0.3 s on the cards.
        static let swapSec: TimeInterval = 0.3
    }
}
