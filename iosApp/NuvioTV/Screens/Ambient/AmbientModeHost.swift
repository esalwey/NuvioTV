import SwiftUI
import UIKit

/// A slide with its artwork decoded and ready to draw.
private struct AmbientLoadedSlide: Identifiable {
    let slide: AmbientSlide
    let backdrop: UIImage
    let logo: UIImage?
    /// Distinguishes a repeat of the same title, so its layer is built fresh.
    let serial: Int
    var id: String { "\(slide.id)#\(serial)" }
}

/// The full-screen slideshow. Plays the slides in order, loading the next while the current one is
/// on screen, and skipping any whose artwork does not load.
struct AmbientSlideshow: View {
    let slides: [AmbientSlide]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var current: AmbientLoadedSlide?
    @State private var motion = AmbientMotion.still

    var body: some View {
        ZStack {
            Color.black
            if let current {
                AmbientSlideLayer(loaded: current, motion: motion, reduceMotion: reduceMotion)
                    .id(current.id)
            }
        }
        .ignoresSafeArea()
        .task(id: slides) { await play() }
    }

    private func play() async {
        guard !slides.isEmpty else { return }
        var index = 0
        var serial = 0
        var misses = 0
        var previousMotion: AmbientMotion?
        var generator = SystemRandomNumberGenerator()
        var pending: Task<AmbientLoadedSlide?, Never>? = Self.loadTask(slides[0], serial: 0)
        defer { pending?.cancel() }

        while !Task.isCancelled {
            let loaded = await pending?.value
            index += 1
            serial += 1
            pending = Self.loadTask(slides[index % slides.count], serial: serial)

            guard let loaded else {
                misses += 1
                if misses >= slides.count {
                    misses = 0
                    try? await Task.sleep(for: .seconds(AmbientTiming.allFailedRetry))
                }
                continue
            }
            misses = 0
            let nextMotion: AmbientMotion = reduceMotion
                ? .still
                : AmbientMotion.next(after: previousMotion, using: &generator)
            previousMotion = nextMotion
            motion = nextMotion
            current = loaded
            try? await Task.sleep(for: .seconds(AmbientTiming.motionDuration + AmbientTiming.blackHold))
        }
    }

    private static func loadTask(_ slide: AmbientSlide, serial: Int) -> Task<AmbientLoadedSlide?, Never> {
        Task { await load(slide, serial: serial) }
    }

    private static func load(_ slide: AmbientSlide, serial: Int) async -> AmbientLoadedSlide? {
        guard let backdrop = try? await ArtworkStore.fetch(slide.backdropURL) else { return nil }
        var logo: UIImage?
        if let logoURL = slide.logoURL {
            logo = try? await ArtworkStore.fetch(logoURL)
        }
        return AmbientLoadedSlide(slide: slide, backdrop: backdrop, logo: logo, serial: serial)
    }
}

/// One slide's whole life: the backdrop fades in under a slow camera move, the title and genres
/// follow, everything holds, then fades back to black. Built fresh per slide, so its animation state
/// always starts from rest.
private struct AmbientSlideLayer: View {
    let loaded: AmbientLoadedSlide
    let motion: AmbientMotion
    let reduceMotion: Bool

    @State private var backdropOpacity = 0.0
    @State private var titleOpacity = 0.0
    @State private var genresOpacity = 0.0
    @State private var progress: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                Image(uiImage: loaded.backdrop)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .scaleEffect(motion.scale(at: progress))
                    .offset(motion.offset(at: progress, in: proxy.size))
                    .opacity(backdropOpacity)
                    .accessibilityHidden(true)

                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.45),
                        .init(color: .black.opacity(0.7), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .opacity(backdropOpacity)
                .accessibilityHidden(true)

                caption
                    // Text keeps to the TV safe area (80 pt sides, 60 pt bottom) while the artwork bleeds.
                    .padding(.leading, 80)
                    .padding(.bottom, 60)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .task { await play() }
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Group {
                if let logo = loaded.logo {
                    Image(uiImage: logo)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: Theme.Size.heroLogoMaxWidth,
                               maxHeight: Theme.Size.heroLogoSlotHeightPinned,
                               alignment: .leading)
                } else {
                    Text(loaded.slide.title)
                        .font(Theme.Font.hero)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: Theme.Size.heroLogoMaxWidth * 1.5, alignment: .leading)
                }
            }
            .opacity(titleOpacity)
            .offset(y: reduceMotion ? 0 : (1 - titleOpacity) * 18)
            .accessibilityLabel(Text(loaded.slide.title))

            if !loaded.slide.genres.isEmpty {
                Text(loaded.slide.genres.joined(separator: "  \u{2022}  "))
                    .font(Theme.Font.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .opacity(genresOpacity)
                    .offset(y: reduceMotion ? 0 : (1 - genresOpacity) * 12)
            }
        }
    }

    private func play() async {
        withAnimation(.linear(duration: AmbientTiming.motionDuration)) { progress = 1 }
        withAnimation(.easeInOut(duration: AmbientTiming.backdropFadeIn)) { backdropOpacity = 1 }
        guard await pause(AmbientTiming.backdropFadeIn + AmbientTiming.titleDelay) else { return }

        withAnimation(.easeOut(duration: AmbientTiming.titleFadeIn)) { titleOpacity = 1 }
        guard await pause(AmbientTiming.genresDelay) else { return }
        withAnimation(.easeOut(duration: AmbientTiming.genresFadeIn)) { genresOpacity = 1 }
        guard await pause(AmbientTiming.titleFadeIn - AmbientTiming.genresDelay + AmbientTiming.hold) else { return }

        withAnimation(.easeInOut(duration: AmbientTiming.genresFadeOut)) { genresOpacity = 0 }
        guard await pause(AmbientTiming.genresFadeOut) else { return }
        withAnimation(.easeInOut(duration: AmbientTiming.titleFadeOut)) { titleOpacity = 0 }
        guard await pause(AmbientTiming.titleFadeOut) else { return }
        withAnimation(.easeInOut(duration: AmbientTiming.backdropFadeOut)) { backdropOpacity = 0 }
    }

    /// Sleeps; false when the layer was removed meanwhile.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }
}

/// The overlay at the app root: nothing until the idle controller shows it, then the slideshow
/// fades in over everything in the tab shell. A press fades it out again (see `AmbientInputGate`).
struct AmbientModeLayer: View {
    @ObservedObject private var controller = AmbientIdleController.shared

    var body: some View {
        ZStack {
            if controller.isShowing {
                AmbientSlideshow(slides: controller.slides)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
            }
        }
        .animation(.easeInOut(duration: controller.isShowing ? 0.9 : 0.4), value: controller.isShowing)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Wires Ambient Mode into the app root: the overlay, the input hook, and the idle loop's inputs.
private struct AmbientModeAttachment: ViewModifier {
    let shellActive: Bool
    let slides: () -> [AmbientSlide]

    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay { AmbientModeLayer() }
            .onAppear {
                let controller = AmbientIdleController.shared
                AmbientInputMonitor.installIfNeeded()
                controller.slideProvider = slides
                controller.shellActive = shellActive
                controller.appActive = scenePhase == .active
                controller.start()
            }
            .onChange(of: shellActive) { _, active in
                let controller = AmbientIdleController.shared
                controller.shellActive = active
                if !active { controller.dismiss() }
                controller.noteActivity()
            }
            .onChange(of: scenePhase) { _, phase in
                let controller = AmbientIdleController.shared
                controller.appActive = phase == .active
                // Leaving the foreground (home screen, Top Shelf, Siri) ends the slideshow now:
                // the idle loop only re-checks eligibility every few seconds, and until then the
                // first remote press after coming back would be swallowed as the dismiss press.
                if phase != .active { controller.dismiss() }
                controller.noteActivity()
            }
    }
}

extension View {
    /// Ambient Mode for the app root. `slides` is asked for the slide list each time the slideshow
    /// is about to start, so it always reflects what Home has loaded by then.
    func ambientMode(shellActive: Bool, slides: @escaping () -> [AmbientSlide]) -> some View {
        modifier(AmbientModeAttachment(shellActive: shellActive, slides: slides))
    }
}
