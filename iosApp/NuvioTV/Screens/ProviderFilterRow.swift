import SwiftUI

/// The source filter row of a stream list: a refresh button, then "All" and one capsule per
/// add-on, each with where that add-on stands (still answering, failed, or how many streams it
/// brought). Select narrows the list to that add-on; "All" brings the rest back. Mobile parity:
/// `ProviderFilterRow.kt` (refresh first, then All, then the add-ons that have streams or are
/// still loading).
///
/// Shared by the stream picker and, later, a sources panel in the player, so it knows nothing of
/// the view model: the caller maps its own state to `Item`s.
///
/// System controls only: `.bordered` capsules (the selected one carries a checkmark and a
/// semibold label, never colour alone), a system spinner for "loading" (it follows Reduce
/// Motion). One focus section, so Up/Down from the list lands on the row.
struct ProviderFilterRow: View {
    struct Item: Identifiable, Equatable {
        enum Status: Equatable {
            /// Still answering; more streams may come.
            case loading
            /// Answered; `count` streams are listed.
            case ready
            /// Failed or timed out.
            case failed
        }
        let id: String
        let name: String
        let status: Status
        /// Streams listed for this add-on right now.
        let count: Int
    }

    let items: [Item]
    /// The selected add-on's id; nil is "All".
    let selectedId: String?
    /// Something is still loading: the refresh button shows a spinner instead of its arrow.
    let isRefreshing: Bool
    /// Focus keys are `chip:<id>`, `chip:all` and `chip:refresh`, in the caller's focus state.
    let focus: FocusState<String?>.Binding
    let onSelect: (String?) -> Void
    /// nil hides the refresh button.
    let onRefresh: (() -> Void)?

    static let allKey = "chip:all"
    static let refreshKey = "chip:refresh"
    static func key(for id: String) -> String { "chip:\(id)" }

    /// One add-on alone is not a choice: "All" and its chip would say the same thing.
    private var showsFilters: Bool { items.count > 1 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                if let onRefresh {
                    refreshButton(onRefresh)
                }
                if showsFilters {
                    chip(name: String(localized: "All"), isSelected: selectedId == nil,
                         status: nil, accessibilityDetail: nil, key: Self.allKey) {
                        onSelect(nil)
                    }
                    ForEach(items) { item in
                        chip(name: item.name, isSelected: selectedId == item.id,
                             status: item, accessibilityDetail: Self.detail(for: item),
                             key: Self.key(for: item.id)) {
                            onSelect(item.id)
                        }
                    }
                }
            }
            // Room for the focus lift and platter, which a scroll view would otherwise clip.
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func refreshButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .font(Theme.Font.meta)
            .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .focused(focus, equals: Self.refreshKey)
        .accessibilityLabel(Text("Refresh Sources"))
        .accessibilityValue(isRefreshing ? Text("Loading") : Text(verbatim: ""))
    }

    private func chip(name: String, isSelected: Bool, status: Item?, accessibilityDetail: String?,
                      key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if isSelected {
                    Image(systemName: "checkmark")
                }
                Text(name)
                    .lineLimit(1)
                if let status {
                    statusAccessory(status)
                }
            }
            .font(Theme.Font.meta)
            .fontWeight(isSelected ? .semibold : nil)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .focused(focus, equals: key)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityDetail.map { "\(name), \($0)" } ?? name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func statusAccessory(_ item: Item) -> some View {
        switch item.status {
        case .loading:
            ProgressView()
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Palette.warning)
        case .ready:
            Text("\(item.count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private static func detail(for item: Item) -> String {
        switch item.status {
        case .loading:
            return String(localized: "Loading")
        case .failed:
            return String(localized: "Unavailable")
        case .ready:
            return item.count == 1 ? String(localized: "1 stream") : String(localized: "\(item.count) streams")
        }
    }
}
