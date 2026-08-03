import Foundation
import Testing
@testable import AIListenerCore

private struct FailingAgent: WhiteboardAgentProtocol {
    enum AgentError: Error {
        case simulatedFailure
    }
    func generateActions(for text: String, currentNodesCount: Int) async throws -> [WhiteboardAction] {
        throw AgentError.simulatedFailure
    }
}

struct WhiteboardServiceTests {
    @Test func testWhiteboardServiceIncrementalUpdatesAndState() async {
        let service = WhiteboardService()

        await service.handleFinalizedText("首先讨论第一个流程步骤")

        #expect(service.nodes.count > 0)
        #expect(service.nodes.first?.type == .flowStep)

        // Test Undo & Redo
        let countBeforeUndo = service.nodes.count
        service.undo()
        #expect(service.nodes.count < countBeforeUndo)

        service.redo()
        #expect(service.nodes.count == countBeforeUndo)

        // Test Pause & Resume
        service.pause()
        #expect(service.isPaused == true)

        await service.handleFinalizedText("第二个时间节点")

        // Should not add nodes while paused
        #expect(service.nodes.count == countBeforeUndo)

        service.resume()
        #expect(service.isPaused == false)

        // Test Snapshot generation and loading
        let snapshot = service.generateSnapshot(sessionId: "sess_test")
        #expect(snapshot.sessionId == "sess_test")
        #expect(snapshot.elementsJSON.contains("node_") == true)

        service.clear()
        #expect(service.nodes.isEmpty)

        service.loadSnapshot(snapshot)
        #expect(service.nodes.count == countBeforeUndo)
    }

    @Test func testFaultIsolationAgentFailureDoesNotCrashService() async {
        let failingService = WhiteboardService(agent: FailingAgent())
        await failingService.handleFinalizedText("一些文本")

        #expect(failingService.lastDiagnosticCode?.contains("AGENT_GENERATION_FAILED") == true)
        #expect(failingService.nodes.isEmpty)
    }
}
