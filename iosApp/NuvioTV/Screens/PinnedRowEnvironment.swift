import SwiftUI

/// BUG-89 (Steven's beta.17 report — a hidden-title square-tile Fusion folder shelf left visibly
/// under the fold, under "Genres", for seconds after it became the last row focused): the last
/// pinned row is the one row the canonical-rest corrector (`PinnedRowSettle` in
/// `BrowseComponents.swift`) EXEMPTS by design — there is no row below it to reveal into, so
/// `settlePlan` returns `targetY: nil` for it (`endOfContent` / upward-no-room) and the corrector
/// never fires. `HomeView.rowsInsets(pinned:heroInScroll:)` is the fix for the common shortfall
/// (a bottom content inset sized to the LAST row's own height, so the scroll range alone can
/// reveal it fully with no corrector involved) — but `PinnedRowSettleTracking` still needs to know
/// it is measuring the exempt row so it can skip the end-of-content rest in its own bookkeeping
/// and log `last=` on the row's `debug_pinned` line, rather than treating a legitimately
/// unreachable rest as a fresh failure to correct.
///
/// Set by `HomeView` on the `ForEach(model.rows)` row content (`row.id == model.rows.last?.id`);
/// read by `PinnedRowSettleTracking` (`BrowseComponents.swift`) into its `Measurement`. Defaults
/// to false everywhere else (Search, Library, every other `CatalogRowView`/`CollectionRowView`
/// host), so nothing outside Home's pinned rows list is affected.
private struct PinnedRowIsLastKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var pinnedRowIsLast: Bool {
        get { self[PinnedRowIsLastKey.self] }
        set { self[PinnedRowIsLastKey.self] = newValue }
    }
}
