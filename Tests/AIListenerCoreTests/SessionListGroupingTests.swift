import Foundation
import Testing
@testable import AIListenerCore

@Suite
struct SessionListGroupingTests {

    // MARK: - Fixtures

    /// A fixed calendar/timezone so "today" boundaries are deterministic
    /// regardless of the machine running the suite.
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    /// `2026-08-05 13:00:00` in Shanghai — the pinned "now" for all tests.
    private var referenceDate: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: "2026-08-05T13:00:00.000+08:00")!
    }

    private func session(
        id: String = UUID().uuidString,
        createdAtUtc: Int64,
        durationMs: Int64 = 60_000,
        preview: String? = "预览文本"
    ) -> SessionListItem {
        SessionListItem(
            sessionId: id,
            createdAtUtc: createdAtUtc,
            endedAtUtc: createdAtUtc + durationMs,
            durationMs: durationMs,
            transcriptState: "finalized",
            previewText: preview
        )
    }

    /// Convenience: turns "HH:mm" on the reference day into a millisecond UTC
    /// timestamp anchored in the test timezone.
    private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Int64 {
        var components = calendar.dateComponents(
            [.year, .month, .day], from: referenceDate
        )
        components.hour = hour
        components.minute = minute
        components.timeZone = calendar.timeZone
        let date = calendar.date(from: components)!
        let shifted = calendar.date(
            byAdding: .day, value: dayOffset, to: date
        ) ?? date
        return Int64(shifted.timeIntervalSince1970 * 1_000)
    }

    // MARK: - Tests

    @Test("Empty input yields no groups")
    func emptyInputYieldsNoGroups() {
        let groups = SessionListGrouping.groupSessionsByDay(
            [], referenceDate: referenceDate, calendar: calendar
        )
        #expect(groups.isEmpty)
    }

    @Test("Sessions split across today / yesterday / earlier, newest-first")
    func threeBucketsInOrder() {
        // Deliberately newest-first, matching listPlayableSessions() ordering.
        let sessions = [
            session(id: "t2", createdAtUtc: at(14, 0)),                 // today 14:00
            session(id: "t1", createdAtUtc: at(9, 30)),                 // today 09:30
            session(id: "y2", createdAtUtc: at(20, 0, dayOffset: -1)), // yesterday 20:00
            session(id: "y1", createdAtUtc: at(8, 0, dayOffset: -1)),  // yesterday 08:00
            session(id: "e2", createdAtUtc: at(18, 0, dayOffset: -2)), // 2 days ago
            session(id: "e1", createdAtUtc: at(6, 0, dayOffset: -3)),  // 3 days ago
        ]

        let groups = SessionListGrouping.groupSessionsByDay(
            sessions, referenceDate: referenceDate, calendar: calendar
        )

        #expect(groups.count == 3)
        #expect(groups.map(\.id) == ["today", "yesterday", "earlier"])
        #expect(groups.map(\.label) == ["今天", "昨天", "更早"])

        #expect(groups[0].items.map(\.sessionId) == ["t2", "t1"])
        #expect(groups[1].items.map(\.sessionId) == ["y2", "y1"])
        #expect(groups[2].items.map(\.sessionId) == ["e2", "e1"])
    }

    @Test("Each bucket preserves the original relative order")
    func orderPreservedWithinBuckets() {
        let sessions = [
            session(id: "a", createdAtUtc: at(23, 0)),
            session(id: "b", createdAtUtc: at(12, 0)),
            session(id: "c", createdAtUtc: at(1, 0)),
        ]
        let groups = SessionListGrouping.groupSessionsByDay(
            sessions, referenceDate: referenceDate, calendar: calendar
        )
        #expect(groups.count == 1)
        #expect(groups[0].items.map(\.sessionId) == ["a", "b", "c"])
    }

    @Test("Only-today sessions produce a single 今天 group")
    func onlyToday() {
        let sessions = [
            session(id: "a", createdAtUtc: at(10, 0)),
            session(id: "b", createdAtUtc: at(0, 1)), // just after midnight today
        ]
        let groups = SessionListGrouping.groupSessionsByDay(
            sessions, referenceDate: referenceDate, calendar: calendar
        )
        #expect(groups.count == 1)
        #expect(groups[0].id == "today")
    }

    @Test("Midnight boundary lands in the correct day")
    func midnightBoundary() {
        // 00:00:00 today is today; 23:59:59 yesterday is yesterday.
        let sessions = [
            session(id: "todayMidnight", createdAtUtc: at(0, 0)),
            session(id: "yesterdayLate", createdAtUtc: at(23, 59, dayOffset: -1)),
        ]
        let groups = SessionListGrouping.groupSessionsByDay(
            sessions, referenceDate: referenceDate, calendar: calendar
        )
        #expect(groups.count == 2)
        #expect(groups[0].id == "today")
        #expect(groups[0].items.map(\.sessionId) == ["todayMidnight"])
        #expect(groups[1].id == "yesterday")
        #expect(groups[1].items.map(\.sessionId) == ["yesterdayLate"])
    }

    @Test("Empty buckets are dropped — never render an empty section")
    func emptyBucketsDropped() {
        // Only yesterday data → only a 昨天 group, no 今天/更早 stub.
        let sessions = [
            session(id: "y1", createdAtUtc: at(10, 0, dayOffset: -1)),
        ]
        let groups = SessionListGrouping.groupSessionsByDay(
            sessions, referenceDate: referenceDate, calendar: calendar
        )
        #expect(groups.count == 1)
        #expect(groups[0].id == "yesterday")
    }

    @Test("Group.id is unique so List sections can key off it")
    func groupIdsUnique() {
        let sessions = [
            session(id: "t", createdAtUtc: at(10, 0)),
            session(id: "y", createdAtUtc: at(10, 0, dayOffset: -1)),
            session(id: "e", createdAtUtc: at(10, 0, dayOffset: -5)),
        ]
        let groups = SessionListGrouping.groupSessionsByDay(
            sessions, referenceDate: referenceDate, calendar: calendar
        )
        let ids = groups.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    // MARK: - Display helpers

    @Test("timeOfDay formats as HH:mm in the configured locale")
    func timeOfDayFormatting() {
        // at(9,5) → 09:05
        let ms = at(9, 5)
        let label = SessionListGrouping.timeOfDay(from: ms)
        #expect(label == "09:05")
    }

    @Test("durationLabel formats milliseconds as mm:ss")
    func durationLabelFormatting() {
        #expect(SessionListGrouping.durationLabel(0) == "00:00")
        #expect(SessionListGrouping.durationLabel(59_999) == "00:59")
        #expect(SessionListGrouping.durationLabel(60_000) == "01:00")
        #expect(SessionListGrouping.durationLabel(3_661_000) == "61:01")
    }
}
