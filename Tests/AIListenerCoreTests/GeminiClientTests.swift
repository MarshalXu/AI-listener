import Foundation
import Testing
@testable import AIListenerCore

@Suite(.serialized)
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

    /// A minimal but complete Minutes payload that GeminiClient's
    /// `MinutesDTO` can decode successfully.
    private var validMinutesJson: String {
        """
        {
          "overview": {
            "title": "项目二期评审",
            "durationMs": 120000,
            "participantSummary": "主要发言者与听众",
            "generalSummary": "会议确认了项目二期落地方案。"
          },
          "coreSummary": ["确认架构方案", "明确交付目标"],
          "topics": [
            {
              "topicId": "uuid-1",
              "title": "架构评审",
              "summary": "讨论了 Gemini 接入与降级策略。",
              "keyPoints": ["密钥安全", "降级提示"]
            }
          ],
          "decisions": ["API Key 不落盘"],
          "actionItems": [
            {
              "itemId": "uuid-2",
              "task": "完成单元测试",
              "assignee": "Hermes",
              "dueDate": "今日",
              "timestampMs": 1000
            }
          ],
          "unresolvedQuestions": ["本地 LLM 性能"],
          "timestampReferences": [
            {
              "refId": "uuid-3",
              "text": "确认 API Key 保存",
              "startMs": 1000,
              "endMs": 5000,
              "label": "关键发言"
            }
          ]
        }
        """
    }

    // MARK: - MockGeminiClient tests

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
                apiKey: nil
            )
        }
    }

    // MARK: - GeminiClient real-API path tests (via StubURLProtocol)

    @Test func geminiClientMissingApiKeyThrowsError() async {
        let client = GeminiClient()

        await #expect(throws: GeminiClientError.missingApiKey) {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: nil
            )
        }
    }

    @Test func geminiClientBlankApiKeyThrowsError() async {
        let client = GeminiClient()

        await #expect(throws: GeminiClientError.missingApiKey) {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: "   "
            )
        }
    }

    @Test func geminiClientNetworkErrorIsPropagated() async {
        let config = StubURLProtocol.makeConfig(
            responder: { _ in throw URLError(.notConnectedToInternet) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        var caught: GeminiClientError?
        do {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: "test-key"
            )
        } catch let error as GeminiClientError {
            caught = error
        } catch {
            Issue.record("Expected GeminiClientError, got \(error)")
        }
        guard case .networkError = caught else {
            Issue.record("Expected .networkError, got \(String(describing: caught))")
            return
        }
    }

    @Test func geminiClientInvalidHttpResponseThrows() async {
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 401, body: Data("Unauthorized".utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        var caught: GeminiClientError?
        do {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: "test-key"
            )
        } catch let error as GeminiClientError {
            caught = error
        } catch {
            Issue.record("Expected GeminiClientError, got \(error)")
        }
        guard case .invalidResponse(let code, _) = caught, code == 401 else {
            Issue.record("Expected .invalidResponse(401), got \(String(describing: caught))")
            return
        }
    }

    @Test func geminiClientQuotaErrorThrows429() async {
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 429, body: Data("Quota exceeded".utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        var caught: GeminiClientError?
        do {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: "test-key"
            )
        } catch let error as GeminiClientError {
            caught = error
        } catch {
            Issue.record("Expected GeminiClientError, got \(error)")
        }
        guard case .invalidResponse(let code, _) = caught, code == 429 else {
            Issue.record("Expected .invalidResponse(429), got \(String(describing: caught))")
            return
        }
    }

    @Test func geminiClientParsesCleanJsonResponse() async throws {
        let envelope = makeEnvelope(text: validMinutesJson)
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 200, body: Data(envelope.utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        let minutes = try await client.generateMinutes(
            sessionId: "00000000-0000-0000-0000-000000000001",
            segments: sampleSegments(),
            kind: .postSession,
            style: .standard,
            apiKey: "test-key"
        )

        #expect(minutes.overview.title == "项目二期评审")
        #expect(minutes.topics.count == 1)
        #expect(minutes.actionItems.first?.assignee == "Hermes")
    }

    @Test func geminiClientParsesJsonWrappedInMarkdownCodeFence() async throws {
        let fenced = "```json\n\(validMinutesJson)\n```"
        let envelope = makeEnvelope(text: fenced)
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 200, body: Data(envelope.utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        let minutes = try await client.generateMinutes(
            sessionId: "00000000-0000-0000-0000-000000000001",
            segments: sampleSegments(),
            kind: .postSession,
            style: .standard,
            apiKey: "test-key"
        )

        #expect(minutes.overview.title == "项目二期评审")
    }

    @Test func geminiClientParsesJsonWithSurroundingProse() async throws {
        let wrapped = "好的，这是你要的纪要：\n\(validMinutesJson)\n希望对你有帮助。"
        let envelope = makeEnvelope(text: wrapped)
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 200, body: Data(envelope.utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        let minutes = try await client.generateMinutes(
            sessionId: "00000000-0000-0000-0000-000000000001",
            segments: sampleSegments(),
            kind: .postSession,
            style: .standard,
            apiKey: "test-key"
        )

        #expect(minutes.overview.title == "项目二期评审")
    }

    @Test func geminiClientNonJsonCandidateTextThrowsInvalidJsonPayload() async {
        let envelope = makeEnvelope(text: "这不是 JSON，只是一段散文。")
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 200, body: Data(envelope.utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        await #expect(throws: GeminiClientError.invalidJsonPayload) {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: "test-key"
            )
        }
    }

    @Test func geminiClientMissingCandidatesFieldThrowsInvalidJsonPayload() async {
        // Safety-filtered response: no candidates at all.
        let envelope = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 200, body: Data(envelope.utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        await #expect(throws: GeminiClientError.invalidJsonPayload) {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: "test-key"
            )
        }
    }

    @Test func geminiClientMalformedGeminiEnvelopeThrowsInvalidJsonPayload() async {
        // Not a valid Gemini envelope at all.
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 200, body: Data("<<not json>>".utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        await #expect(throws: GeminiClientError.invalidJsonPayload) {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: "test-key"
            )
        }
    }

    @Test func geminiClientIncompleteMinutesPayloadThrowsInvalidJsonPayload() async {
        // Valid envelope + valid JSON, but the inner object is missing required
        // fields (e.g. `overview`). cleanJsonString leaves it as-is, and DTO
        // decoding should fail.
        let incompleteJson = #"{"coreSummary":["a"]}"#
        let envelope = makeEnvelope(text: incompleteJson)
        let config = StubURLProtocol.makeConfig(
            responder: { _ in StubResponse(statusCode: 200, body: Data(envelope.utf8)) }
        )
        let client = GeminiClient(session: URLSession(configuration: config))

        await #expect(throws: GeminiClientError.invalidJsonPayload) {
            _ = try await client.generateMinutes(
                sessionId: "00000000-0000-0000-0000-000000000001",
                segments: sampleSegments(),
                kind: .postSession,
                style: .standard,
                apiKey: "test-key"
            )
        }
    }

    // MARK: - Helpers

    private func makeEnvelope(text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        {
          "candidates": [
            {
              "content": {
                "parts": [{"text": "\(escaped)"}]
              }
            }
          ]
        }
        """
    }
}

// MARK: - StubURLProtocol

/// A thread-safe URLProtocol stub that lets tests inject canned responses
/// (or thrown errors) for the Gemini generateContent endpoint without any
/// real network access.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var responder: ((URLRequest) throws -> StubResponse)?

    static func makeConfig(responder: @escaping (URLRequest) throws -> StubResponse) -> URLSessionConfiguration {
        Self.lock.lock()
        Self.responder = responder
        Self.lock.unlock()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return config
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response: StubResponse
        do {
            response = try Self.currentResponder()(request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let url = request.url ?? URL(string: "https://example.com")!
        let http = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])
        client?.urlProtocol(self, didReceive: http!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func currentResponder() -> (URLRequest) throws -> StubResponse {
        lock.lock()
        let r = responder
        lock.unlock()
        return r ?? { _ in StubResponse(statusCode: 599, body: Data()) }
    }
}

private struct StubResponse: Sendable {
    let statusCode: Int
    let body: Data
}
