import Foundation

public protocol WhiteboardAgentProtocol: Sendable {
    func generateActions(for text: String, currentNodesCount: Int) async throws -> [WhiteboardAction]
}

public final class DefaultWhiteboardAgent: WhiteboardAgentProtocol, @unchecked Sendable {
    public init() {}

    public func generateActions(for text: String, currentNodesCount: Int) async throws -> [WhiteboardAction] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var actions: [WhiteboardAction] = []
        let nodeIndex = currentNodesCount + 1
        let posX = 100.0 + Double((nodeIndex * 180) % 720)
        let posY = 100.0 + Double((nodeIndex / 4) * 120)

        // Rule / Heuristics based structured action extraction
        if trimmed.contains("流程") || trimmed.contains("步骤") || trimmed.contains("首先") || trimmed.contains("其次") {
            let stepNode = WhiteboardNode(
                id: "node_\(UUID().uuidString.prefix(8))",
                type: .flowStep,
                label: trimmed,
                x: posX,
                y: posY,
                width: 200,
                height: 80,
                backgroundColor: "#E3F2FD",
                strokeColor: "#1E88E5"
            )
            actions.append(WhiteboardAction(kind: .addFlowStep, node: stepNode))
        } else if trimmed.contains("时间") || trimmed.contains("日期") || trimmed.contains("点") {
            let timelineNode = WhiteboardNode(
                id: "node_\(UUID().uuidString.prefix(8))",
                type: .timelineEvent,
                label: trimmed,
                x: posX,
                y: posY,
                width: 180,
                height: 70,
                backgroundColor: "#FFF3E0",
                strokeColor: "#FB8C00"
            )
            actions.append(WhiteboardAction(kind: .addTimelineEvent, node: timelineNode))
        } else if trimmed.contains("待办") || trimmed.contains("任务") || trimmed.contains("负责") {
            let cardNode = WhiteboardNode(
                id: "node_\(UUID().uuidString.prefix(8))",
                type: .card,
                label: trimmed,
                x: posX,
                y: posY,
                width: 220,
                height: 100,
                backgroundColor: "#E8F5E9",
                strokeColor: "#43A047"
            )
            actions.append(WhiteboardAction(kind: .addCard, node: cardNode))
        } else {
            let defaultNode = WhiteboardNode(
                id: "node_\(UUID().uuidString.prefix(8))",
                type: .rectangle,
                label: trimmed,
                x: posX,
                y: posY,
                width: 180,
                height: 80,
                backgroundColor: "#F5F5F5",
                strokeColor: "#757575"
            )
            actions.append(WhiteboardAction(kind: .addNode, node: defaultNode))
        }

        return actions.map { WhiteboardSanitizer.sanitizeAction($0) }
    }
}
