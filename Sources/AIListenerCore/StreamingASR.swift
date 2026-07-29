import Foundation

public struct ASRInputFrame: Sendable, Equatable {
    public let sessionId: String
    public let sequence: Int64
    public let startMs: Int64
    public let durationMs: Int64
    public let sampleRate: Int
    public let samples: [Float]

    public init(
        sessionId: String,
        sequence: Int64,
        startMs: Int64,
        durationMs: Int64,
        sampleRate: Int,
        samples: [Float]
    ) {
        self.sessionId = sessionId
        self.sequence = sequence
        self.startMs = startMs
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.samples = samples
    }
}

public struct ASRTranscriptEvent: Sendable, Equatable {
    public enum Status: String, Sendable {
        case partial
        case finalized
    }

    public let segmentId: String
    public let sessionId: String
    public let status: Status
    public let sequence: Int64
    public let revision: Int64
    public let startMs: Int64
    public let endMs: Int64
    public let text: String
    public let createdMonotonicMs: Int64
    public let engineId: String
    public let engineModelVersion: String

    public init(
        segmentId: String,
        sessionId: String,
        status: Status,
        sequence: Int64,
        revision: Int64,
        startMs: Int64,
        endMs: Int64,
        text: String,
        createdMonotonicMs: Int64,
        engineId: String,
        engineModelVersion: String
    ) {
        self.segmentId = segmentId
        self.sessionId = sessionId
        self.status = status
        self.sequence = sequence
        self.revision = revision
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.createdMonotonicMs = createdMonotonicMs
        self.engineId = engineId
        self.engineModelVersion = engineModelVersion
    }
}

public struct ASRDiagnostic: Sendable, Equatable {
    public let code: String
    public let sessionId: String
    public let firstDroppedSequence: Int64?
    public let lastDroppedSequence: Int64?

    public init(
        code: String,
        sessionId: String,
        firstDroppedSequence: Int64? = nil,
        lastDroppedSequence: Int64? = nil
    ) {
        self.code = code
        self.sessionId = sessionId
        self.firstDroppedSequence = firstDroppedSequence
        self.lastDroppedSequence = lastDroppedSequence
    }
}

/// A local engine boundary. Implementations must not perform network I/O.
public protocol LocalStreamingASREngine: AnyObject, Sendable {
    func accept(_ frame: ASRInputFrame) throws -> [ASRTranscriptEvent]
    func finish() throws -> [ASRTranscriptEvent]
}

public struct ASRQueueMetrics: Sendable, Equatable {
    public let capacity: Int
    public let acceptedFrames: Int64
    public let processedFrames: Int64
    public let droppedFrames: Int64
    public let maximumDepth: Int
    public let degraded: Bool
}

/// Non-blocking, bounded ASR branch. The writer remains on the capture path and
/// calls `offer` only after its own append succeeds.
public final class BoundedASRQueue: @unchecked Sendable {
    public typealias EventSink = @Sendable (ASRTranscriptEvent) -> Void
    public typealias DiagnosticSink = @Sendable (ASRDiagnostic) -> Void

    private let condition = NSCondition()
    private let capacity: Int
    private let engine: any LocalStreamingASREngine
    private let eventSink: EventSink
    private let diagnosticSink: DiagnosticSink
    private var frames: [ASRInputFrame] = []
    private var stopping = false
    private var workerFinished = false
    private var failed = false
    private var accepted: Int64 = 0
    private var processed: Int64 = 0
    private var dropped: Int64 = 0
    private var maximumDepth = 0
    private var pendingGap: (sessionId: String, first: Int64, last: Int64)?
    private var worker: Thread!

    public init(
        capacity: Int,
        engine: any LocalStreamingASREngine,
        eventSink: @escaping EventSink,
        diagnosticSink: @escaping DiagnosticSink
    ) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.engine = engine
        self.eventSink = eventSink
        self.diagnosticSink = diagnosticSink
        worker = Thread { [weak self] in self?.run() }
        worker.qualityOfService = .userInitiated
        worker.start()
    }

    /// Returns immediately. When full, the newest ASR frame is dropped and a
    /// coalesced gap is emitted by the worker; no capture/writer backpressure.
    @discardableResult
    public func offer(_ frame: ASRInputFrame) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !stopping, !failed else { return false }
        guard frames.count < capacity else {
            dropped += 1
            if var gap = pendingGap, gap.sessionId == frame.sessionId {
                gap.last = frame.sequence
                pendingGap = gap
            } else {
                pendingGap = (frame.sessionId, frame.sequence, frame.sequence)
            }
            condition.signal()
            return false
        }
        frames.append(frame)
        accepted += 1
        maximumDepth = max(maximumDepth, frames.count)
        condition.signal()
        return true
    }

    public func finish(deadline: Date) -> Bool {
        condition.lock()
        stopping = true
        condition.broadcast()
        while !workerFinished {
            if !condition.wait(until: deadline) { break }
        }
        let finished = workerFinished
        condition.unlock()
        return finished
    }

    public func metrics() -> ASRQueueMetrics {
        condition.lock()
        defer { condition.unlock() }
        return ASRQueueMetrics(
            capacity: capacity, acceptedFrames: accepted, processedFrames: processed,
            droppedFrames: dropped, maximumDepth: maximumDepth, degraded: failed || dropped > 0
        )
    }

    private func run() {
        while true {
            condition.lock()
            if let gap = pendingGap {
                pendingGap = nil
                condition.unlock()
                diagnosticSink(ASRDiagnostic(
                    code: "ASR_INPUT_GAP", sessionId: gap.sessionId,
                    firstDroppedSequence: gap.first, lastDroppedSequence: gap.last
                ))
                continue
            }
            while frames.isEmpty && !stopping {
                condition.wait()
                if pendingGap != nil { break }
            }
            if pendingGap != nil {
                condition.unlock()
                continue
            }
            if frames.isEmpty && stopping {
                condition.unlock()
                flushAndExit()
                return
            }
            let frame = frames.removeFirst()
            condition.unlock()

            do {
                try engine.accept(frame).forEach(eventSink)
                condition.lock()
                processed += 1
                condition.unlock()
            } catch {
                condition.lock()
                failed = true
                frames.removeAll(keepingCapacity: false)
                condition.unlock()
                diagnosticSink(ASRDiagnostic(code: "ASR_ENGINE_FAILED", sessionId: frame.sessionId))
            }
        }
    }

    private func flushAndExit() {
        if !failed {
            do {
                try engine.finish().forEach(eventSink)
            } catch {
                diagnosticSink(ASRDiagnostic(code: "ASR_FINISH_FAILED", sessionId: "unknown"))
            }
        }
        condition.lock()
        workerFinished = true
        condition.broadcast()
        condition.unlock()
    }
}

public actor TranscriptEventCoordinator {
    public typealias PartialSink = @MainActor @Sendable ([ASRTranscriptEvent]) -> Void
    public typealias DiagnosticSink = @Sendable (ASRDiagnostic) -> Void

    private let sessionId: String
    private let store: SessionStore
    private let partialSink: PartialSink
    private let diagnosticSink: DiagnosticSink
    private var partials: [String: ASRTranscriptEvent] = [:]
    private var pendingFinals: [Int64: ASRTranscriptEvent] = [:]
    private var seen: Set<String> = []
    private var nextFinalSequence: Int64 = 0

    public init(
        sessionId: String,
        store: SessionStore,
        partialSink: @escaping PartialSink,
        diagnosticSink: @escaping DiagnosticSink = { _ in }
    ) {
        self.sessionId = sessionId
        self.store = store
        self.partialSink = partialSink
        self.diagnosticSink = diagnosticSink
    }

    public func consume(_ event: ASRTranscriptEvent) throws {
        guard event.sessionId == sessionId else {
            throw SessionStoreError.invalidContract("crossSessionSegment")
        }
        let identity = "\(event.segmentId):\(event.revision)"
        guard seen.insert(identity).inserted else { return }
        guard event.startMs >= 0, event.endMs > event.startMs else {
            throw SessionStoreError.invalidContract("segmentTime")
        }

        switch event.status {
        case .partial:
            if let current = partials[event.segmentId], current.revision >= event.revision { return }
            partials[event.segmentId] = event
            publishPartials()
        case .finalized:
            guard !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SessionStoreError.invalidContract("segmentText")
            }
            guard event.sequence >= nextFinalSequence else {
                throw SessionStoreError.invalidContract("segmentSequence")
            }
            if let pending = pendingFinals[event.sequence],
               pending.createdMonotonicMs <= event.createdMonotonicMs {
                return
            }
            pendingFinals[event.sequence] = event
            try drainFinals()
        }
    }

    public func persistedSegmentCount() throws -> Int {
        try store.transcriptSegmentCount(sessionId: sessionId)
    }

    private func publishPartials() {
        let snapshot = partials.values.sorted {
            ($0.startMs, $0.createdMonotonicMs) < ($1.startMs, $1.createdMonotonicMs)
        }
        Task { @MainActor in partialSink(snapshot) }
    }

    private func drainFinals() throws {
        while let event = pendingFinals[nextFinalSequence] {
            do {
                try store.insertTranscriptSegment(TranscriptSegmentRecord(
                    segmentId: event.segmentId, sessionId: event.sessionId,
                    revisionOf: nil, status: "finalized", sequence: event.sequence,
                    revision: event.revision, startMs: event.startMs, endMs: event.endMs,
                    text: event.text, createdMonotonicMs: event.createdMonotonicMs,
                    engineId: event.engineId, engineModelVersion: event.engineModelVersion
                ))
            } catch SessionStoreError.invalidContract("transcriptOrderConflict") {
                pendingFinals.removeValue(forKey: nextFinalSequence)
                diagnosticSink(ASRDiagnostic(
                    code: "TRANSCRIPT_ORDER_CONFLICT", sessionId: sessionId
                ))
                throw SessionStoreError.invalidContract("transcriptOrderConflict")
            }
            pendingFinals.removeValue(forKey: nextFinalSequence)
            nextFinalSequence += 1
            partials.removeValue(forKey: event.segmentId)
            publishPartials()
        }
    }
}
