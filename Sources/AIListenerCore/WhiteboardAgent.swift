import Foundation

public protocol WhiteboardAgentProtocol: Sendable {
    func generateActions(for text: String, currentNodesCount: Int) async throws -> [WhiteboardAction]
}

/// Default whiteboard agent that extracts concise, structured summary nodes
/// (mind-map style) from finalized ASR text instead of dumping the raw transcript.
///
/// Uses local heuristics (no network/API-key dependency) so it works in offline
/// and localMock scenarios. The heuristics:
/// 1. Split the finalized text into multiple points when possible (by sequence
///    markers such as 首先/其次/第一, or by sentence punctuation)。
/// 2. Derive a concise `label` for each point — a short phrase, never the full
///    raw sentence (AC1.1).
/// 3. When more than one point is extracted, connect them with `connectNodes`
///    actions to express a parent → child / sequential relationship (AC1.2).
public final class DefaultWhiteboardAgent: WhiteboardAgentProtocol, @unchecked Sendable {
    public init() {}

    public func generateActions(for text: String, currentNodesCount: Int) async throws -> [WhiteboardAction] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let points = extractPoints(from: trimmed)
        var actions: [WhiteboardAction] = []

        // Layout: place the first (topic) node at the left, children to the right.
        let baseX = 120.0
        let baseY = 120.0
        let childX = baseX + 260.0
        let childSpacingY = 110.0

        let nodeKind = classify(text: trimmed)

        // Parent / topic node — label is a concise summary of the whole utterance.
        let parentLabel = summarizeTopic(from: trimmed, points: points)
        let parentNode = makeNode(
            idSuffix: "p",
            type: nodeKind,
            label: parentLabel,
            x: baseX,
            y: baseY,
            width: 200,
            height: 84
        )
        actions.append(WhiteboardAction(kind: actionKind(for: nodeKind), node: parentNode))

        // Child nodes — one per extracted point, labelled with a concise phrase.
        var childNodeIds: [String] = []
        for (index, point) in points.enumerated() {
            let label = summarizePoint(point)
            guard !label.isEmpty else { continue }
            let child = makeNode(
                idSuffix: "c\(index)",
                type: childType(for: point),
                label: label,
                x: childX,
                y: baseY + Double(index) * childSpacingY,
                width: 200,
                height: 70
            )
            childNodeIds.append(child.id)
            actions.append(WhiteboardAction(kind: actionKind(for: child.type), node: child))
        }

        // Connect parent → each child to express hierarchy (AC1.2).
        for childId in childNodeIds {
            let conn = WhiteboardConnection(
                id: "conn_\(UUID().uuidString.prefix(8))",
                fromNodeId: parentNode.id,
                toNodeId: childId
            )
            actions.append(WhiteboardAction(kind: .connectNodes, connection: conn))
        }

        return actions.map { WhiteboardSanitizer.sanitizeAction($0) }
    }

    // MARK: - Point extraction

    /// Splits a finalized utterance into discrete points using Chinese sequence
    /// markers and sentence punctuation. Returns 1–N points.
    private func extractPoints(from text: String) -> [String] {
        // Common Chinese ordinal / sequence markers.
        let markers = ["第一", "第二", "第三", "第四", "第五", "第六", "第七", "第八", "第九", "第十",
                       "首先", "其次", "然后", "接着", "最后", "另外", "此外", "同时"]
        var points: [String] = []

        // Try splitting by sequence markers first.
        var remaining = text
        var foundMarkerSplit = false
        for marker in markers {
            if remaining.contains(marker) {
                let parts = split(by: markers, in: remaining)
                if parts.count > 1 {
                    points = parts
                    foundMarkerSplit = true
                    break
                }
            }
        }

        // Fallback: split by sentence-ending punctuation.
        if !foundMarkerSplit {
            let raw = text
                .components(separatedBy: "。")
                .flatMap { $0.components(separatedBy: "；") }
                .flatMap { $0.components(separatedBy: "；") }
                .flatMap { $0.components(separatedBy: ";") }
                .flatMap { $0.components(separatedBy: ".") }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            points = raw
        }

        // If nothing split out, the whole text is a single point.
        if points.isEmpty {
            points = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        return points
    }

    /// Splits text by any of the provided markers, returning the text segments
    /// *including* the leading marker so the point retains context.
    private func split(by markers: [String], in text: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let rest = String(chars[i...])
            var matchedMarker: String? = nil
            for marker in markers {
                if rest.hasPrefix(marker) {
                    matchedMarker = marker
                    break
                }
            }
            if let marker = matchedMarker {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                current = marker
                i += marker.count
            } else {
                current.append(chars[i])
                i += 1
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { segments.append(last) }
        return segments
    }

    // MARK: - Summarization (local heuristics)

    /// Produces a concise topic label for the whole utterance.
    private func summarizeTopic(from text: String, points: [String]) -> String {
        // If multiple points, prefer the first marker phrase as the topic.
        if points.count > 1, let first = points.first {
            let topic = leadingPhrase(of: first, maxChars: 12)
            if !topic.isEmpty { return topic }
        }
        return leadingPhrase(of: text, maxChars: 14)
    }

    /// Produces a concise label for a single point.
    private func summarizePoint(_ point: String) -> String {
        leadingPhrase(of: point, maxChars: 16)
    }

    /// Returns a short phrase (up to `maxChars`) from the start of `text`,
    /// cutting at the first clause separator if one appears early enough.
    private func leadingPhrase(of text: String, maxChars: Int) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let separators: [Character] = ["，", ",", "：", ":", "、", "。", "；", ";"]
        var cut = cleaned
        for sep in separators {
            if let range = cleaned.range(of: String(sep)) {
                let before = String(cleaned[..<range.lowerBound])
                if before.count >= 2 && before.count <= maxChars {
                    cut = before
                    break
                }
            }
        }
        if cut.count > maxChars {
            let end = cut.index(cut.startIndex, offsetBy: maxChars)
            cut = String(cut[..<end])
        }
        return cut
    }

    // MARK: - Node classification

    private func classify(text: String) -> WhiteboardNodeType {
        if text.contains("流程") || text.contains("步骤") || text.contains("首先") || text.contains("其次") {
            return .flowStep
        } else if text.contains("时间") || text.contains("日期") || text.contains("点") {
            return .timelineEvent
        } else if text.contains("待办") || text.contains("任务") || text.contains("负责") {
            return .card
        }
        return .rectangle
    }

    private func childType(for point: String) -> WhiteboardNodeType {
        if point.contains("时间") || point.contains("日期") || point.contains("点") {
            return .timelineEvent
        } else if point.contains("待办") || point.contains("任务") || point.contains("负责") {
            return .card
        }
        return .rectangle
    }

    private func actionKind(for type: WhiteboardNodeType) -> WhiteboardActionKind {
        switch type {
        case .flowStep: return .addFlowStep
        case .timelineEvent: return .addTimelineEvent
        case .card: return .addCard
        default: return .addNode
        }
    }

    private func makeNode(idSuffix: String, type: WhiteboardNodeType, label: String, x: Double, y: Double, width: Double, height: Double) -> WhiteboardNode {
        let (bg, stroke) = colors(for: type)
        return WhiteboardNode(
            id: "node_\(UUID().uuidString.prefix(8))_\(idSuffix)",
            type: type,
            label: label,
            x: x,
            y: y,
            width: width,
            height: height,
            backgroundColor: bg,
            strokeColor: stroke
        )
    }

    private func colors(for type: WhiteboardNodeType) -> (String, String) {
        switch type {
        case .flowStep: return ("#E3F2FD", "#1E88E5")
        case .timelineEvent: return ("#FFF3E0", "#FB8C00")
        case .card: return ("#E8F5E9", "#43A047")
        default: return ("#F5F5F5", "#757575")
        }
    }
}
