import Foundation

public enum TranscriptBusEvent: Sendable, Equatable {
    case partials([ASRTranscriptEvent])
    case finalized(ASRTranscriptEvent)
    case reset(sessionId: String)
}

public final class TranscriptBusSubscription: @unchecked Sendable {
    private let onCancel: @Sendable () -> Void
    private let lock = NSLock()
    private var isCancelled = false

    public init(onCancel: @escaping @Sendable () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        lock.unlock()
        onCancel()
    }

    deinit {
        cancel()
    }
}

/// Thread-safe, non-blocking transcript event bus for distributing real-time ASR events.
///
/// Guaranteed semantics:
/// 1. Per-subscriber FIFO ordering: Every event delivered to a given subscriber arrives on a dedicated
///    serial queue in strict publish order.
/// 2. Subscriber fault & latency isolation: Each subscriber executes on its own serial queue. A slow or
///    blocking subscriber does not delay or block other subscribers or the publisher.
/// 3. Publisher non-blocking delivery: `publish` enqueues events asynchronously and returns immediately.
public final class TranscriptEventBus: @unchecked Sendable {
    public typealias SubscriberHandler = @Sendable (TranscriptBusEvent) -> Void

    private final class SubscriberState: @unchecked Sendable {
        let id: UUID
        let handler: SubscriberHandler
        let queue: DispatchQueue
        private let lock = NSLock()
        private var isCancelled = false

        init(id: UUID, handler: @escaping SubscriberHandler) {
            self.id = id
            self.handler = handler
            self.queue = DispatchQueue(
                label: "AIListenerCore.TranscriptEventBus.subscriber.\(id.uuidString)",
                qos: .userInitiated
            )
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        func dispatch(_ event: TranscriptBusEvent) {
            queue.async { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                let cancelled = self.isCancelled
                self.lock.unlock()
                guard !cancelled else { return }
                self.handler(event)
            }
        }
    }

    private let lock = NSLock()
    private var subscribers: [UUID: SubscriberState] = [:]

    public init() {}

    /// Subscribes a handler callback to receive transcript events asynchronously.
    /// The return token automatically cancels subscription on deinit or explicit `cancel()`.
    @discardableResult
    public func subscribe(
        onEvent: @escaping @Sendable (TranscriptBusEvent) -> Void
    ) -> TranscriptBusSubscription {
        let id = UUID()
        let state = SubscriberState(id: id, handler: onEvent)

        lock.lock()
        subscribers[id] = state
        lock.unlock()

        return TranscriptBusSubscription { [weak self] in
            self?.unsubscribe(id: id)
        }
    }

    /// Creates an AsyncStream for listening to transcript events using async/await.
    public func stream() -> AsyncStream<TranscriptBusEvent> {
        AsyncStream { continuation in
            let subscription = self.subscribe { event in
                continuation.yield(event)
            }
            continuation.onTermination = { _ in
                subscription.cancel()
            }
        }
    }

    /// Publishes an event to all subscribers asynchronously without blocking the caller.
    public func publish(_ event: TranscriptBusEvent) {
        lock.lock()
        let states = Array(subscribers.values)
        lock.unlock()

        for state in states {
            state.dispatch(event)
        }
    }

    public func publishPartials(_ partials: [ASRTranscriptEvent]) {
        publish(.partials(partials))
    }

    public func publishFinalized(_ event: ASRTranscriptEvent) {
        publish(.finalized(event))
    }

    public func publishReset(sessionId: String) {
        publish(.reset(sessionId: sessionId))
    }

    private func unsubscribe(id: UUID) {
        lock.lock()
        let state = subscribers.removeValue(forKey: id)
        lock.unlock()
        state?.cancel()
    }
}
