import Foundation

public final class WhiteboardService: @unchecked Sendable {
    private let lock = NSLock()
    private var _nodes: [WhiteboardNode] = []
    private var _connections: [WhiteboardConnection] = []
    private var _isPaused: Bool = false
    private var _lastDiagnosticCode: String? = nil
    private var undoStack: [(forward: [WhiteboardAction], reverse: [WhiteboardAction])] = []
    private var redoStack: [(forward: [WhiteboardAction], reverse: [WhiteboardAction])] = []

    private let agent: WhiteboardAgentProtocol
    private var batcher: TranscriptBatcher<ASRTranscriptEvent>? = nil
    private var busSubscription: TranscriptBusSubscription?

    public var nodes: [WhiteboardNode] {
        lock.withLock { _nodes }
    }

    public var connections: [WhiteboardConnection] {
        lock.withLock { _connections }
    }

    public var isPaused: Bool {
        lock.withLock { _isPaused }
    }

    public var lastDiagnosticCode: String? {
        lock.withLock { _lastDiagnosticCode }
    }

    public init(
        agent: WhiteboardAgentProtocol = DefaultWhiteboardAgent(),
        batcherConfig: TranscriptBatcher<ASRTranscriptEvent>.Configuration? = TranscriptBatcher<ASRTranscriptEvent>.Configuration()
    ) {
        self.agent = agent
        self.batcher = nil
        if let config = batcherConfig {
            self.batcher = TranscriptBatcher(config: config) { [weak self] events in
                guard let self = self else { return }
                let combinedText = events.map { $0.text }.joined(separator: " ")
                Task {
                    await self.handleFinalizedText(combinedText)
                }
            }
        }
    }

    public func subscribeToBus(_ bus: TranscriptEventBus) {
        lock.withLock {
            busSubscription?.cancel()
            busSubscription = bus.subscribe { [weak self] event in
                guard let self = self else { return }
                switch event {
                case .finalized(let transcript):
                    if let batcher = self.batcher {
                        batcher.append(transcript)
                    } else {
                        Task {
                            await self.handleFinalizedText(transcript.text)
                        }
                    }
                case .reset:
                    self.batcher?.reset()
                    self.clear()
                case .partials:
                    break
                }
            }
        }
    }

    public func flushBatcher() {
        batcher?.flush()
    }

    public func pause() {
        lock.withLock {
            _isPaused = true
        }
    }

    public func resume() {
        lock.withLock {
            _isPaused = false
        }
    }

    public func clear() {
        batcher?.reset()
        lock.withLock {
            _nodes.removeAll()
            _connections.removeAll()
            undoStack.removeAll()
            redoStack.removeAll()
            _lastDiagnosticCode = nil
        }
    }

    private func setDiagnosticCode(_ code: String) {
        lock.withLock {
            _lastDiagnosticCode = code
        }
    }

    public func handleFinalizedText(_ text: String) async {
        guard !isPaused else { return }

        do {
            let currentCount = nodes.count
            let actions = try await agent.generateActions(for: text, currentNodesCount: currentCount)
            if !actions.isEmpty {
                applyActions(actions, recordUndo: true)
            }
        } catch {
            setDiagnosticCode("AGENT_GENERATION_FAILED:\(error.localizedDescription)")
        }
    }

    public func applyActions(_ actions: [WhiteboardAction], recordUndo: Bool = true) {
        lock.withLock {
            if recordUndo {
                var reverseActions: [WhiteboardAction] = []
                for action in actions {
                    switch action.kind {
                    case .addNode, .addCard, .addFlowStep, .addTimelineEvent:
                        if let node = action.node {
                            reverseActions.append(WhiteboardAction(kind: .deleteNode, nodeId: node.id))
                        }
                    case .deleteNode:
                        if let nodeId = action.nodeId, let node = _nodes.first(where: { $0.id == nodeId }) {
                            reverseActions.append(WhiteboardAction(kind: .addNode, node: node))
                        }
                    case .connectNodes:
                        break
                    case .updateNode:
                        if let node = action.node, let old = _nodes.first(where: { $0.id == node.id }) {
                            reverseActions.append(WhiteboardAction(kind: .updateNode, node: old))
                        }
                    case .clear:
                        break
                    case .loadSnapshot:
                        break
                    }
                }
                if !reverseActions.isEmpty {
                    undoStack.append((forward: actions, reverse: reverseActions))
                    redoStack.removeAll()
                }
            }

            executeActionsLocked(actions)
        }
    }

    private func executeActionsLocked(_ actions: [WhiteboardAction]) {
        for rawAction in actions {
            let action = WhiteboardSanitizer.sanitizeAction(rawAction)
            switch action.kind {
            case .addNode, .addCard, .addFlowStep, .addTimelineEvent:
                if let node = action.node {
                    _nodes.removeAll { $0.id == node.id }
                    _nodes.append(node)
                }
            case .updateNode:
                if let node = action.node, let idx = _nodes.firstIndex(where: { $0.id == node.id }) {
                    _nodes[idx] = node
                }
            case .deleteNode:
                if let id = action.nodeId {
                    _nodes.removeAll { $0.id == id }
                    _connections.removeAll { $0.fromNodeId == id || $0.toNodeId == id }
                }
            case .connectNodes:
                if let conn = action.connection {
                    _connections.removeAll { $0.id == conn.id }
                    _connections.append(conn)
                }
            case .clear:
                _nodes.removeAll()
                _connections.removeAll()
            case .loadSnapshot:
                break
            }
        }
    }

    public func undo() {
        lock.withLock {
            guard let pair = undoStack.popLast() else { return }
            redoStack.append(pair)
            executeActionsLocked(pair.reverse)
        }
    }

    public func redo() {
        lock.withLock {
            guard let pair = redoStack.popLast() else { return }
            undoStack.append(pair)
            executeActionsLocked(pair.forward)
        }
    }

    public func generateSnapshot(sessionId: String) -> WhiteboardSnapshot {
        lock.withLock {
            let encoder = JSONEncoder()
            let elementsData = (try? encoder.encode(_nodes)) ?? Data()
            let elementsStr = String(data: elementsData, encoding: .utf8) ?? "[]"

            return WhiteboardSnapshot(
                sessionId: sessionId,
                elementsJSON: elementsStr,
                appStateJSON: "{\"viewBackgroundColor\": \"#ffffff\"}"
            )
        }
    }

    public func loadSnapshot(_ snapshot: WhiteboardSnapshot) {
        lock.withLock {
            let decoder = JSONDecoder()
            if let data = snapshot.elementsJSON.data(using: .utf8),
               let loadedNodes = try? decoder.decode([WhiteboardNode].self, from: data) {
                _nodes = loadedNodes.map { WhiteboardSanitizer.sanitizeNode($0) }
            }
            _connections.removeAll()
            undoStack.removeAll()
            redoStack.removeAll()
        }
    }
}
