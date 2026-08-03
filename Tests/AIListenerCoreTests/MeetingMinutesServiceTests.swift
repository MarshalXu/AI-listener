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

    // MARK: Degradation reason surfacing (RD-2 scope)

    /// A fresh KeychainManager with a unique service name guarantees no API
    /// key is present, so tests don't touch or depend on the real keychain.
    private func emptyKeychain() -> KeychainManager {
        KeychainManager(serviceName: "ai.listener.tests.\(UUID().uuidString)")
    }

    @Test func degradedReasonWhenAiModeOff() async throws {
        let defaults = UserDefaults(suiteName: "ServiceTest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        privacyStore.saveSettings(PrivacySettings(aiMode: .off, aiModel: .gemini,
                                                  cloudConsentGranted: true))

        let service = MeetingMinutesService(
            client: MockGeminiClient(),
            privacySettingsStore: privacyStore,
            keychainManager: emptyKeychain()
        )

        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)
        // Three segments would normally trigger incremental; with AI off we
        // expect a degraded status carrying the "AI 已关闭" reason instead.
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 2, startMs: 5000))
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 3, startMs: 9000))

        let status = await service.status
        try #require(status.degradationReason != nil, "expected degraded status when AI mode off")
        #expect(status.degradationReason!.contains("AI 已关闭"))
    }

    @Test func degradedReasonWhenCloudConsentMissing() async throws {
        let defaults = UserDefaults(suiteName: "ServiceTest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        privacyStore.saveSettings(PrivacySettings(aiMode: .incrementalAndPost,
                                                  aiModel: .gemini,
                                                  cloudConsentGranted: false))

        let service = MeetingMinutesService(
            client: MockGeminiClient(),
            privacySettingsStore: privacyStore,
            keychainManager: emptyKeychain()
        )

        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))

        let status = await service.status
        try #require(status.degradationReason != nil)
        #expect(status.degradationReason!.contains("未授权云端处理"))
    }

    @Test func degradedReasonWhenApiKeyMissing() async throws {
        let defaults = UserDefaults(suiteName: "ServiceTest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        // Cloud consent granted, but no key is present (emptyKeychain).
        privacyStore.saveSettings(PrivacySettings(aiMode: .incrementalAndPost,
                                                  aiModel: .gemini,
                                                  cloudConsentGranted: true))

        let service = MeetingMinutesService(
            client: MockGeminiClient(),
            privacySettingsStore: privacyStore,
            keychainManager: emptyKeychain()
        )

        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))

        let status = await service.status
        try #require(status.degradationReason != nil)
        #expect(status.degradationReason!.contains("API Key"))
    }

    @Test func finishSessionReturnsNilWithDegradedReasonWhenUnconfigured() async throws {
        let defaults = UserDefaults(suiteName: "ServiceTest_\(UUID().uuidString)")!
        let privacyStore = PrivacySettingsStore(userDefaults: defaults)
        privacyStore.saveSettings(PrivacySettings(aiMode: .off, aiModel: .gemini,
                                                  cloudConsentGranted: true))

        let service = MeetingMinutesService(
            client: MockGeminiClient(),
            privacySettingsStore: privacyStore,
            keychainManager: emptyKeychain()
        )

        let sessionId = UUID().uuidString
        await service.startSession(sessionId: sessionId)
        await service.handleFinalizedSegment(sampleSegment(sessionId: sessionId, seq: 1, startMs: 1000))

        let result = await service.finishSession(sessionId: sessionId)
        #expect(result == nil)

        let status = await service.status
        try #require(status.degradationReason != nil)
        // finishSession must keep degraded (not reset to .idle) so the UI can
        // surface the reason.
        #expect(status.degradationReason!.contains("AI 已关闭"))
    }
}
