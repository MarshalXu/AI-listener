import Foundation
import Testing
@testable import AIListenerCore

private final class ThreadSafeBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

struct TranscriptBatcherTests {
    @Test func testBatcherCountThresholdTrigger() async throws {
        let expectation = ThreadSafeBox<[[String]]>([])
        let batcher = TranscriptBatcher<String>(
            config: .init(maxCount: 3, idleTimeout: 10.0, maxWaitTimeout: 30.0)
        ) { items in
            expectation.withLock { $0.append(items) }
        }

        batcher.append("句一")
        batcher.append("句二")
        #expect(batcher.currentBufferCount == 2)
        #expect(expectation.withLock { $0.isEmpty })

        batcher.append("句三") // Should trigger flush
        #expect(batcher.currentBufferCount == 0)

        let flushed = expectation.withLock { $0 }
        #expect(flushed.count == 1)
        #expect(flushed.first == ["句一", "句二", "句三"])
    }

    @Test func testBatcherIdleTimeoutTrigger() async throws {
        let expectation = ThreadSafeBox<[[String]]>([])
        let batcher = TranscriptBatcher<String>(
            config: .init(maxCount: 10, idleTimeout: 0.1, maxWaitTimeout: 5.0)
        ) { items in
            expectation.withLock { $0.append(items) }
        }

        batcher.append("停顿前的句子")
        #expect(batcher.currentBufferCount == 1)

        // Wait for idle timeout
        try await Task.sleep(nanoseconds: 200_000_000)

        let flushed = expectation.withLock { $0 }
        #expect(flushed.count == 1)
        #expect(flushed.first == ["停顿前的句子"])
        #expect(batcher.currentBufferCount == 0)
    }

    @Test func testBatcherMaxWaitTimeoutTrigger() async throws {
        let expectation = ThreadSafeBox<[[String]]>([])
        let batcher = TranscriptBatcher<String>(
            config: .init(maxCount: 100, idleTimeout: 0.5, maxWaitTimeout: 0.2)
        ) { items in
            expectation.withLock { $0.append(items) }
        }

        batcher.append("第一句")

        // Keep appending every 0.05s so idle timeout (0.5s) never triggers, but max wait timeout (0.2s) will
        for i in 2...5 {
            try await Task.sleep(nanoseconds: 50_000_000)
            batcher.append("第\(i)句")
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let flushed = expectation.withLock { $0 }
        #expect(!flushed.isEmpty)
    }

    @Test func testBatcherManualFlushAndReset() async throws {
        let expectation = ThreadSafeBox<[[String]]>([])
        let batcher = TranscriptBatcher<String>(
            config: .init(maxCount: 10, idleTimeout: 10.0, maxWaitTimeout: 30.0)
        ) { items in
            expectation.withLock { $0.append(items) }
        }

        batcher.append("A")
        batcher.append("B")
        #expect(batcher.currentBufferCount == 2)

        batcher.flush()
        #expect(batcher.currentBufferCount == 0)
        #expect(expectation.withLock { $0.count } == 1)

        batcher.append("C")
        batcher.reset()
        #expect(batcher.currentBufferCount == 0)
        #expect(expectation.withLock { $0.count } == 1) // No new flush on reset
    }

    @Test func testWhiteboardServiceWithBatchingIntegration() async throws {
        let bus = TranscriptEventBus()
        let service = WhiteboardService(
            batcherConfig: .init(maxCount: 3, idleTimeout: 10.0, maxWaitTimeout: 30.0)
        )
        service.subscribeToBus(bus)

        func makeEvent(_ seq: Int64, _ text: String) -> ASRTranscriptEvent {
            ASRTranscriptEvent(
                segmentId: "seg-\(seq)",
                sessionId: "s1",
                status: .finalized,
                sequence: seq,
                revision: 1,
                startMs: seq * 1000,
                endMs: (seq + 1) * 1000,
                text: text,
                createdMonotonicMs: seq * 1000,
                engineId: "mock",
                engineModelVersion: "v1"
            )
        }

        bus.publishFinalized(makeEvent(1, "首先流程一"))
        bus.publishFinalized(makeEvent(2, "其次流程二"))

        // Count is 2 (< 3), service nodes should still be 0
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(service.nodes.count == 0)

        bus.publishFinalized(makeEvent(3, "然后流程三"))

        // 3rd event triggers batch flush -> generates actions
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(service.nodes.count > 0)
    }
}
