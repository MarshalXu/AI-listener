import Foundation

public struct MeetingOverview: Codable, Sendable, Equatable {
    public let title: String
    public let durationMs: Int64
    public let participantSummary: String
    public let generalSummary: String

    public init(title: String, durationMs: Int64, participantSummary: String, generalSummary: String) {
        self.title = title
        self.durationMs = durationMs
        self.participantSummary = participantSummary
        self.generalSummary = generalSummary
    }
}

public struct MinutesTopic: Codable, Sendable, Equatable, Identifiable {
    public var id: String { topicId }
    public let topicId: String
    public let title: String
    public let summary: String
    public let keyPoints: [String]

    public init(topicId: String = UUID().uuidString, title: String, summary: String, keyPoints: [String]) {
        self.topicId = topicId
        self.title = title
        self.summary = summary
        self.keyPoints = keyPoints
    }
}

public struct ActionItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { itemId }
    public let itemId: String
    public let task: String
    public let assignee: String?
    public let dueDate: String?
    public let timestampMs: Int64?

    public init(
        itemId: String = UUID().uuidString,
        task: String,
        assignee: String? = nil,
        dueDate: String? = nil,
        timestampMs: Int64? = nil
    ) {
        self.itemId = itemId
        self.task = task
        self.assignee = assignee
        self.dueDate = dueDate
        self.timestampMs = timestampMs
    }
}

public struct TimestampReference: Codable, Sendable, Equatable, Identifiable {
    public var id: String { refId }
    public let refId: String
    public let text: String
    public let startMs: Int64
    public let endMs: Int64
    public let label: String

    public init(refId: String = UUID().uuidString, text: String, startMs: Int64, endMs: Int64, label: String) {
        self.refId = refId
        self.text = text
        self.startMs = startMs
        self.endMs = endMs
        self.label = label
    }
}

public struct MeetingMinutes: Codable, Sendable, Equatable, Identifiable {
    public enum MinutesKind: String, Codable, Sendable, Equatable {
        case incremental = "incremental"
        case postSession = "post_session"
    }

    public var id: String { minutesId }
    public let minutesId: String
    public let sessionId: String
    public let kind: MinutesKind
    public let style: MinutesStyle
    public let overview: MeetingOverview
    public let coreSummary: [String]
    public let topics: [MinutesTopic]
    public let decisions: [String]
    public let actionItems: [ActionItem]
    public let unresolvedQuestions: [String]
    public let timestampReferences: [TimestampReference]
    public let createdAtUtc: Int64
    public let updatedAtUtc: Int64

    public init(
        minutesId: String = UUID().uuidString,
        sessionId: String,
        kind: MinutesKind,
        style: MinutesStyle,
        overview: MeetingOverview,
        coreSummary: [String],
        topics: [MinutesTopic],
        decisions: [String],
        actionItems: [ActionItem],
        unresolvedQuestions: [String],
        timestampReferences: [TimestampReference],
        createdAtUtc: Int64 = Int64(Date().timeIntervalSince1970),
        updatedAtUtc: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.minutesId = minutesId
        self.sessionId = sessionId
        self.kind = kind
        self.style = style
        self.overview = overview
        self.coreSummary = coreSummary
        self.topics = topics
        self.decisions = decisions
        self.actionItems = actionItems
        self.unresolvedQuestions = unresolvedQuestions
        self.timestampReferences = timestampReferences
        self.createdAtUtc = createdAtUtc
        self.updatedAtUtc = updatedAtUtc
    }
}
