import Testing
import Foundation
import AVFoundation
@testable import AIListenerCore

@Suite(.serialized)
struct EndToEndIntegrationAndFaultIsolationTests {
    private func databaseURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".test-artifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "session.sqlite")
    }

    private func assetRootURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".test-artifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeSegment(sessionId: String, seq: Int64, startMs: Int64, text: String) -> TranscriptSegmentRecord {
        TranscriptSegmentRecord(
            segmentId: UUID().uuidString,
            sessionId: sessionId,
            revisionOf: nil,
            status: "finalized",
            sequence: seq,
            revision: 0,
            startMs: startMs,
            endMs: startMs + 2000,
            text: text,
            createdMonotonicMs: startMs,
            engineId: "sherpa",
            engineModelVersion: "v1"
        )
    }

    private func makeEvent(sessionId: String, seq: Int64, startMs: Int64, text: String) -> ASRTranscriptEvent {
        ASRTranscriptEvent(
            segmentId: UUID().uuidString,
            sessionId: sessionId,
            status: .finalized,
            sequence: seq,
            revision: 0,
            startMs: startMs,
            endMs: startMs + 2000,
            text: text,
            createdMonotonicMs: startMs,
            engineId: "sherpa",
            engineModelVersion: "v1"
        )
    }

    // MARK: - Test 1: Full End-to-End Pipeline & Reopen Verification
    @Test func testEndToEndPipelineAndPersistenceReopen() async throws {
        let dbURL = try databaseURL()
        let assetRoot = try assetRootURL()
        let store = try SessionStore(databaseURL: dbURL)
        let eventBus = TranscriptEventBus()

        let mockEngine = MockASREngine()
        let pipeline = try RecordingSessionPipeline(
            store: store,
            assetRoot: assetRoot,
            engine: mockEngine,
            eventBus: eventBus
        )

        let defaults = UserDefaults(suiteName: "E2ETest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        privacyStore.saveSettings(PrivacySettings(aiMode: .incrementalAndPost, aiModel: .localMock, cloudConsentGranted: true))

        let mockGemini = MockGeminiClient()
        let minutesService = MeetingMinutesService(
            client: mockGemini,
            sessionStore: store,
            privacySettingsStore: privacyStore
        )
        await minutesService.startSession(sessionId: pipeline.sessionId)

        let whiteboardService = WhiteboardService(
            agent: DefaultWhiteboardAgent(),
            batcherConfig: nil
        )
        whiteboardService.subscribeToBus(eventBus)

        // Subtitle bus observer
        let receivedCount = SubtitleCounter()
        let busSub = eventBus.subscribe { event in
            if case .finalized = event {
                receivedCount.increment()
            }
        }

        // Feed Audio Frame
        let frameFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: frameFormat, frameCapacity: 1600)!
        pcmBuffer.frameLength = 1600
        let frame = AudioFrame(buffer: pcmBuffer, monotonicNanoseconds: 100_000_000)

        try pipeline.consume(frame)

        // Publish finalized events onto bus & send to minutes service
        let e1 = makeEvent(sessionId: pipeline.sessionId, seq: 1, startMs: 1000, text: "Welcome to AI Listener team meeting")
        let e2 = makeEvent(sessionId: pipeline.sessionId, seq: 2, startMs: 4000, text: "Today we discuss architecture design")
        let e3 = makeEvent(sessionId: pipeline.sessionId, seq: 3, startMs: 7000, text: "Decisions include fault isolation for all services")

        eventBus.publishFinalized(e1)
        eventBus.publishFinalized(e2)
        eventBus.publishFinalized(e3)

        let s1 = makeSegment(sessionId: pipeline.sessionId, seq: 1, startMs: 1000, text: e1.text)
        let s2 = makeSegment(sessionId: pipeline.sessionId, seq: 2, startMs: 4000, text: e2.text)
        let s3 = makeSegment(sessionId: pipeline.sessionId, seq: 3, startMs: 7000, text: e3.text)

        await minutesService.handleFinalizedSegment(s1)
        await minutesService.handleFinalizedSegment(s2)
        await minutesService.handleFinalizedSegment(s3)

        whiteboardService.flushBatcher()

        // Finish session
        let minutes = await minutesService.finishSession(sessionId: pipeline.sessionId)
        #expect(minutes != nil)

        let audioAsset = try pipeline.finish()
        #expect(audioAsset.sessionId == pipeline.sessionId)

        let snapshot = WhiteboardSnapshot(
            snapshotId: "snap_\(pipeline.sessionId)",
            sessionId: pipeline.sessionId,
            elementsJSON: "[{\"id\":\"node_1\",\"type\":\"rectangle\"}]",
            appStateJSON: "{\"viewBackgroundColor\":\"#ffffff\"}"
        )
        try store.saveWhiteboardSnapshot(snapshot)

        try await Task.sleep(nanoseconds: 50_000_000)
        busSub.cancel()

        #expect(receivedCount.value == 3)

        // Reopen database store and verify persistence
        let reopenedStore = try SessionStore(databaseURL: dbURL)
        let playable = try reopenedStore.listPlayableSessions()
        #expect(playable.count == 1)
        #expect(playable.first?.sessionId == pipeline.sessionId)

        let loadedMinutes = try reopenedStore.fetchMeetingMinutes(sessionId: pipeline.sessionId, kind: .postSession)
        #expect(loadedMinutes != nil)
        #expect(loadedMinutes?.sessionId == pipeline.sessionId)

        let loadedSnapshot = try reopenedStore.fetchWhiteboardSnapshot(sessionId: pipeline.sessionId)
        #expect(loadedSnapshot != nil)
        #expect(loadedSnapshot?.sessionId == pipeline.sessionId)
        #expect(loadedSnapshot?.elementsJSON.contains("node_1") == true)
    }

    // MARK: - Test 2: Fault Isolation - Network Failure / Gemini Error
    @Test func testFaultIsolationNetworkFailureDoesNotImpactRecordingOrASR() async throws {
        let dbURL = try databaseURL()
        let store = try SessionStore(databaseURL: dbURL)
        let eventBus = TranscriptEventBus()

        let defaults = UserDefaults(suiteName: "FaultTest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        privacyStore.saveSettings(PrivacySettings(aiMode: .incrementalAndPost, aiModel: .gemini, cloudConsentGranted: true))

        let keychain = KeychainManager(serviceName: "ai.listener.test-keychain-\(UUID().uuidString)")
        try keychain.saveApiKey("dummy-api-key")
        defer { try? keychain.deleteApiKey() }

        let failingClient = MockGeminiClient(shouldFail: true)
        let minutesService = MeetingMinutesService(
            client: failingClient,
            sessionStore: store,
            privacySettingsStore: privacyStore,
            keychainManager: keychain
        )
        await minutesService.startSession(sessionId: "fault-session-1")

        // Feed segments
        let s1 = makeSegment(sessionId: "fault-session-1", seq: 1, startMs: 1000, text: "Seg 1")
        let s2 = makeSegment(sessionId: "fault-session-1", seq: 2, startMs: 4000, text: "Seg 2")
        let s3 = makeSegment(sessionId: "fault-session-1", seq: 3, startMs: 7000, text: "Seg 3")

        await minutesService.handleFinalizedSegment(s1)
        await minutesService.handleFinalizedSegment(s2)
        await minutesService.handleFinalizedSegment(s3)

        // Verify status degraded gracefully without throwing exception or crashing
        let status = await minutesService.status
        if case .degraded(let reason) = status {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("Expected service status to be degraded, got \(status)")
        }

        // Verify event bus continues functioning
        let counter = SubtitleCounter()
        let sub = eventBus.subscribe { event in
            if case .finalized = event { counter.increment() }
        }
        let testEvent = makeEvent(sessionId: "fault-session-1", seq: 4, startMs: 10000, text: "ASR continues working")
        eventBus.publishFinalized(testEvent)

        try await Task.sleep(nanoseconds: 50_000_000)
        sub.cancel()

        #expect(counter.value == 1)
    }

    // MARK: - Test 3: Fault Isolation - Whiteboard Agent Error
    @Test func testFaultIsolationWhiteboardAgentErrorDoesNotCrashApp() async throws {
        struct FailingWhiteboardAgent: WhiteboardAgentProtocol {
            func generateActions(for text: String, currentNodesCount: Int) async throws -> [WhiteboardAction] {
                throw NSError(domain: "WhiteboardAgentError", code: 500, userInfo: [NSLocalizedDescriptionKey: "Model generation failed"])
            }
        }

        let whiteboardService = WhiteboardService(agent: FailingWhiteboardAgent(), batcherConfig: nil)
        await whiteboardService.handleFinalizedText("Trigger whiteboard agent error")

        #expect(whiteboardService.lastDiagnosticCode != nil)
        #expect(whiteboardService.lastDiagnosticCode?.contains("AGENT_GENERATION_FAILED") == true)
        #expect(whiteboardService.nodes.count == 0)
    }

    // MARK: - Test 4: Offline / Flight Mode Verification
    @Test func testOfflineRecordingASRAndPersistence() throws {
        let dbURL = try databaseURL()
        let assetRoot = try assetRootURL()
        let store = try SessionStore(databaseURL: dbURL)
        let mockEngine = MockASREngine()

        let pipeline = try RecordingSessionPipeline(
            store: store,
            assetRoot: assetRoot,
            engine: mockEngine
        )

        let frameFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: frameFormat, frameCapacity: 1600)!
        pcmBuffer.frameLength = 1600
        let frame = AudioFrame(buffer: pcmBuffer, monotonicNanoseconds: 100_000_000)

        #expect(throws: Never.self) {
            try pipeline.consume(frame)
        }
        let asset = try pipeline.finish()

        #expect(FileManager.default.fileExists(atPath: assetRoot.appending(path: asset.relativePath).path))
        let playable = try store.listPlayableSessions()
        #expect(playable.count == 1)
        #expect(playable.first?.sessionId == pipeline.sessionId)
    }

    // MARK: - Regression: sessionId consistency prevents FK failure on stop
    // XUC-9 — `CaptureViewModel.start()` previously generated a sessionId,
    // stored it in `currentSessionId`, but did NOT pass it to
    // `RecordingSessionPipeline.init`, which then used its default
    // `UUID().uuidString` for the `sessions` row. At stop time
    // `saveWhiteboardSnapshot` was called with the original sessionId,
    // violating the `whiteboard_snapshots.session_id → sessions.id` FK
    // and raising sqlite code 19. This test pins the contract the fix
    // relies on: an explicitly-passed sessionId is the one the pipeline
    // exposes and persists, and a snapshot saved with that same id does
    // not throw after the session row exists.
    @Test func testPipelineSessionIdIsConsistentAndSnapshotSaveDoesNotViolateForeignKey() throws {
        let dbURL = try databaseURL()
        let assetRoot = try assetRootURL()
        let store = try SessionStore(databaseURL: dbURL)
        let mockEngine = MockASREngine()

        // Caller generates a sessionId (mirrors CaptureViewModel.start()).
        let callerSessionId = UUID().uuidString

        // The fix: pass sessionId explicitly. Without it, the pipeline would
        // generate a *different* id internally (the default argument).
        let pipeline = try RecordingSessionPipeline(
            store: store,
            assetRoot: assetRoot,
            engine: mockEngine,
            sessionId: callerSessionId
        )

        // The pipeline must expose the caller's id, not a fresh one.
        #expect(pipeline.sessionId == callerSessionId)

        // Feed one audio frame so finish() has audio to commit; this also
        // inserts the sessions row via AtomicAudioAssetWriter.begin.
        let frameFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: frameFormat, frameCapacity: 1600)!
        pcmBuffer.frameLength = 1600
        let frame = AudioFrame(buffer: pcmBuffer, monotonicNanoseconds: 100_000_000)
        try pipeline.consume(frame)
        _ = try pipeline.finish()

        // The sessions row must exist with the caller's id; otherwise the
        // FK on whiteboard_snapshots would fail (the original bug).
        #expect(try store.sessionState(sessionId: callerSessionId) != nil)

        // Saving a snapshot with the same sessionId must not throw an FK
        // error. Before the fix this raised sqlite code 19.
        let snapshot = WhiteboardSnapshot(
            snapshotId: "snap_\(callerSessionId)",
            sessionId: callerSessionId,
            elementsJSON: "[{\"id\":\"node_1\",\"type\":\"rectangle\"}]",
            appStateJSON: "{\"viewBackgroundColor\":\"#ffffff\"}"
        )
        #expect(throws: Never.self) {
            try store.saveWhiteboardSnapshot(snapshot)
        }

        let fetched = try store.fetchWhiteboardSnapshot(sessionId: callerSessionId)
        #expect(fetched?.sessionId == callerSessionId)
    }
}

// MARK: - Helpers
private final class MockASREngine: LocalStreamingASREngine, @unchecked Sendable {
    func accept(_ frame: ASRInputFrame) throws -> [ASRTranscriptEvent] {
        return []
    }
    func finish() throws -> [ASRTranscriptEvent] {
        return []
    }
}

private final class SubtitleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var value: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}
