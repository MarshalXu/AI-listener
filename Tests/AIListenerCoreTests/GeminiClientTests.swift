import Foundation
import Testing
@testable import AIListenerCore

// MARK: - StubURLProtocol

/// A thread-safe URLProtocol subclass used by GeminiClientTests to inject
/// canned HTTP responses (and errors) without touching the network.
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    // Access is externally synchronized via `lock`; `nonisolated(unsafe)`
    // silences Swift 6's global-mutable-state checker accordingly.
    private nonisolated(unsafe) static var responders: [(request: URLRequest, handler: (URLRequest) throws -> (HTTPURLResponse, Data))] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responders.removeAll()
    }

    /// Install a responder keyed by the request URL. When the next request to
    /// that URL arrives the handler decides what to return (status/body or a
    /// thrown error). Requests are consumed FIFO.
    static func stub(url: URL, handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.lock(); defer { lock.unlock() }
        responders.append((request: URLRequest(url: url), handler: { req in
            let (status, body) = try handler(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, body)
        }))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        // Match the most recent registered responder for this URL (FIFO).
        var match: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        for i in (0..<Self.responders.count).reversed() where Self.responders[i].request.url == request.url {
            match = Self.responders[i].handler
            Self.responders.remove(at: i)
            break
        }
        Self.lock.unlock()

        guard let handler = match else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Gemini response fixtures

private func geminiEnvelope(text: String) -> Data {
    let escaped = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    let body = "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\(escaped)\"}]}}]}"
    return body.data(using: .utf8)!
}

private let validMinutesJSON = """
{
  "overview": {
    "title": "项目周会",
    "durationMs": 120000,
    "participantSummary": "5 人参会",
    "generalSummary": "讨论了项目进度并确认下一阶段计划。"
  },
  "coreSummary": ["确认项目进度", "明确交付目标"],
  "topics": [
    {
      "topicId": "t1",
      "title": "架构评审",
      "summary": "评审了二期架构方案",
      "keyPoints": ["重点关注密钥安全", "确保网络异常时降级"]
    }
  ],
  "decisions": ["API Key 仅存 Keychain"],
  "actionItems": [
    {
      "itemId": "a1",
      "task": "完成单元测试",
      "assignee": "Hermes",
      "dueDate": "今日",
      "timestampMs": 1000
    }
  ],
  "unresolvedQuestions": ["本地 LLM 接入可能性"],
  "timestampReferences": [
    {
      "refId": "r1",
      "text": "API Key 保存在 Keychain",
      "startMs": 6000,
      "endMs": 12000,
      "label": "关键发言"
    }
  ]
}
"""

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

    private func client(session: URLSession = .shared) -> GeminiClient {
        GeminiClient(session: session, modelName: "gemini-1.5-flash")
    }

    // MARK: Mock client

    @Test func mockClientGeneratesMinutesSuccessfully() async throws {
        let client = MockGeminiClient()
        let segments = sampleSegments()

        let minutes = try await client.generateMinutes(
            sessionId: "00000000-0000-0000-0000-000000000001",
            segments: segments,
            kind: .postSession,
            style: .standard,
            apiKey: "test-key"
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
                apiKey: "test-key"
            )
        }
    }

    // MARK: Missing/blank API key

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

    // MARK: Network / HTTP error paths (via StubURLProtocol)

    @Test func geminiClientNetworkErrorIsPropagated() async {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=test-key")!
        StubURLProtocol.stub(url: url) { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await client(session: stubbedSession()).generateMinutes(
                sessionId: "s", segments: sampleSegments(),
                kind: .postSession, style: .standard, apiKey: "test-key"
            )
            Issue.record("expected a networkError to be thrown")
        } catch let err as GeminiClientError {
            if case .networkError = err {
                // expected — URLError.localizedDescription is locale-dependent,
                // so we only assert on the case, not the string.
            } else {
                Issue.record("expected .networkError, got \(err)")
            }
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    @Test func geminiClientInvalidHttpResponseThrows() async {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=bad-key")!
        StubURLProtocol.stub(url: url) { _ in
            (401, "API key not valid".data(using: .utf8)!)
        }

        await #expect(throws: GeminiClientError.invalidResponse(401, "API key not valid")) {
            _ = try await client(session: stubbedSession()).generateMinutes(
                sessionId: "s", segments: sampleSegments(),
                kind: .postSession, style: .standard, apiKey: "bad-key"
            )
        }
    }

    @Test func geminiClientQuotaErrorThrows429() async {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=quota-key")!
        StubURLProtocol.stub(url: url) { _ in
            (429, "quota exceeded".data(using: .utf8)!)
        }

        await #expect(throws: GeminiClientError.invalidResponse(429, "quota exceeded")) {
            _ = try await client(session: stubbedSession()).generateMinutes(
                sessionId: "s", segments: sampleSegments(),
                kind: .postSession, style: .standard, apiKey: "quota-key"
            )
        }
    }

    // MARK: Response parsing

    @Test func geminiClientParsesCleanJsonResponse() async throws {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=clean-key")!
        StubURLProtocol.stub(url: url) { _ in
            (200, geminiEnvelope(text: validMinutesJSON))
        }

        let minutes = try await client(session: stubbedSession()).generateMinutes(
            sessionId: "s", segments: sampleSegments(),
            kind: .postSession, style: .standard, apiKey: "clean-key"
        )

        #expect(minutes.overview.title == "项目周会")
        #expect(minutes.coreSummary == ["确认项目进度", "明确交付目标"])
        #expect(minutes.topics.first?.topicId == "t1")
        #expect(minutes.actionItems.first?.task == "完成单元测试")
        #expect(minutes.unresolvedQuestions == ["本地 LLM 接入可能性"])
    }

    @Test func geminiClientParsesJsonWrappedInMarkdownCodeFence() async throws {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=fence-key")!
        let wrapped = "```json\n\(validMinutesJSON)\n```"
        StubURLProtocol.stub(url: url) { _ in
            (200, geminiEnvelope(text: wrapped))
        }

        let minutes = try await client(session: stubbedSession()).generateMinutes(
            sessionId: "s", segments: sampleSegments(),
            kind: .postSession, style: .standard, apiKey: "fence-key"
        )
        #expect(minutes.overview.title == "项目周会")
        #expect(!minutes.coreSummary.isEmpty)
    }

    @Test func geminiClientParsesJsonWithSurroundingProse() async throws {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=prose-key")!
        let prose = "好的，这是你要的纪要：\n\(validMinutesJSON)\n以上为结构化纪要，请查阅。"
        StubURLProtocol.stub(url: url) { _ in
            (200, geminiEnvelope(text: prose))
        }

        let minutes = try await client(session: stubbedSession()).generateMinutes(
            sessionId: "s", segments: sampleSegments(),
            kind: .postSession, style: .standard, apiKey: "prose-key"
        )
        #expect(minutes.overview.title == "项目周会")
        #expect(minutes.decisions == ["API Key 仅存 Keychain"])
    }

    @Test func geminiClientNonJsonCandidateTextThrowsInvalidJsonPayload() async {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=nonjson-key")!
        StubURLProtocol.stub(url: url) { _ in
            (200, geminiEnvelope(text: "这不是 JSON，只是普通文本。"))
        }

        await #expect(throws: GeminiClientError.invalidJsonPayload) {
            _ = try await client(session: stubbedSession()).generateMinutes(
                sessionId: "s", segments: sampleSegments(),
                kind: .postSession, style: .standard, apiKey: "nonjson-key"
            )
        }
    }

    @Test func geminiClientMissingCandidatesFieldThrowsInvalidJsonPayload() async {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=nocand-key")!
        // Safety filter blocked the prompt → empty candidates.
        let body = "{\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}"
        StubURLProtocol.stub(url: url) { _ in
            (200, body.data(using: .utf8)!)
        }

        await #expect(throws: GeminiClientError.invalidJsonPayload) {
            _ = try await client(session: stubbedSession()).generateMinutes(
                sessionId: "s", segments: sampleSegments(),
                kind: .postSession, style: .standard, apiKey: "nocand-key"
            )
        }
    }

    @Test func geminiClientMalformedGeminiEnvelopeThrowsInvalidJsonPayload() async {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=malformed-key")!
        StubURLProtocol.stub(url: url) { _ in
            (200, "{not valid json".data(using: .utf8)!)
        }

        await #expect(throws: GeminiClientError.invalidJsonPayload) {
            _ = try await client(session: stubbedSession()).generateMinutes(
                sessionId: "s", segments: sampleSegments(),
                kind: .postSession, style: .standard, apiKey: "malformed-key"
            )
        }
    }

    @Test func geminiClientIncompleteMinutesPayloadThrowsInvalidJsonPayload() async {
        defer { StubURLProtocol.reset() }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=incomplete-key")!
        // Missing actionItems / unresolvedQuestions / timestampReferences.
        let partial = """
        {
          "overview": {"title":"x","durationMs":1,"participantSummary":"y","generalSummary":"z"},
          "coreSummary": [],
          "topics": [],
          "decisions": []
        }
        """
        StubURLProtocol.stub(url: url) { _ in
            (200, geminiEnvelope(text: partial))
        }

        await #expect(throws: GeminiClientError.invalidJsonPayload) {
            _ = try await client(session: stubbedSession()).generateMinutes(
                sessionId: "s", segments: sampleSegments(),
                kind: .postSession, style: .standard, apiKey: "incomplete-key"
            )
        }
    }
}
