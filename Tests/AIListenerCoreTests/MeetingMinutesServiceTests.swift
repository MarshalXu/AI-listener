import Foundation
import Testing
@testable import AIListenerCore

@Suite(.serialized)
struct MeetingMinutesServiceTests {
    private func databaseURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: ".test-artifacts", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "session.sqlite")
    }

    private func createSession(store: SessionStore, id: String) throws {
        let record = SessionRecord(
            sessionId: id, state: "recording", transcriptState: "active",
            createdAtUtc: 1, captureStartMonotonicNs: 2
        )
        try store.insertSession(record)
    }

    private func sampleSegment(sessionId: String, seq: Int64, startMs: Int64) -> TranscriptSegmentRecord {
        TranscriptSegmentRecord(
            segmentId: UUID().uuidString,
            sessionId: sessionId,
            revisionOf: nil,
            status: "finalized",
            sequence: seq,
            revision: 0,
            startMs: startMs,
            endMs: startMs + 3000,
            text: "测试 Segment \(seq)",
            createdMonotonicMs: startMs,
            engineId: "sherpa",
            engineModelVersion: "v1"
        )
    }

    @Test func serviceGeneratesIncrementalAndPostSessionMinutes() async throws {
        let url = try databaseURL()
        let store = try SessionStore(databaseURL: url)
        let sessionId = UUID().uuidString
        try createSession(store: store, id: sessionId)

        let mockClient = MockGeminiClient()
        let defaults = UserDefaults(suiteName: "ServiceTest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        privacyStore.saveSettings(PrivacySettings(aiMode: .incrementalAndPost, aiModel: .localMock))

        let service = MeetingMinutesService(
            client: mockClient,
            sessionStore: store,
            privacySettingsStore: privacyStore
        )

        await service.startSession(sessionId: sessionId)
        let initialStatus = await service.status
        #expect(initialStatus == .active)

        // Send 3 finalized segments -> triggers incremental update
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 2, startMs: 5000))
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 3, startMs: 9000))

        let latest = await service.latestMinutes
        #expect(latest != nil)
        #expect(latest?.kind == .incremental)

        let finalMinutes = await service.finishSession(sessionId: sessionId)
        #expect(finalMinutes != nil)
        #expect(finalMinutes?.kind == .postSession)

        let fetched = try store.fetchMeetingMinutes(sessionId: sessionId, kind: .postSession)
        #expect(fetched != nil)
        #expect(fetched?.sessionId == sessionId)
    }

    @Test func faultIsolationClientErrorDegradesStatusWithoutCrashing() async throws {
        let mockClient = MockGeminiClient(shouldFail: true)
        let defaults = UserDefaults(suiteName: "ServiceTest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        privacyStore.saveSettings(PrivacySettings(aiMode: .incrementalAndPost, aiModel: .localMock))

        let service = MeetingMinutesService(
            client: mockClient,
            privacySettingsStore: privacyStore
        )

        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)

        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 2, startMs: 5000))
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 3, startMs: 9000))

        let degradedStatus = await service.status
        if case .degraded(let reason) = degradedStatus {
            #expect(!reason.isEmpty)
        } else {
            Issue.record("Expected degraded status on client failure")
        }

        let result = await service.finishSession(sessionId: sessionId)
        #expect(result == nil)
    }

    // MARK: - Degradation reasons when the configuration is incomplete

    private func serviceWith(
        settings: PrivacySettings,
        keychainManager: KeychainManager = KeychainManager(serviceName: "ai.listener.test.\(UUID().uuidString)")
    ) -> MeetingMinutesService {
        let defaults = UserDefaults(suiteName: "ServiceTest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        privacyStore.saveSettings(settings)
        return MeetingMinutesService(
            client: MockGeminiClient(),
            privacySettingsStore: privacyStore,
            keychainManager: keychainManager
        )
    }

    @Test func degradedReasonWhenAiModeOff() async {
        let service = serviceWith(settings: PrivacySettings(aiMode: .off, aiModel: .localMock))
        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))

        let status = await service.status
        #expect(status == .degraded(reason: "AI 已关闭：请在设置中开启 AI 模式以生成纪要。"))
    }

    @Test func degradedReasonWhenCloudConsentMissing() async {
        let service = serviceWith(settings: PrivacySettings(
            aiMode: .incrementalAndPost, aiModel: .gemini, cloudConsentGranted: false
        ))
        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))

        let reason = await service.status.degradationReason ?? ""
        #expect(reason.contains("未授权云端处理"))
    }

    @Test func degradedReasonWhenApiKeyMissing() async {
        let service = serviceWith(settings: PrivacySettings(
            aiMode: .incrementalAndPost, aiModel: .gemini, cloudConsentGranted: true
        ))
        // No API key stored in the keychain for this test actor, so
        // KeychainManager.shared.getApiKey() will fail and hasKey == false.
        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))

        let reason = await service.status.degradationReason ?? ""
        #expect(reason.contains("API Key"))
    }

    @Test func finishSessionReturnsNilWithDegradedReasonWhenUnconfigured() async {
        let service = serviceWith(settings: PrivacySettings(aiMode: .off, aiModel: .localMock))
        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))

        let result = await service.finishSession(sessionId: sessionId)
        #expect(result == nil)

        let reason = await service.status.degradationReason ?? ""
        #expect(reason.contains("AI 已关闭"))
    }
}
