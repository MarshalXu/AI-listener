import AVFoundation
import Foundation
import Testing
@testable import AIListenerCore

@Suite(.serialized)
struct StreamingASRTests {
    @Test func bundledPathsUseStandardFrameworksAndResourcesDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "AIListener-bundle-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: root) }
        let frameworks = root.appending(path: "Contents/Frameworks")
        let model = root.appending(path: "Contents/Resources/Model")
        try FileManager.default.createDirectory(at: frameworks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("runtime".utf8).write(
            to: frameworks.appending(path: "libsherpa-onnx-c-api.dylib")
        )
        for name in [
            "encoder-epoch-99-avg-1.int8.onnx", "decoder-epoch-99-avg-1.onnx",
            "joiner-epoch-99-avg-1.int8.onnx", "tokens.txt",
        ] {
            try Data(name.utf8).write(to: model.appending(path: name))
        }
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>com.ailistener.fixture</string>
        <key>CFBundleName</key><string>AIListenerFixture</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        </dict></plist>
        """.utf8).write(to: root.appending(path: "Contents/Info.plist"))

        let bundle = try #require(Bundle(url: root))
        let paths = try #require(SherpaModelPaths.bundled(in: bundle))
        #expect(paths.library.path == frameworks.appending(path: "libsherpa-onnx-c-api.dylib").path)
        #expect(paths.tokens.path == model.appending(path: "tokens.txt").path)
    }

    @Test func sherpaAdapterRejectsMissingRuntimeBeforeLoadingModel() {
        let root = URL(fileURLWithPath: "/definitely-missing-ai-listener-runtime")
        #expect(throws: SherpaStreamingASRError.missingFile("library")) {
            _ = try SherpaStreamingASREngine(
                paths: SherpaModelPaths(
                    library: root.appending(path: "libsherpa.dylib"),
                    encoder: root.appending(path: "encoder.onnx"),
                    decoder: root.appending(path: "decoder.onnx"),
                    joiner: root.appending(path: "joiner.onnx"),
                    tokens: root.appending(path: "tokens.txt")
                ),
                modelVersion: "fixture"
            )
        }
    }

    @Test func sherpaAdapterDecodesApprovedPublicFixture() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = repository.appending(
            path: "evidence/AI-4/runtime/sherpa-onnx-v1.13.2-osx-arm64-shared-no-tts/lib"
        )
        let model = repository.appending(
            path: "evidence/AI-4/models/sherpa-onnx-streaming-zipformer-zh-14M-2023-02-23"
        )
        let engine = try SherpaStreamingASREngine(
            paths: SherpaModelPaths(
                library: runtime.appending(path: "libsherpa-onnx-c-api.dylib"),
                encoder: model.appending(path: "encoder-epoch-99-avg-1.int8.onnx"),
                decoder: model.appending(path: "decoder-epoch-99-avg-1.onnx"),
                joiner: model.appending(path: "joiner-epoch-99-avg-1.int8.onnx"),
                tokens: model.appending(path: "tokens.txt")
            ),
            modelVersion: "zh-14M-2023-02-23"
        )
        let audio = try AVAudioFile(forReading: model.appending(path: "test_wavs/0.wav"))
        let format = audio.processingFormat
        let chunkFrames: AVAudioFrameCount = 3_200
        var events: [ASRTranscriptEvent] = []
        var sequence: Int64 = 0
        var startMs: Int64 = 0
        while audio.framePosition < audio.length {
            let remaining = AVAudioFrameCount(audio.length - audio.framePosition)
            let count = min(chunkFrames, remaining)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
            try audio.read(into: buffer, frameCount: count)
            let samples = Array(UnsafeBufferPointer(
                start: buffer.floatChannelData![0], count: Int(buffer.frameLength)
            ))
            let duration = Int64(Double(samples.count) / format.sampleRate * 1_000)
            events += try engine.accept(ASRInputFrame(
                sessionId: "public-fixture", sequence: sequence, startMs: startMs,
                durationMs: duration, sampleRate: Int(format.sampleRate), samples: samples
            ))
            sequence += 1
            startMs += duration
        }
        events += try engine.finish()
        #expect(events.contains { !$0.text.isEmpty })
        #expect(events.contains { $0.status == .finalized })
        #expect(events.allSatisfy { $0.engineId == "sherpa-onnx" })
    }

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

    @Test func productPipelineWritesAudioRunsASRAndPersistsFinalizedTranscript() throws {
        final class ProductEngine: LocalStreamingASREngine, @unchecked Sendable {
            private var last: ASRInputFrame?

            func accept(_ frame: ASRInputFrame) throws -> [ASRTranscriptEvent] {
                last = frame
                return [ASRTranscriptEvent(
                    segmentId: "\(frame.sessionId)-0", sessionId: frame.sessionId,
                    status: .partial, sequence: 0, revision: 0,
                    startMs: frame.startMs, endMs: max(frame.startMs + frame.durationMs, 1),
                    text: "你好", createdMonotonicMs: 1,
                    engineId: "fixture", engineModelVersion: "product-wiring"
                )]
            }

            func finish() throws -> [ASRTranscriptEvent] {
                guard let frame = last else { return [] }
                return [ASRTranscriptEvent(
                    segmentId: "\(frame.sessionId)-0", sessionId: frame.sessionId,
                    status: .finalized, sequence: 0, revision: 1,
                    startMs: frame.startMs, endMs: max(frame.startMs + frame.durationMs, 1),
                    text: "你好世界", createdMonotonicMs: 2,
                    engineId: "fixture", engineModelVersion: "product-wiring"
                )]
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appending(path: "ai-listener-product-pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appending(path: "Audio")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let store = try SessionStore(databaseURL: root.appending(path: "sessions.sqlite"))
        let sessionId = UUID().uuidString
        let pipeline = try RecordingSessionPipeline(
            store: store, assetRoot: assets, engine: ProductEngine(),
            sessionId: sessionId, captureStartMonotonicNanoseconds: 1,
            partialSink: { _ in }, finalizedSink: { _ in }, diagnosticSink: { _ in }
        )

        try pipeline.consume(AudioFrame(
            buffer: pcmBuffer(channels: 1), monotonicNanoseconds: 1
        ))
        let asset = try pipeline.finish()

        #expect(FileManager.default.fileExists(atPath: assets.appending(path: asset.relativePath).path))
        #expect(try store.transcriptSegmentCount(sessionId: sessionId) == 1)
        let detail = try #require(try store.playableSession(sessionId: sessionId))
        #expect(detail.session.state == "ready")
        #expect(detail.segments.map(\.text) == ["你好世界"])
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
