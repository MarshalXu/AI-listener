@preconcurrency import AVFoundation
import Foundation

public enum RecordingSessionPipelineError: Error, Equatable {
    case noAudioFrames
    case alreadyFinished
    case asrFinishTimedOut
}

/// Product-level recording pipeline used by the app: durable audio is written
/// before each frame is offered to local ASR, and finalized ASR events are
/// committed to the same session before the audio asset becomes playable.
public final class RecordingSessionPipeline: @unchecked Sendable {
    public typealias PartialSink = @MainActor @Sendable ([ASRTranscriptEvent]) -> Void
    public typealias FinalizedSink = @MainActor @Sendable (ASRTranscriptEvent) -> Void
    public typealias DiagnosticSink = @Sendable (ASRDiagnostic) -> Void

    public let sessionId: String
    private let store: SessionStore
    private let session: SessionRecord
    private let writer: AtomicAudioAssetWriter
    private let engine: any LocalStreamingASREngine
    private let partialSink: PartialSink
    private let finalizedSink: FinalizedSink
    private let diagnosticSink: DiagnosticSink
    private let lock = NSLock()
    private var beganWriting = false
    private var finished = false
    private lazy var transcript = TranscriptEventCoordinator(
        sessionId: sessionId,
        store: store,
        partialSink: partialSink,
        finalizedSink: finalizedSink,
        diagnosticSink: diagnosticSink
    )
    private lazy var queue = BoundedASRQueue(
        capacity: 64,
        engine: engine,
        eventSink: { [weak self] event in self?.consumeTranscriptSynchronously(event) },
        diagnosticSink: diagnosticSink
    )
    private lazy var fanout = WriterFirstAudioFanout(
        sessionId: sessionId,
        captureStartMonotonicNanoseconds: UInt64(session.captureStartMonotonicNs),
        writerSink: { [weak self] buffer in try self?.write(buffer) },
        queue: queue,
        diagnosticSink: diagnosticSink
    )

    public init(
        store: SessionStore,
        assetRoot: URL,
        engine: any LocalStreamingASREngine,
        sessionId: String = UUID().uuidString,
        createdAtUtc: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        captureStartMonotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        partialSink: @escaping PartialSink,
        finalizedSink: @escaping FinalizedSink,
        diagnosticSink: @escaping DiagnosticSink
    ) throws {
        self.sessionId = sessionId
        self.store = store
        self.engine = engine
        self.partialSink = partialSink
        self.finalizedSink = finalizedSink
        self.diagnosticSink = diagnosticSink
        session = SessionRecord(
            sessionId: sessionId, state: "recording", transcriptState: "active",
            createdAtUtc: createdAtUtc,
            captureStartMonotonicNs: Int64(clamping: captureStartMonotonicNanoseconds)
        )
        writer = try AtomicAudioAssetWriter(assetRoot: assetRoot, session: session)
    }

    public func consume(_ frame: AudioFrame) throws {
        lock.lock()
        let isFinished = finished
        lock.unlock()
        guard !isFinished else { throw RecordingSessionPipelineError.alreadyFinished }
        try fanout.consume(frame)
    }

    @discardableResult
    public func finish(
        deadline: Date = Date().addingTimeInterval(10)
    ) throws -> AudioAssetRecord {
        lock.lock()
        guard !finished else {
            lock.unlock()
            throw RecordingSessionPipelineError.alreadyFinished
        }
        finished = true
        let hasAudio = beganWriting
        lock.unlock()
        guard hasAudio else { throw RecordingSessionPipelineError.noAudioFrames }
        guard queue.finish(deadline: deadline) else {
            throw RecordingSessionPipelineError.asrFinishTimedOut
        }
        return try writer.finalize(into: store)
    }

    private func write(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        let needsBegin = !beganWriting
        if needsBegin { beganWriting = true }
        lock.unlock()
        if needsBegin {
            do {
                try writer.begin(format: buffer.format, store: store)
            } catch {
                lock.lock()
                beganWriting = false
                lock.unlock()
                throw error
            }
        }
        try writer.write(buffer)
    }

    private func consumeTranscriptSynchronously(_ event: ASRTranscriptEvent) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                try await transcript.consume(event)
            } catch {
                diagnosticSink(ASRDiagnostic(code: "TRANSCRIPT_PERSIST_FAILED", sessionId: sessionId))
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}
