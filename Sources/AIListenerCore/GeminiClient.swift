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
        // responseMimeType = application/json nudges Gemini to return pure JSON
        // (no markdown fences / prose wrapping), reducing cleanup fragility.
        // temperature is pinned low for deterministic, structured output.
        let requestBody: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt]
                    ]
                ]
            ],
            "generationConfig": [
                "responseMimeType": "application/json",
                "temperature": 0.2
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

        // Strip a fenced code block that may appear anywhere in the candidate
        // text. Only strip when a matching closing fence exists so we never
        // damage content that merely contains stray backticks.
        if trimmed.contains("```") {
            let fenceStart = trimmed.range(of: "```")
            let innerStart: String.Index
            if let start = fenceStart {
                let afterFence = start.upperBound
                // Skip an optional language tag (e.g. "json") up to a newline.
                if afterFence < trimmed.endIndex, trimmed[afterFence..<trimmed.endIndex].hasPrefix("json") {
                    let afterLang = trimmed.index(afterFence, offsetBy: 4)
                    if afterLang < trimmed.endIndex, trimmed[afterLang].isNewline {
                        innerStart = trimmed.index(after: afterLang)
                    } else {
                        innerStart = afterFence
                    }
                } else {
                    innerStart = afterFence
                }
            } else {
                innerStart = trimmed.startIndex
            }

            if let close = trimmed.range(of: "```", range: innerStart..<trimmed.endIndex) {
                trimmed = String(trimmed[innerStart..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Fallback: if the model wrapped the JSON in prose (no fences),
        // extract the outermost { ... } object so JSONDecoder gets clean JSON.
        if !trimmed.hasPrefix("{") || !trimmed.hasSuffix("}") {
            if let firstBrace = trimmed.firstIndex(of: "{"),
               let lastBrace = trimmed.lastIndex(of: "}"),
               firstBrace <= lastBrace {
                trimmed = String(trimmed[firstBrace...lastBrace])
            }
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

        let maxMs = segments.map(\.endMs).max() ?? 0
        let nonEmptySegments = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let fullText = nonEmptySegments.map(\.text).joined(separator: "；")
        let sentences = MockGeminiClient.splitSentences(fullText)

        // Empty transcript: explicit "no speech" placeholder instead of fake sample content.
        if fullText.isEmpty {
            let overview = MeetingOverview(
                title: "未命名会议",
                durationMs: maxMs,
                participantSummary: "逐字稿未标注发言人",
                generalSummary: "无发言记录"
            )
            return MeetingMinutes(
                sessionId: sessionId,
                kind: kind,
                style: style,
                overview: overview,
                coreSummary: [],
                topics: [],
                decisions: [],
                actionItems: [],
                unresolvedQuestions: [],
                timestampReferences: []
            )
        }

        // overview — derived from transcript content.
        let titleSource = nonEmptySegments.first?.text ?? fullText
        let title = MockGeminiClient.deriveTitle(from: titleSource, style: style)
        let generalSummary = MockGeminiClient.deriveGeneralSummary(from: sentences)
        let participantSummary = "逐字稿未标注发言人"
        let overview = MeetingOverview(
            title: title,
            durationMs: maxMs,
            participantSummary: participantSummary,
            generalSummary: generalSummary
        )

        // coreSummary — 2~3 representative sentences from the transcript (non-fixed).
        let coreSummary = MockGeminiClient.deriveCoreSummary(from: sentences)

        // topics — group segments by time gaps, each topic titled/summarised from its segments.
        let topics = MockGeminiClient.deriveTopics(from: nonEmptySegments)

        // decisions / actionItems / unresolvedQuestions — keyword detection on real sentences.
        let decisions = MockGeminiClient.detectSentences(
            from: sentences,
            keywords: ["决定", "确认", "同意", "通过", "确定", "决议", "达成", "敲定"]
        )
        let actionableSentences = MockGeminiClient.detectActionableSentences(
            from: sentences,
            segments: nonEmptySegments
        )
        let unresolvedQuestions = MockGeminiClient.detectSentences(
            from: sentences,
            keywords: ["？", "?", "吗", "呢", "怎么", "如何", "是否", "能不能", "能否", "为什么"]
        )

        // timestampReferences — keep existing segment-based logic (already transcript-derived).
        let timestampReferences = nonEmptySegments.prefix(3).map { seg in
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
            actionItems: actionableSentences,
            unresolvedQuestions: unresolvedQuestions,
            timestampReferences: Array(timestampReferences)
        )
    }

    // MARK: - Local heuristic helpers

    /// Split text into sentences using common CJK/ASCII terminators, dropping empties.
    private static func splitSentences(_ text: String) -> [String] {
        let separators: Set<Character> = ["。", "！", "？", "；", ".", "!", "?", "\n"]
        var current = String()
        var result: [String] = []
        for char in text {
            if separators.contains(char) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(trimmed)
                }
                current = String()
            } else {
                current.append(char)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            result.append(tail)
        }
        return result
    }

    /// Title from the first utterance: strip trailing punctuation, truncate to ~20 chars.
    private static func deriveTitle(from source: String, style: MinutesStyle) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = String(trimmed.prefix(20))
        let trailingPunctuation = CharacterSet(charactersIn: "。！？；.!?；,，、：")
        let cleaned = prefix.trimmingCharacters(in: trailingPunctuation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "未命名会议" : cleaned
        return "\(base)（\(style.displayName)）"
    }

    /// General summary: concatenate the first few sentences, capped at ~120 chars.
    private static func deriveGeneralSummary(from sentences: [String]) -> String {
        guard !sentences.isEmpty else { return "无发言记录" }
        var summary = ""
        for sentence in sentences {
            let candidate = summary.isEmpty ? sentence : summary + "；" + sentence
            if candidate.count > 120 {
                summary += "；" + sentence
                break
            }
            summary = candidate
            if summary.count >= 80 { break }
        }
        let capped = String(summary.prefix(120))
        return capped
    }

    /// Core summary: pick up to 3 representative sentences (first, middle, last).
    private static func deriveCoreSummary(from sentences: [String]) -> [String] {
        guard !sentences.isEmpty else { return [] }
        if sentences.count <= 3 {
            return sentences
        }
        let first = sentences[0]
        let middle = sentences[sentences.count / 2]
        let last = sentences[sentences.count - 1]
        return [first, middle, last]
    }

    /// Group segments into topics by time gaps (≥10s) or size (every 4 segments),
    /// each topic titled/summarised from its own segments.
    private static func deriveTopics(from segments: [TranscriptSegmentRecord]) -> [MinutesTopic] {
        guard !segments.isEmpty else { return [] }
        var groups: [[TranscriptSegmentRecord]] = []
        var current: [TranscriptSegmentRecord] = []
        var lastEndMs: Int64 = segments[0].startMs

        for seg in segments {
            let gap = seg.startMs - lastEndMs
            if !current.isEmpty && (gap >= 10_000 || current.count >= 4) {
                groups.append(current)
                current = []
            }
            current.append(seg)
            lastEndMs = max(lastEndMs, seg.endMs)
        }
        if !current.isEmpty {
            groups.append(current)
        }

        return groups.enumerated().map { index, group in
            let groupText = group.map(\.text).joined(separator: "；")
            let titleSource = group.first?.text ?? groupText
            let trailing = CharacterSet(charactersIn: "。！？；.!?，,、：")
            let titleBase = String(titleSource.prefix(24))
                .trimmingCharacters(in: trailing)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = titleBase.isEmpty ? "议题 \(index + 1)" : "议题 \(index + 1)：\(titleBase)"
            let summary = String(groupText.prefix(100))
            let keyPoints = group.prefix(3).map { String($0.text.prefix(40)) }
            return MinutesTopic(
                title: title,
                summary: summary,
                keyPoints: keyPoints
            )
        }
    }

    /// Return sentences containing any of the given keywords (real transcript content).
    private static func detectSentences(from sentences: [String], keywords: [String]) -> [String] {
        let matched = sentences.filter { sentence in
            keywords.contains { keyword in sentence.contains(keyword) }
        }
        return Array(matched.prefix(5))
    }

    /// Detect actionable sentences and attach the originating segment timestamp.
    private static func detectActionableSentences(
        from sentences: [String],
        segments: [TranscriptSegmentRecord]
    ) -> [ActionItem] {
        let keywords = ["需要", "负责", "完成", "跟进", "安排", "待办", "推进", "落实", "下周", "本周", "明天", "今天", "尽快", "之后"]
        let matched = sentences.filter { sentence in
            keywords.contains { keyword in sentence.contains(keyword) }
        }
        return matched.prefix(5).map { sentence in
            // Find the segment whose text contains this sentence, for timestamp attribution.
            let seg = segments.first { seg in seg.text.contains(sentence) }
                ?? segments.min(by: { abs($0.startMs) < abs($1.startMs) })
            return ActionItem(
                task: String(sentence.prefix(60)),
                assignee: nil,
                dueDate: nil,
                timestampMs: seg?.startMs
            )
        }
    }
}
