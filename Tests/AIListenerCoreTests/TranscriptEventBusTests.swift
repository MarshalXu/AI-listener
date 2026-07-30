import AIListenerCore
import Foundation
import Testing

struct TranscriptEventBusTests {
    @Test
    func testSubscribeAndPublishPartialsAndFinalized() async throws {
        let bus = TranscriptEventBus()
        let receivedEvents = LockIsolated<[TranscriptBusEvent]>([])

        let subscription = bus.subscribe { event in
            receivedEvents.withValue { $0.append(event) }
        }

        let partial = ASRTranscriptEvent(
            segmentId: "seg-1", sessionId: "sess-1", status: .partial, sequence: 0,
            revision: 1, startMs: 0, endMs: 500, text: "hello",
            createdMonotonicMs: 100, engineId: "mock", engineModelVersion: "v1"
        )
        let finalized = ASRTranscriptEvent(
            segmentId: "seg-1", sessionId: "sess-1", status: .finalized, sequence: 0,
            revision: 2, startMs: 0, endMs: 1000, text: "hello world",
            createdMonotonicMs: 200, engineId: "mock", engineModelVersion: "v1"
        )

        bus.publishPartials([partial])
        bus.publishFinalized(finalized)

        for _ in 0..<50 {
            if receivedEvents.withValue({ $0.count }) == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let events = receivedEvents.withValue { $0 }
        #expect(events.count == 2)
        #expect(events[0] == .partials([partial]))
        #expect(events[1] == .finalized(finalized))

        subscription.cancel()
    }

    @Test
    func testStressOrderConsistencyWithMultipleSubscribers() async throws {
        let bus = TranscriptEventBus()
        let totalEvents = 200

        let subscriber1Events = LockIsolated<[Int]>([])
        let subscriber2Events = LockIsolated<[Int]>([])
        let subscriber3Events = LockIsolated<[Int]>([])

        let sub1 = bus.subscribe { event in
            if case .reset(let sessionId) = event, let index = Int(sessionId) {
                subscriber1Events.withValue { $0.append(index) }
            }
        }
        let sub2 = bus.subscribe { event in
            if case .reset(let sessionId) = event, let index = Int(sessionId) {
                subscriber2Events.withValue { $0.append(index) }
            }
        }
        let sub3 = bus.subscribe { event in
            if case .reset(let sessionId) = event, let index = Int(sessionId) {
                subscriber3Events.withValue { $0.append(index) }
            }
        }

        // Publish totalEvents resets sequentially
        for i in 0..<totalEvents {
            bus.publishReset(sessionId: "\(i)")
        }

        for _ in 0..<100 {
            let c1 = subscriber1Events.withValue { $0.count }
            let c2 = subscriber2Events.withValue { $0.count }
            let c3 = subscriber3Events.withValue { $0.count }
            if c1 == totalEvents && c2 == totalEvents && c3 == totalEvents { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let expected = Array(0..<totalEvents)
        #expect(subscriber1Events.withValue { $0 } == expected)
        #expect(subscriber2Events.withValue { $0 } == expected)
        #expect(subscriber3Events.withValue { $0 } == expected)

        sub1.cancel()
        sub2.cancel()
        sub3.cancel()
    }

    @Test
    func testCancellationUnsubscribes() async throws {
        let bus = TranscriptEventBus()
        let receivedEvents = LockIsolated<[TranscriptBusEvent]>([])

        let subscription = bus.subscribe { event in
            receivedEvents.withValue { $0.append(event) }
        }

        let event1 = ASRTranscriptEvent(
            segmentId: "s1", sessionId: "sess-1", status: .partial, sequence: 0,
            revision: 1, startMs: 0, endMs: 500, text: "first",
            createdMonotonicMs: 100, engineId: "mock", engineModelVersion: "v1"
        )
        bus.publishPartials([event1])

        for _ in 0..<50 {
            if receivedEvents.withValue({ $0.count }) == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(receivedEvents.withValue { $0.count } == 1)

        subscription.cancel()

        let event2 = ASRTranscriptEvent(
            segmentId: "s2", sessionId: "sess-1", status: .finalized, sequence: 1,
            revision: 1, startMs: 500, endMs: 1000, text: "second",
            createdMonotonicMs: 200, engineId: "mock", engineModelVersion: "v1"
        )
        bus.publishFinalized(event2)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(receivedEvents.withValue { $0.count } == 1)
    }

    @Test
    func testAsyncStream() async throws {
        let bus = TranscriptEventBus()
        let stream = bus.stream()

        Task {
            try await Task.sleep(nanoseconds: 20_000_000)
            bus.publishReset(sessionId: "sess-test")
        }

        var received: TranscriptBusEvent?
        for await event in stream {
            received = event
            break
        }

        #expect(received == .reset(sessionId: "sess-test"))
    }

    @Test
    func testFaultIsolationSlowSubscriberDoesNotBlockPublisherOrOtherSubscribers() async throws {
        let bus = TranscriptEventBus()
        let fastReceived = LockIsolated<[Int]>([])
        let slowReceived = LockIsolated<[Int]>([])

        // Slow subscriber sleeps on its own serial queue for each item
        let subSlow = bus.subscribe { event in
            Thread.sleep(forTimeInterval: 0.005)
            if case .reset(let id) = event, let idx = Int(id) {
                slowReceived.withValue { $0.append(idx) }
            }
        }

        // Fast subscriber processes immediately
        let subFast = bus.subscribe { event in
            if case .reset(let id) = event, let idx = Int(id) {
                fastReceived.withValue { $0.append(idx) }
            }
        }

        let start = Date()
        let eventCount = 20
        for i in 0..<eventCount {
            bus.publishReset(sessionId: "\(i)")
        }
        let elapsed = Date().timeIntervalSince(start)

        // Publisher MUST be non-blocking (< 50ms for 20 publishes, despite slow subscriber taking 20 * 5ms = 100ms)
        #expect(elapsed < 0.05)

        // Fast subscriber should receive all events very quickly (< 100ms total)
        for _ in 0..<50 {
            if fastReceived.withValue({ $0.count }) == eventCount { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let expected = Array(0..<eventCount)
        #expect(fastReceived.withValue { $0 } == expected)

        // Wait for slow subscriber to finish processing its queue
        for _ in 0..<100 {
            if slowReceived.withValue({ $0.count }) == eventCount { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(slowReceived.withValue { $0 } == expected)

        subSlow.cancel()
        subFast.cancel()
    }
}

private final class LockIsolated<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ initial: Value) {
        self._value = initial
    }

    func withValue<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&_value)
    }
}
