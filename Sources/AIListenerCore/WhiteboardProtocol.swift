import Foundation

public struct WhiteboardContract {
    public static let version = "ai-listener.contracts/1.0"
}

public enum WhiteboardNodeType: String, Codable, Sendable, CaseIterable {
    case rectangle
    case ellipse
    case diamond
    case text
    case card
    case flowStep
    case timelineEvent
}

public enum WhiteboardActionKind: String, Codable, Sendable, CaseIterable {
    case addNode
    case updateNode
    case deleteNode
    case connectNodes
    case addFlowStep
    case addTimelineEvent
    case addCard
    case clear
    case loadSnapshot
}

public struct WhiteboardNode: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: WhiteboardNodeType
    public var label: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var backgroundColor: String?
    public var strokeColor: String?
    public var metadata: [String: String]?

    public init(
        id: String = UUID().uuidString,
        type: WhiteboardNodeType,
        label: String,
        x: Double,
        y: Double,
        width: Double = 160.0,
        height: Double = 80.0,
        backgroundColor: String? = nil,
        strokeColor: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.id = id
        self.type = type
        self.label = label
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.backgroundColor = backgroundColor
        self.strokeColor = strokeColor
        self.metadata = metadata
    }
}

public struct WhiteboardConnection: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let fromNodeId: String
    public let toNodeId: String
    public var label: String?

    public init(
        id: String = UUID().uuidString,
        fromNodeId: String,
        toNodeId: String,
        label: String? = nil
    ) {
        self.id = id
        self.fromNodeId = fromNodeId
        self.toNodeId = toNodeId
        self.label = label
    }
}

public struct WhiteboardSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let snapshotId: String
    public let sessionId: String
    public var elementsJSON: String
    public var appStateJSON: String
    public let createdAtUTC: Int64
    public var updatedAtUTC: Int64

    public var id: String { snapshotId }

    public init(
        snapshotId: String = UUID().uuidString,
        sessionId: String,
        elementsJSON: String = "[]",
        appStateJSON: String = "{}",
        createdAtUTC: Int64 = Int64(Date().timeIntervalSince1970),
        updatedAtUTC: Int64 = Int64(Date().timeIntervalSince1970)
    ) {
        self.snapshotId = snapshotId
        self.sessionId = sessionId
        self.elementsJSON = elementsJSON
        self.appStateJSON = appStateJSON
        self.createdAtUTC = createdAtUTC
        self.updatedAtUTC = updatedAtUTC
    }
}

public struct WhiteboardAction: Codable, Sendable, Equatable {
    public let kind: WhiteboardActionKind
    public var node: WhiteboardNode?
    public var connection: WhiteboardConnection?
    public var nodeId: String?
    public var snapshot: WhiteboardSnapshot?

    public init(
        kind: WhiteboardActionKind,
        node: WhiteboardNode? = nil,
        connection: WhiteboardConnection? = nil,
        nodeId: String? = nil,
        snapshot: WhiteboardSnapshot? = nil
    ) {
        self.kind = kind
        self.node = node
        self.connection = connection
        self.nodeId = nodeId
        self.snapshot = snapshot
    }
}

public struct WhiteboardSanitizer: Sendable {
    private static let dangerousPatterns: [String] = [
        "<script", "</script>", "javascript:", "onload=", "onerror=",
        "onclick=", "onmouseover=", "<iframe", "document.cookie"
    ]

    public static func sanitizeText(_ text: String) -> String {
        var clean = text
        for pattern in dangerousPatterns {
            clean = clean.replacingOccurrences(of: pattern, with: "", options: .caseInsensitive)
        }
        // Basic escaping of raw < and > to avoid html injection in WebView
        clean = clean.replacingOccurrences(of: "<", with: "&lt;")
                     .replacingOccurrences(of: ">", with: "&gt;")
        return clean
    }

    public static func sanitizeNode(_ node: WhiteboardNode) -> WhiteboardNode {
        var sanitized = node
        sanitized.label = sanitizeText(node.label)
        if let meta = node.metadata {
            var cleanMeta: [String: String] = [:]
            for (k, v) in meta {
                cleanMeta[sanitizeText(k)] = sanitizeText(v)
            }
            sanitized.metadata = cleanMeta
        }
        return sanitized
    }

    public static func sanitizeAction(_ action: WhiteboardAction) -> WhiteboardAction {
        var sanitized = action
        if let node = action.node {
            sanitized.node = sanitizeNode(node)
        }
        if let conn = action.connection {
            var cleanConn = conn
            if let label = conn.label {
                cleanConn.label = sanitizeText(label)
            }
            sanitized.connection = cleanConn
        }
        return sanitized
    }
}
