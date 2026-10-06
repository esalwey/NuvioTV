import SwiftUI

/// Full-bleed title artwork behind a screen's own content: the image, then a leading scrim for text
/// on the left and a bottom fade — the Details page's recipe (`DetailView.scrimOverlay`) as one
/// layer, for the screens around playback that sat on flat black (the stream picker, AES-3; the
/// player's end screen). Falls back to the plain app background when there's no art.
///
/// `blurRadius` is for low-resolution fallbacks (an episode still or a poster blown up to 1920 pt);
/// a real backdrop stays sharp, like on Details. Decorative: hidden from VoiceOver, never hit-tested.
struct ArtworkBackdrop: View {
    let url: String?
    var blurRadius: CGFloat = 0

    var body: some View {
        ZStack {
            Theme.Palette.background
            if let url = CachedTitleArt.nonEmpty(url) {
                GeometryReader { geo in
                    // A failed load shows nothing rather than the grey film-glyph placeholder.
                    CachedAsyncImage(string: url, failure: { Color.clear })
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: blurRadius, opaque: true)
                }
                LinearGradient(
                    colors: [.black.opacity(0.95), .black.opacity(0.55), .black.opacity(0.7)],
                    startPoint: .leading, endPoint: .trailing
                )
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .center, endPoint: .bottom
                )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
