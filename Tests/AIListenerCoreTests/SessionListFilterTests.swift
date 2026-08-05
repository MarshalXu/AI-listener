import Foundation
import Testing
@testable import AIListenerCore

// MARK: - SidebarFilter contract

@Suite
struct SidebarFilterTests {
    @Test func allCasesAreOrderedRecentAllFavoritesTrash() {
        // The sidebar renders these in declaration order; locking the order
        // guards against an accidental reordering that would change the nav.
        #expect(SidebarFilter.allCases == [.recent, .all, .favorites, .trash])
    }

    @Test func labelsAreLocalizedChinese() {
        #expect(SidebarFilter.recent.label == "最近")
        #expect(SidebarFilter.all.label == "全部")
        #expect(SidebarFilter.favorites.label == "收藏")
        #expect(SidebarFilter.trash.label == "回收站")
    }

    @Test func systemImagesAreDistinct() {
        let images = Set(SidebarFilter.allCases.map(\.systemImage))
        #expect(images.count == SidebarFilter.allCases.count)
    }
}

// MARK: - SessionListFilter.apply

@Suite
struct SessionListFilterTests {
    /// Convenience builder so each session is uniquely identifiable and easy
    /// to assert against by its 1-based index.
    private func session(_ id: Int, preview: String? = nil, createdAtUtc: Int64? = nil) -> SessionListItem {
        SessionListItem(
            sessionId: "s\(id)",
            createdAtUtc: createdAtUtc ?? Int64(id),
            endedAtUtc: nil,
            durationMs: Int64(id) * 1000,
            transcriptState: "finalized",
            previewText: preview
        )
    }

    // - recent ----------------------------------------------------------------

    @Test func recentReturnsLeadingSliceCappedByLimit() {
        let sessions = (1...15).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .recent, searchText: "")
        #expect(result.map(\.sessionId) == (1...10).map { "s\($0)" })
        #expect(result.count == 10)
    }

    @Test func recentRespectsCustomLimit() {
        let sessions = (1...5).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .recent, searchText: "", recentLimit: 3)
        #expect(result.map(\.sessionId) == ["s1", "s2", "s3"])
    }

    @Test func recentWithFewerThanLimitReturnsAll() {
        let sessions = (1...3).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .recent, searchText: "")
        #expect(result.count == 3)
    }

    // - all -------------------------------------------------------------------

    @Test func allReturnsEverythingUnchangedOrder() {
        let sessions = (1...3).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .all, searchText: "")
        #expect(result.map(\.sessionId) == ["s1", "s2", "s3"])
    }

    // - favorites -------------------------------------------------------------

    @Test func favoritesIntersectFavoriteIds() {
        let sessions = (1...4).map { session($0, preview: "p\($0)") }
        let favs: Set<String> = ["s2", "s4"]
        let result = SessionListFilter.apply(to: sessions, filter: .favorites, searchText: "", favoriteIds: favs)
        #expect(result.map(\.sessionId) == ["s2", "s4"])
    }

    @Test func favoritesEmptyWhenNoFavoritesMatch() {
        let sessions = (1...3).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .favorites, searchText: "", favoriteIds: [])
        #expect(result.isEmpty)
    }

    @Test func favoritesEmptyWhenFavoriteIdsReferenceMissingSessions() {
        let sessions = (1...2).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .favorites, searchText: "", favoriteIds: ["sX"])
        #expect(result.isEmpty)
    }

    // - trash -----------------------------------------------------------------

    @Test func trashAlwaysReturnsEmpty() {
        // Hard-delete store has no trash state; trash is an empty placeholder.
        let sessions = (1...5).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .trash, searchText: "")
        #expect(result.isEmpty)
    }

    // - search ----------------------------------------------------------------

    @Test func searchMatchesCaseInsensitively() {
        let sessions = [
            session(1, preview: "Project Alpha"),
            session(2, preview: "project Beta"),
            session(3, preview: "Sprint Review")
        ]
        let result = SessionListFilter.apply(to: sessions, filter: .all, searchText: "PROJECT")
        #expect(result.map(\.sessionId) == ["s1", "s2"])
    }

    @Test func searchTrimsWhitespace() {
        let sessions = [
            session(1, preview: "alpha"),
            session(2, preview: "beta")
        ]
        let result = SessionListFilter.apply(to: sessions, filter: .all, searchText: "   alpha   ")
        #expect(result.map(\.sessionId) == ["s1"])
    }

    @Test func searchOnNilPreviewNeverMatches() {
        let sessions = [
            session(1, preview: nil),
            session(2, preview: "alpha")
        ]
        let result = SessionListFilter.apply(to: sessions, filter: .all, searchText: "alpha")
        #expect(result.map(\.sessionId) == ["s2"])
    }

    @Test func searchEmptyAfterTrimReturnsUnfiltered() {
        let sessions = (1...3).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .all, searchText: "   ")
        #expect(result.count == 3)
    }

    // - combined filter + search --------------------------------------------

    @Test func searchAppliedAfterFavoritesFilter() {
        let sessions = [
            session(1, preview: "Standup"),
            session(2, preview: "Standup retro"),
            session(3, preview: "Design review")
        ]
        let favs: Set<String> = ["s1", "s3"]
        let result = SessionListFilter.apply(to: sessions, filter: .favorites, searchText: "standup", favoriteIds: favs)
        #expect(result.map(\.sessionId) == ["s1"])
    }

    @Test func searchAppliedAfterRecentFilter() {
        let sessions = (1...12).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .recent, searchText: "p1")
        // recent limits to first 10 (s1..s10); of those, "p1" matches s1 and s10
        #expect(Set(result.map(\.sessionId)) == Set(["s1", "s10"]))
    }

    // - edge cases ------------------------------------------------------------

    @Test func emptyInputReturnsEmptyForEveryFilter() {
        for filter in SidebarFilter.allCases {
            let result = SessionListFilter.apply(to: [], filter: filter, searchText: "x")
            #expect(result.isEmpty, "filter \(filter) should yield [] on empty input")
        }
    }

    @Test func recentLimitClampedToZeroYieldsEmpty() {
        let sessions = (1...3).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .recent, searchText: "", recentLimit: 0)
        #expect(result.isEmpty)
    }

    @Test func recentLimitNegativeYieldsEmpty() {
        let sessions = (1...3).map { session($0, preview: "p\($0)") }
        let result = SessionListFilter.apply(to: sessions, filter: .recent, searchText: "", recentLimit: -5)
        #expect(result.isEmpty)
    }

    @Test func isPureAndPreservesOriginalList() {
        // The function must not mutate its input (value semantics make this
        // trivial in Swift, but this pins the contract explicitly).
        let sessions = (1...5).map { session($0, preview: "p\($0)") }
        let original = sessions
        _ = SessionListFilter.apply(to: sessions, filter: .all, searchText: "p1")
        #expect(sessions == original)
    }
}
