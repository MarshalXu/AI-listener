import Foundation
import Testing
@testable import AIListenerCore

@Suite
struct GeminiClientTests {
    private func sampleSegments() -> [TranscriptSegmentRecord] {
        [
            TranscriptSegmentRecord(
                segmentId: UUID().uuidString,
                sessionId: "00000000-0000-0000-0000-000000000001",
                revisionOf: nil,
                status: "finalized",
                sequence: 1,
                revision: 0,
                startMs: 1000,
                endMs: 5000,
                text: "大家早上好，今天讨论项目二期阶段落地方案。",
                createdMonotonicMs: 1000,
                engineId: "sherpa",
                engineModelVersion: "v1"
            ),
            TranscriptSegmentRecord(
                segmentId: UUID().uuidString,
                sessionId: "00000000-0000-0000-0000-000000000001",
                revisionOf: nil,
                status: "finalized",
                sequence: 2,
                revision: 0,
                startMs: 6000,
                endMs: 12000,
                text: "确认 API Key 保存在 Keychain 中，不写配置文件。",
                createdMonotonicMs: 2000,
                engineId: "sherpa",
                engineModelVersion: "v1"
            )
        ]
    }

    @Test func mockClientGeneratesMinutesSuccessfully() async throws {
        let client = MockGeminiClient()
        let segments = sampleSegments()

        let minutes = try await client.generateMinutes(
            sessionId: "00000000-0000-0000-0000-000000000001",
            segments: segments,
            kind: .postSession,
            style: .standard,
            apiKey: nil
        )

        #expect(minutes.sessionId == "00000000-0000-0000-0000-000000000001")
        #expect(minutes.kind == .postSession)
        #expect(minutes.style == .standard)
        #expect(!minutes.overview.title.isEmpty)
        #expect(!minutes.coreSummary.isEmpty)
        #expect(!minutes.decisions.isEmpty)
        #expect(!minutes.actionItems.isEmpty)
        #expect(minutes.timestampReferences.count == 2)
    }

    @Test func mockClientFailureHandling() async {
        let client = MockGeminiClient(shouldFail: true, failureError: .invalidResponse(500, "Server Error"))

        await #expect(throws: GeminiClientError.invalidResponse(500, "Server Error")) {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .incremental,
                style: .concise,
                apiKey: "dummy-key"
            )
        }
    }

    @Test func geminiClientMissingApiKeyThrowsError() async {
        let client = GeminiClient()

        await #expect(throws: GeminiClientError.missingApiKey) {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: ""
            )
        }
    }
}
