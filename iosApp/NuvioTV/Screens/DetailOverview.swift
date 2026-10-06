import SwiftUI

/// AES-10: the Details synopsis, capped at `collapsedLines` so a long overview no longer pushes the
/// cast and episode rows off the first screen, with a More / Less pill that expands it in place.
///
/// The pill exists only when the text really overflows at its width — two hidden copies (full and
/// capped) are measured — so a short synopsis adds no focus stop between the action row and the
/// rows below. It lives inside `DetailView.topBlock`'s focus section like the action-row buttons,
/// and wears the same system `.bordered` capsule as them (VIS-08: no glass on content). In place
/// rather than a modal: a cover over Details would have to pause and tear down the hero trailer.
/// No animation on the toggle: the page's row anchoring reads layout, so the change lands once.
struct DetailOverview: View {
    let text: String
    var collapsedLines = 4
    var maxWidth: CGFloat = 1100

    /// Accessibility identifier of the More / Less pill.
    static let toggleIdentifier = "detail.overview.toggle"

    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0

    /// Taller than `collapsedLines` at this width (1 pt of slack for rounding).
    private var overflows: Bool { fullHeight > collapsedHeight + 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(expanded ? nil : collapsedLines)
                .truncationMode(.tail)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .background(alignment: .topLeading) { measurements }
            if overflows || expanded {
                toggle
            }
        }
    }

    /// The full text and the capped one, laid out at the visible text's width and never drawn.
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .font(Theme.Font.body)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                    fullHeight = height
                })
            Text(text)
                .font(Theme.Font.body)
                .lineLimit(collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { height in
                    collapsedHeight = height
                })
        }
        .hidden()
        .accessibilityHidden(true)
    }

    private var toggle: some View {
        Button {
            expanded.toggle()
        } label: {
            Label(expanded ? String(localized: "Less") : String(localized: "More"),
                  systemImage: expanded ? "chevron.up" : "chevron.down")
                .font(Theme.Font.meta)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        // The UI tests' handle on this extra focus stop (DetailRowAnchorTests steps past it).
        .accessibilityIdentifier(Self.toggleIdentifier)
    }
}
