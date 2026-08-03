import Foundation
import Testing
@testable import AIListenerCore

struct WhiteboardAgentTests {
    /// AC1.1 — node label must be a concise extraction, not the raw input text.
    @Test func testNodeLabelIsNotRawText() async throws {
        let agent = DefaultWhiteboardAgent()
        let raw = "接下来讨论项目进度，第一阶段已完成原型，第二阶段计划下周开始"
        let actions = try await agent.generateActions(for: raw, currentNodesCount: 0)

        #expect(!actions.isEmpty)

        let nodeActions = actions.filter {
            [.addNode, .addCard, .addFlowStep, .addTimelineEvent].contains($0.kind)
        }
        #expect(!nodeActions.isEmpty)

        for action in nodeActions {
            let label = action.node?.label ?? ""
            // Label must not equal the raw input (AC1.1).
            #expect(label != raw)
            // Label must be shorter than the raw input.
            #expect(label.count < raw.count)
            // Label must be non-empty.
            #expect(!label.isEmpty)
        }
    }

    /// AC1.2 — multi-point inputs must produce connectNodes actions linking
    /// produced nodes.
    @Test func testMultiPointInputProducesConnectNodes() async throws {
        let agent = DefaultWhiteboardAgent()
        let raw = "首先讨论项目进度，其次规划下周任务，最后确认时间节点"
        let actions = try await agent.generateActions(for: raw, currentNodesCount: 0)

        // There must be at least one connectNodes action.
        let connectActions = actions.filter { $0.kind == .connectNodes }
        #expect(!connectActions.isEmpty)

        // Every connection must reference node ids that were actually produced.
        let producedNodeIds = Set(actions.compactMap { $0.node?.id })
        #expect(!producedNodeIds.isEmpty)

        for conn in connectActions {
            let conn = try #require(conn.connection)
            #expect(producedNodeIds.contains(conn.fromNodeId))
            #expect(producedNodeIds.contains(conn.toNodeId))
            #expect(conn.fromNodeId != conn.toNodeId)
        }
    }

    /// AC1.1 — even a single-sentence input must produce a label shorter than
    /// the raw text.
    @Test func testSingleSentenceLabelShorterThanRaw() async throws {
        let agent = DefaultWhiteboardAgent()
        let raw = "今天天气很好，我们一起去公园散步"
        let actions = try await agent.generateActions(for: raw, currentNodesCount: 0)

        let nodeActions = actions.filter {
            [.addNode, .addCard, .addFlowStep, .addTimelineEvent].contains($0.kind)
        }
        #expect(!nodeActions.isEmpty)

        if let label = nodeActions.first?.node?.label {
            #expect(label != raw)
            #expect(label.count < raw.count)
        }
    }

    /// Empty input must produce no actions.
    @Test func testEmptyInputProducesNoActions() async throws {
        let agent = DefaultWhiteboardAgent()
        let actions = try await agent.generateActions(for: "   ", currentNodesCount: 0)
        #expect(actions.isEmpty)
    }

    /// Sanity: the agent still produces nodes for a short single point.
    @Test func testProducesAtLeastOneNode() async throws {
        let agent = DefaultWhiteboardAgent()
        let raw = "项目进度讨论"
        let actions = try await agent.generateActions(for: raw, currentNodesCount: 0)
        let nodeActions = actions.filter {
            [.addNode, .addCard, .addFlowStep, .addTimelineEvent].contains($0.kind)
        }
        #expect(!nodeActions.isEmpty)
    }
}
