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
}
