import Foundation

/// Pure helpers that bucket the playable-session list into human-friendly day
/// groups ("今天" / "昨天" / absolute date). Kept free of SwiftUI and of
/// `Calendar.current` *reads that mutate state* so they are unit-testable; the
/// only live input is the wall clock, which tests pin via `referenceDate`.
public enum SessionListGrouping {

    /// A dated bucket of sessions, ready to render as a `List` section.
    public struct Group: Sendable, Equatable, Identifiable {
        public let id: String
        public let label: String
        public let items: [SessionListItem]

        public init(id: String, label: String, items: [SessionListItem]) {
            self.id = id
            self.label = label
            self.items = items
        }
    }

    /// Splits `sessions` (expected already sorted newest-first, matching
    /// `SessionStore.listPlayableSessions()`) into up to three ordered groups:
    /// today, yesterday, and everything earlier. Empty buckets are dropped so
    /// the UI never renders an empty section.
    ///
    /// `referenceDate` is injectable for deterministic tests; it defaults to
    /// `Date()` so production callers don't need to pass anything.
    public static func groupSessionsByDay(
        _ sessions: [SessionListItem],
        referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> [Group] {
        guard !sessions.isEmpty else { return [] }

        let startOfToday = calendar.startOfDay(for: referenceDate)
        let startOfYesterday =
            calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_Hans_CN")
        dateFormatter.dateFormat = "M月d日"

        var today: [SessionListItem] = []
        var yesterday: [SessionListItem] = []
        var earlier: [SessionListItem] = []

        for session in sessions {
            let date = Date(timeIntervalSince1970: Double(session.createdAtUtc) / 1_000)
            let startOfDay = calendar.startOfDay(for: date)
            if startOfDay == startOfToday {
                today.append(session)
            } else if startOfDay == startOfYesterday {
                yesterday.append(session)
            } else {
                earlier.append(session)
            }
        }

        var groups: [Group] = []
        if !today.isEmpty {
            groups.append(Group(id: "today", label: "今天", items: today))
        }
        if !yesterday.isEmpty {
            groups.append(Group(id: "yesterday", label: "昨天", items: yesterday))
        }
        if !earlier.isEmpty {
            groups.append(Group(id: "earlier", label: "更早", items: earlier))
        }
        return groups
    }

    /// Formats a session's creation instant (stored as UTC milliseconds) as a
    /// locale-appropriate wall-clock `HH:mm`. Shared by the list row and any
    /// other surface that needs the same display value.
    public static func timeOfDay(from createdAtUtc: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(createdAtUtc) / 1_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    /// Formats a duration (milliseconds) as `mm:ss`, matching the existing
    /// `duration(_:)` helper that lived inline in `SessionLibraryView`.
    public static func durationLabel(_ durationMs: Int64) -> String {
        String(format: "%02lld:%02lld", durationMs / 60_000, (durationMs / 1_000) % 60)
    }
}
