import Foundation

public enum GeminiClientError: Error, Equatable {
    case missingApiKey
    case invalidResponse(Int, String)
    case invalidJsonPayload
    case networkError(String)
}

public protocol GeminiClientProtocol: Sendable {
    func generateMinutes(
        sessionId: String,
        segments: [TranscriptSegmentRecord],
        kind: MeetingMinutes.MinutesKind,
        style: MinutesStyle,
        apiKey: String?
    ) async throws -> MeetingMinutes
}

public final class GeminiClient: GeminiClientProtocol, @unchecked Sendable {
    private let session: URLSession
    private let modelName: String

    public init(session: URLSession = .shared, modelName: String = "gemini-1.5-flash") {
        self.session = session
        self.modelName = modelName
    }

    public func generateMinutes(
        sessionId: String,
        segments: [TranscriptSegmentRecord],
        kind: MeetingMinutes.MinutesKind,
        style: MinutesStyle,
        apiKey: String?
    ) async throws -> MeetingMinutes {
        guard let apiKey = apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GeminiClientError.missingApiKey
        }

        let urlString = "https://generativelanguage.googleapis.com/v1beta/models/\(modelName):generateContent?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw GeminiClientError.networkError("Invalid URL")
        }

        let prompt = buildPrompt(sessionId: sessionId, segments: segments, kind: kind, style: style)
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: requestBody) else {
            throw GeminiClientError.invalidJsonPayload
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GeminiClientError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiClientError.invalidResponse(-1, "Non-HTTP response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown HTTP error"
            throw GeminiClientError.invalidResponse(httpResponse.statusCode, errorText)
        }

        return try parseGeminiResponse(data: data, sessionId: sessionId, kind: kind, style: style)
    }

    private func buildPrompt(
        sessionId: String,
        segments: [TranscriptSegmentRecord],
        kind: MeetingMinutes.MinutesKind,
        style: MinutesStyle
    ) -> String {
        let transcriptText = segments.map { seg in
            "[\(seg.startMs)ms - \(seg.endMs)ms]: \(seg.text)"
        }.joined(separator: "\n")

        return """
        你是一个专业的 AI 会议纪要生成助手。请阅读以下会议逐字稿，按【\(style.displayName)】风格生成结构化会议纪要。
        纪要类型：\(kind == .incremental ? "会中增量摘要" : "会后完整纪要")。

        【逐字稿】：
        \(transcriptText.isEmpty ? "(无逐字稿内容)" : transcriptText)

        【输出规范】：
        必须且仅返回合法 JSON 对象，格式如下（不包含额外的解释文本）：
        {
          "overview": {
            "title": "会议主题/名称",
            "durationMs": 120000,
            "participantSummary": "参会人员概述",
            "generalSummary": "会议概览总结"
          },
          "coreSummary": ["核心要点1", "核心要点2"],
          "topics": [
            {
              "topicId": "uuid-1",
              "title": "议题/章节名称",
              "summary": "议题讨论摘要",
              "keyPoints": ["要点1", "要点2"]
            }
          ],
          "decisions": ["关键决策1"],
          "actionItems": [
            {
              "itemId": "uuid-2",
              "task": "具体待办任务",
              "assignee": "负责人",
              "dueDate": "截止时间",
              "timestampMs": 1000
            }
          ],
          "unresolvedQuestions": ["未决问题/风险1"],
          "timestampReferences": [
            {
              "refId": "uuid-3",
              "text": "引用的原话或关键讨论",
              "startMs": 1000,
              "endMs": 5000,
              "label": "标签"
            }
          ]
        }
        """
    }

    private func parseGeminiResponse(
        data: Data,
        sessionId: String,
        kind: MeetingMinutes.MinutesKind,
        style: MinutesStyle
    ) throws -> MeetingMinutes {
        struct GeminiAPIResponse: Codable {
            struct Candidate: Codable {
                struct Content: Codable {
                    struct Part: Codable {
                        let text: String?
                    }
                    let parts: [Part]?
                }
                let content: Content?
            }
            let candidates: [Candidate]?
        }

        guard let jsonObject = try? JSONDecoder().decode(GeminiAPIResponse.self, from: data),
              let candidateText = jsonObject.candidates?.first?.content?.parts?.first?.text else {
            throw GeminiClientError.invalidJsonPayload
        }

        let cleanedJson = cleanJsonString(candidateText)
        guard let jsonResultData = cleanedJson.data(using: .utf8) else {
            throw GeminiClientError.invalidJsonPayload
        }

        struct MinutesDTO: Codable {
            let overview: MeetingOverview
            let coreSummary: [String]
            let topics: [MinutesTopic]
            let decisions: [String]
            let actionItems: [ActionItem]
            let unresolvedQuestions: [String]
            let timestampReferences: [TimestampReference]
        }

        do {
            let dto = try JSONDecoder().decode(MinutesDTO.self, from: jsonResultData)
            return MeetingMinutes(
                sessionId: sessionId,
                kind: kind,
                style: style,
                overview: dto.overview,
                coreSummary: dto.coreSummary,
                topics: dto.topics,
                decisions: dto.decisions,
                actionItems: dto.actionItems,
                unresolvedQuestions: dto.unresolvedQuestions,
                timestampReferences: dto.timestampReferences
            )
        } catch {
            throw GeminiClientError.invalidJsonPayload
        }
    }

    private func cleanJsonString(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```json") {
            trimmed.removeFirst(7)
        } else if trimmed.hasPrefix("```") {
            trimmed.removeFirst(3)
        }
        if trimmed.hasSuffix("```") {
            trimmed.removeLast(3)
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public final class MockGeminiClient: GeminiClientProtocol, @unchecked Sendable {
    public var shouldFail: Bool
    public var failureError: GeminiClientError

    public init(shouldFail: Bool = false, failureError: GeminiClientError = .networkError("Mock network failure")) {
        self.shouldFail = shouldFail
        self.failureError = failureError
    }

    public func generateMinutes(
        sessionId: String,
        segments: [TranscriptSegmentRecord],
        kind: MeetingMinutes.MinutesKind,
        style: MinutesStyle,
        apiKey: String?
    ) async throws -> MeetingMinutes {
        if shouldFail {
            throw failureError
        }

        let maxMs = segments.map(\.endMs).max() ?? 60000
        let fullText = segments.map(\.text).joined(separator: "；")

        let overview = MeetingOverview(
            title: "【Mock】会议纪要 (\(style.displayName))",
            durationMs: maxMs,
            participantSummary: "参会人员：主要发言者与听众",
            generalSummary: fullText.isEmpty ? "本次会议无发言记录。" : "会议讨论摘要：\(fullText.prefix(100))..."
        )

        let coreSummary = [
            "总结要点 1：已确认项目进度与架构方案。",
            "总结要点 2：明确阶段性交付交付目标。"
        ]

        let topics = [
            MinutesTopic(
                title: "议题一：架构与功能评审",
                summary: "对阶段二功能（Keychain、Gemini 纪要）进行讨论与评审。",
                keyPoints: ["重点关注密钥安全性", "确保网络异常时静默降级"]
            )
        ]

        let decisions = [
            "确定 API Key 不落盘，仅存储于 Keychain。",
            "确定使用 SQLite schema v3 迁移存储纪要。"
        ]

        let actionItems = [
            ActionItem(
                task: "完成 MockGeminiClient 与单元测试编写",
                assignee: "Hermes",
                dueDate: "今日",
                timestampMs: segments.first?.startMs ?? 0
            )
        ]

        let unresolvedQuestions = [
            "关注本地 LLM 接入的可能性与性能表现"
        ]

        let timestampReferences = segments.prefix(3).map { seg in
            TimestampReference(
                text: seg.text,
                startMs: seg.startMs,
                endMs: seg.endMs,
                label: "关键发言"
            )
        }

        return MeetingMinutes(
            sessionId: sessionId,
            kind: kind,
            style: style,
            overview: overview,
            coreSummary: coreSummary,
            topics: topics,
            decisions: decisions,
            actionItems: actionItems,
            unresolvedQuestions: unresolvedQuestions,
            timestampReferences: Array(timestampReferences)
        )
    }
}
