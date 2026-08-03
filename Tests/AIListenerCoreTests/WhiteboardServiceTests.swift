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

    // MARK: - AC2.1 — flushBatcher before snapshot

    /// AC2.1 — after flushBatcher, a pending finalized text must be reflected
    /// in the snapshot's elements. This mirrors the stop() ordering fix.
    @Test func testFlushBatcherDrainsPendingTextIntoSnapshot() async throws {
        // Use a batcher with a high threshold so items stay buffered until
        // an explicit flush.
        let config = TranscriptBatcher<ASRTranscriptEvent>.Configuration(
            maxCount: 100, idleTimeout: 600, maxWaitTimeout: 600
        )
        let service = WhiteboardService(agent: DefaultWhiteboardAgent(), batcherConfig: config)

        // Simulate a finalized event that the batcher holds pending.
        let event = ASRTranscriptEvent(
            segmentId: UUID().uuidString,
            sessionId: "sess",
            status: .finalized,
            sequence: 1,
            revision: 0,
            startMs: 0,
            endMs: 1000,
            text: "首先讨论项目进度，其次规划下周任务",
            createdMonotonicMs: 0,
            engineId: "sherpa",
            engineModelVersion: "v1"
        )
        // Feed it directly via append on the batcher.
        service.flushBatcher() // no-op when empty, ensures timers cancelled
        // We exercise the flush path by appending then flushing.
        // The batcher is private; use the bus to deliver finalized events.
        let bus = TranscriptEventBus()
        service.subscribeToBus(bus)
        bus.publishFinalized(event)

        // The batcher buffers the event; it should not yet be in nodes.
        // Give the bus dispatch a tick to deliver to the subscriber.
        try await Task.sleep(nanoseconds: 50_000_000)
        let nodesBeforeFlush = service.nodes.count
        // It may or may not have flushed yet depending on timing; either way
        // the flush below must drain remaining buffer.
        _ = nodesBeforeFlush

        service.flushBatcher()
        // flush() enqueues a Task to handleFinalizedText; yield to let it run.
        try await Task.sleep(nanoseconds: 150_000_000)

        let snapshot = service.generateSnapshot(sessionId: "sess")
        #expect(snapshot.elementsJSON.contains("node_") == true)
        #expect(service.nodes.count > 0)
    }

    // MARK: - AC2.2 — connections round-trip

    /// AC2.2 — generateSnapshot → loadSnapshot must preserve connections.
    @Test func testSnapshotRoundTripsNodesAndConnections() async throws {
        let service = WhiteboardService(agent: DefaultWhiteboardAgent(), batcherConfig: nil)

        // Produce structured nodes + connections via the enhanced agent.
        await service.handleFinalizedText("首先讨论项目进度，其次规划下周任务，最后确认时间节点")

        let nodesBefore = service.nodes
        let connectionsBefore = service.connections

        #expect(!nodesBefore.isEmpty)
        #expect(!connectionsBefore.isEmpty)

        let snapshot = service.generateSnapshot(sessionId: "sess_rt")

        // Snapshot JSON must carry both nodes and connections.
        #expect(snapshot.elementsJSON.contains("\"nodes\"") == true)
        #expect(snapshot.elementsJSON.contains("\"connections\"") == true)

        // Clear and reload — the state must be restored faithfully.
        service.clear()
        #expect(service.nodes.isEmpty)
        #expect(service.connections.isEmpty)

        service.loadSnapshot(snapshot)

        #expect(service.nodes.count == nodesBefore.count)
        #expect(service.connections.count == connectionsBefore.count)

        // Connection endpoints must survive the round-trip.
        let reloadedConnIds = Set(service.connections.map { $0.id })
        let originalConnIds = Set(connectionsBefore.map { $0.id })
        #expect(reloadedConnIds == originalConnIds)
    }

    /// AC2.2 — legacy snapshots that stored only a nodes array must still load.
    @Test func testLoadLegacyNodesOnlySnapshot() async throws {
        let service = WhiteboardService(agent: DefaultWhiteboardAgent(), batcherConfig: nil)
        let legacyJSON = "[{\"id\":\"node_legacy1\",\"type\":\"rectangle\",\"label\":\"legacy\",\"x\":10,\"y\":20,\"width\":160,\"height\":80}]"
        let snapshot = WhiteboardSnapshot(
            snapshotId: "snap_legacy",
            sessionId: UUID().uuidString,
            elementsJSON: legacyJSON,
            appStateJSON: "{}"
        )
        service.loadSnapshot(snapshot)
        #expect(service.nodes.count == 1)
        #expect(service.nodes.first?.id == "node_legacy1")
        #expect(service.connections.isEmpty)
    }

    // MARK: - AC2.3 — persistence failure observability (store-level)

    /// AC2.3 — saveWhiteboardSnapshot must throw on an invalid sessionId so
    /// callers cannot silently swallow failures. The app's stop() now catches
    /// and surfaces this as pipelineErrorCode.
    @Test func testSaveWhiteboardSnapshotThrowsOnInvalidSessionId() throws {
        let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appending(path: "test_ac23.sqlite")
        let store = try SessionStore(databaseURL: dbURL)

        let badSnapshot = WhiteboardSnapshot(
            snapshotId: "snap_bad",
            sessionId: "not-a-uuid",
            elementsJSON: "[]",
            appStateJSON: "{}"
        )

        #expect(throws: SessionStoreError.self) {
            try store.saveWhiteboardSnapshot(badSnapshot)
        }
    }
}
