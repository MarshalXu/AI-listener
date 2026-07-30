import AVFoundation
import Foundation
import Testing
@testable import AIListenerCore

@Suite(.serialized)
struct StreamingASRTests {
    final class FixtureEngine: LocalStreamingASREngine, @unchecked Sendable {
        let delay: TimeInterval
        let failAt: Int64?
        private let lock = NSLock()
        private(set) var sequences: [Int64] = []

        init(delay: TimeInterval = 0, failAt: Int64? = nil) {
            self.delay = delay
            self.failAt = failAt
        }

        func accept(_ frame: ASRInputFrame) throws -> [ASRTranscriptEvent] {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if frame.sequence == failAt { throw Failure.injected }
            lock.lock()
            sequences.append(frame.sequence)
            lock.unlock()
            return []
        }

        func finish() throws -> [ASRTranscriptEvent] { [] }
        enum Failure: Error { case injected }
    }

    final class LockedValues<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []
        func append(_ value: Value) { lock.withLock { storage.append(value) } }
        var values: [Value] { lock.withLock { storage } }
    }

    private func frame(_ sequence: Int64, sessionId: String = "00000000-0000-0000-0000-000000000001") -> ASRInputFrame {
        ASRInputFrame(
            sessionId: sessionId, sequence: sequence, startMs: sequence * 10,
            durationMs: 10, sampleRate: 16_000, samples: [0]
        )
    }

    private func pcmBuffer(
        sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2,
        frames: AVAudioFrameCount = 480
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = Float(channel + 1) * 0.1
            }
        }
        return buffer
    }

    @Test func frameConverterProducesOwned16kMonoSamplesAndMonotonicTiming() throws {
        let input = pcmBuffer()
        let converted = try ASRFrameConverter().convert(
            AudioFrame(buffer: input, monotonicNanoseconds: 1_010_000_000),
            sessionId: "session", sequence: 7,
            captureStartMonotonicNanoseconds: 1_000_000_000
        )

        #expect(converted.sampleRate == 16_000)
        #expect(converted.samples.count == 160)
        #expect(converted.startMs == 10)
        #expect(converted.durationMs == 10)
        #expect(converted.sequence == 7)
    }

    @Test func fanoutWritesBeforeOfferingASRAndWriterFailureStopsFanout() throws {
        enum WriterFailure: Error { case injected }
        let engine = FixtureEngine()
        let queue = BoundedASRQueue(
            capacity: 2, engine: engine, eventSink: { _ in }, diagnosticSink: { _ in }
        )
        let writes = LockedValues<String>()
        let fanout = WriterFirstAudioFanout(
            sessionId: "session", captureStartMonotonicNanoseconds: 0,
            writerSink: { _ in
                writes.append("write")
                throw WriterFailure.injected
            },
            queue: queue, diagnosticSink: { _ in }
        )

        #expect(throws: WriterFailure.self) {
            try fanout.consume(AudioFrame(buffer: pcmBuffer(), monotonicNanoseconds: 1))
        }
        #expect(queue.finish(deadline: Date().addingTimeInterval(1)))
        #expect(writes.values == ["write"])
        #expect(engine.sequences.isEmpty)
        #expect(queue.metrics().acceptedFrames == 0)
    }

    @Test func fanoutKeepsWritingWhenASREngineFails() throws {
        let engine = FixtureEngine(failAt: 0)
        let diagnostics = LockedValues<ASRDiagnostic>()
        let queue = BoundedASRQueue(
            capacity: 2, engine: engine, eventSink: { _ in },
            diagnosticSink: { diagnostics.append($0) }
        )
        let writes = LockedValues<Int>()
        let fanout = WriterFirstAudioFanout(
            sessionId: "session", captureStartMonotonicNanoseconds: 0,
            writerSink: { _ in writes.append(1) }, queue: queue,
            diagnosticSink: { diagnostics.append($0) }
        )

        try fanout.consume(AudioFrame(buffer: pcmBuffer(), monotonicNanoseconds: 1))
        Thread.sleep(forTimeInterval: 0.02)
        try fanout.consume(AudioFrame(buffer: pcmBuffer(), monotonicNanoseconds: 2))
        #expect(queue.finish(deadline: Date().addingTimeInterval(1)))
        #expect(writes.values.count == 2)
        #expect(queue.metrics().degraded)
        #expect(diagnostics.values.contains { $0.code == "ASR_ENGINE_FAILED" })
    }

    @Test func queueIsBoundedAndReportsGapWithoutBlockingProducer() {
        let engine = FixtureEngine(delay: 0.03)
        let diagnostics = LockedValues<ASRDiagnostic>()
        let queue = BoundedASRQueue(
            capacity: 2, engine: engine, eventSink: { _ in },
            diagnosticSink: { diagnostics.append($0) }
        )

        let start = Date()
        for sequence in 0..<100 { queue.offer(frame(Int64(sequence))) }
        let producerElapsed = Date().timeIntervalSince(start)
        #expect(producerElapsed < 0.1)
        #expect(queue.finish(deadline: Date().addingTimeInterval(2)))

        let metrics = queue.metrics()
        #expect(metrics.maximumDepth <= 2)
        #expect(metrics.droppedFrames > 0)
        #expect(metrics.acceptedFrames == metrics.processedFrames)
        #expect(diagnostics.values.contains { $0.code == "ASR_INPUT_GAP" })
    }

    @Test func engineFailureDegradesOnlyASRBranch() {
        let diagnostics = LockedValues<ASRDiagnostic>()
        let queue = BoundedASRQueue(
            capacity: 4, engine: FixtureEngine(failAt: 1), eventSink: { _ in },
            diagnosticSink: { diagnostics.append($0) }
        )
        #expect(queue.offer(frame(0)))
        #expect(queue.offer(frame(1)))
        #expect(queue.finish(deadline: Date().addingTimeInterval(2)))
        #expect(queue.metrics().degraded)
        #expect(diagnostics.values.contains { $0.code == "ASR_ENGINE_FAILED" })
    }

    @Test func transcriptCoordinatorRevisesPartialAndCommitsFinalizedExactlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ai-listener-asr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SessionStore(databaseURL: root.appending(path: "store.sqlite"))
        try store.insertSession(SessionRecord(
            sessionId: "00000000-0000-0000-0000-000000000001", state: "recording", transcriptState: "active",
            createdAtUtc: 1, captureStartMonotonicNs: 1
        ))
        let snapshots = LockedValues<[ASRTranscriptEvent]>()
        let coordinator = TranscriptEventCoordinator(
            sessionId: "00000000-0000-0000-0000-000000000001", store: store,
            partialSink: { snapshots.append($0) }
        )
        let base = ASRTranscriptEvent(
            segmentId: "segment", sessionId: "00000000-0000-0000-0000-000000000001", status: .partial,
            sequence: 0, revision: 0, startMs: 0, endMs: 100, text: "你",
            createdMonotonicMs: 1, engineId: "fixture", engineModelVersion: "1"
        )
        try await coordinator.consume(base)
        try await coordinator.consume(ASRTranscriptEvent(
            segmentId: "segment", sessionId: "00000000-0000-0000-0000-000000000001", status: .partial,
            sequence: 0, revision: 1, startMs: 0, endMs: 200, text: "你好",
            createdMonotonicMs: 2, engineId: "fixture", engineModelVersion: "1"
        ))
        let final = ASRTranscriptEvent(
            segmentId: "segment", sessionId: "00000000-0000-0000-0000-000000000001", status: .finalized,
            sequence: 0, revision: 2, startMs: 0, endMs: 200, text: "你好",
            createdMonotonicMs: 3, engineId: "fixture", engineModelVersion: "1"
        )
        try await coordinator.consume(final)
        try await coordinator.consume(final)

        #expect(try await coordinator.persistedSegmentCount() == 1)
        #expect(snapshots.values.contains { $0.first?.text == "你好" })
    }

    @Test func transcriptCoordinatorRejectsCrossSessionAndSequenceGap() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ai-listener-asr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SessionStore(databaseURL: root.appending(path: "store.sqlite"))
        try store.insertSession(SessionRecord(
            sessionId: "00000000-0000-0000-0000-000000000001", state: "recording", transcriptState: "active",
            createdAtUtc: 1, captureStartMonotonicNs: 1
        ))
        let coordinator = TranscriptEventCoordinator(
            sessionId: "00000000-0000-0000-0000-000000000001", store: store, partialSink: { _ in }
        )
        let wrong = ASRTranscriptEvent(
            segmentId: "x", sessionId: "00000000-0000-0000-0000-000000000002", status: .partial,
            sequence: 0, revision: 0, startMs: 0, endMs: 1, text: "x",
            createdMonotonicMs: 1, engineId: "fixture", engineModelVersion: "1"
        )
        await #expect(throws: SessionStoreError.self) { try await coordinator.consume(wrong) }
    }

    @Test func transcriptCoordinatorBuffersOutOfOrderFinalsAndCommitsInSequence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ai-listener-asr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SessionStore(databaseURL: root.appending(path: "store.sqlite"))
        let sessionId = "00000000-0000-0000-0000-000000000001"
        try store.insertSession(SessionRecord(
            sessionId: sessionId, state: "recording", transcriptState: "active",
            createdAtUtc: 1, captureStartMonotonicNs: 1
        ))
        let coordinator = TranscriptEventCoordinator(
            sessionId: sessionId, store: store, partialSink: { _ in }
        )
        func final(sequence: Int64, startMs: Int64) -> ASRTranscriptEvent {
            ASRTranscriptEvent(
                segmentId: "segment-\(sequence)", sessionId: sessionId, status: .finalized,
                sequence: sequence, revision: 0, startMs: startMs, endMs: startMs + 100,
                text: "文本\(sequence)", createdMonotonicMs: 10 - sequence,
                engineId: "fixture", engineModelVersion: "1"
            )
        }

        try await coordinator.consume(final(sequence: 1, startMs: 100))
        #expect(try await coordinator.persistedSegmentCount() == 0)
        try await coordinator.consume(final(sequence: 0, startMs: 0))
        #expect(try await coordinator.persistedSegmentCount() == 2)
    }

    @Test func transcriptCoordinatorReportsOverlappingFinalConflict() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ai-listener-asr-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SessionStore(databaseURL: root.appending(path: "store.sqlite"))
        let sessionId = "00000000-0000-0000-0000-000000000001"
        try store.insertSession(SessionRecord(
            sessionId: sessionId, state: "recording", transcriptState: "active",
            createdAtUtc: 1, captureStartMonotonicNs: 1
        ))
        let diagnostics = LockedValues<ASRDiagnostic>()
        let coordinator = TranscriptEventCoordinator(
            sessionId: sessionId, store: store, partialSink: { _ in },
            diagnosticSink: { diagnostics.append($0) }
        )
        func final(sequence: Int64, startMs: Int64) -> ASRTranscriptEvent {
            ASRTranscriptEvent(
                segmentId: "segment-\(sequence)", sessionId: sessionId, status: .finalized,
                sequence: sequence, revision: 0, startMs: startMs, endMs: startMs + 100,
                text: "文本", createdMonotonicMs: sequence,
                engineId: "fixture", engineModelVersion: "1"
            )
        }

        try await coordinator.consume(final(sequence: 0, startMs: 0))
        await #expect(throws: SessionStoreError.self) {
            try await coordinator.consume(final(sequence: 1, startMs: 50))
        }
        #expect(diagnostics.values.contains { $0.code == "TRANSCRIPT_ORDER_CONFLICT" })
        #expect(try await coordinator.persistedSegmentCount() == 1)
    }
}
