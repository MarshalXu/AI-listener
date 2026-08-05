import Foundation

// MARK: - SidebarFilter

/// Navigation filters exposed by the left sidebar in `SessionLibraryView`.
/// Each case maps to a client-side predicate over `[SessionListItem]`.
///
/// - Note: Favorites are stored locally as a `UserDefaults` set of session
///   IDs (see `SessionFavoritesStore`). They do **not** modify `SessionStore`
///   schema — the underlying data source stays unchanged, per XUC-12 scope.
///   Trash is a placeholder that surfaces an empty state until a soft-delete
///   data model is added in a later slice; existing deletion stays hard.
public enum SidebarFilter: String, CaseIterable, Sendable, Equatable, Hashable {
    case recent
    case all
    case favorites
    case trash

    public var label: String {
        switch self {
        case .recent: "最近"
        case .all: "全部"
        case .favorites: "收藏"
        case .trash: "回收站"
        }
    }

    public var systemImage: String {
        switch self {
        case .recent: "clock"
        case .all: "list.bullet"
        case .favorites: "star"
        case .trash: "trash"
        }
    }
}

// MARK: - SessionListFilter

/// Pure, side-effect-free filtering for the session list sidebar + search box.
///
/// Extracted out of `SessionLibraryViewModel` so that the filter logic can be
/// unit-tested by `AIListenerCoreTests` without an App-layer test target
/// (the App target has no tests; `AIListenerCoreTests` only depends on
/// `AIListenerCore`). Keeping this a pure function — no SwiftUI, no
/// `ObservableObject`, no `UserDefaults` — is what makes that possible.
public enum SessionListFilter {
    /// Returns the subset of `sessions` matching `filter` and `searchText`.
    ///
    /// - `recent`: the most recent sessions (capped at `recentLimit`,
    ///   default 10), ordered newest-first — matching the descending
    ///   `created_at_utc` order `listPlayableSessions` already returns.
    /// - `all`: all sessions, unchanged order.
    /// - `favorites`: sessions whose `sessionId` is in `favoriteIds`.
    /// - `trash`: empty — hard-delete store has no trash state; the sidebar
    ///   shows an empty placeholder. Surfaced here (rather than dropping the
    ///   case) so the enum stays the single source of truth for nav items and
    ///   the empty-state is explicit, not an accidental `[]`.
    ///
    /// `searchText` is matched case-insensitively, trimmed, against each
    /// session's `previewText` (falling back to empty string when nil).
    public static func apply(
        to sessions: [SessionListItem],
        filter: SidebarFilter,
        searchText: String,
        favoriteIds: Set<String> = [],
        recentLimit: Int = 10
    ) -> [SessionListItem] {
        let filtered: [SessionListItem]
        switch filter {
        case .recent:
            // sessions already arrive newest-first from listPlayableSessions;
            // take the leading slice.
            filtered = Array(sessions.prefix(max(0, recentLimit)))
        case .all:
            filtered = sessions
        case .favorites:
            filtered = sessions.filter { favoriteIds.contains($0.sessionId) }
        case .trash:
            // No soft-delete backend: trash is an empty placeholder. Returning
            // [] intentionally so the empty-state UI is driven by data, not a
            // special-cased view.
            filtered = []
        }

        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return filtered }

        return filtered.filter { item in
            let preview = (item.previewText ?? "").lowercased()
            return preview.contains(needle)
        }
    }
}
