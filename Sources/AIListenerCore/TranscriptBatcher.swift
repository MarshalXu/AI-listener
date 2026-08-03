import Foundation

/// A thread-safe, non-blocking batcher that buffers incoming transcript items and flushes them
/// based on count threshold, idle timeout, max wait timeout, or manual flush.
public final class TranscriptBatcher<Element: Sendable>: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var maxCount: Int
        public var idleTimeout: TimeInterval
        public var maxWaitTimeout: TimeInterval

        public init(
            maxCount: Int = 5,
            idleTimeout: TimeInterval = 10.0,
            maxWaitTimeout: TimeInterval = 30.0
        ) {
            self.maxCount = maxCount
            self.idleTimeout = idleTimeout
            self.maxWaitTimeout = maxWaitTimeout
        }
    }

    private let lock = NSLock()
    private let config: Configuration
    private let onFlush: @Sendable ([Element]) -> Void

    private var buffer: [Element] = []
    private var idleTimer: DispatchSourceTimer?
    private var maxWaitTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "AIListenerCore.TranscriptBatcher", qos: .userInitiated)

    public var currentBufferCount: Int {
        lock.withLock { buffer.count }
    }

    public init(
        config: Configuration = Configuration(),
        onFlush: @escaping @Sendable ([Element]) -> Void
    ) {
        self.config = config
        self.onFlush = onFlush
    }

    public func append(_ item: Element) {
        lock.lock()
        buffer.append(item)
        let count = buffer.count

        if count >= config.maxCount {
            let itemsToFlush = buffer
            buffer.removeAll()
            cancelTimersLocked()
            lock.unlock()

            notifyFlush(itemsToFlush)
            return
        }

        // Schedule or reset idle timer
        scheduleIdleTimerLocked()

        // Schedule max wait timer on the first item of a batch
        if count == 1 {
            scheduleMaxWaitTimerLocked()
        }

        lock.unlock()
    }

    public func flush() {
        lock.lock()
        guard !buffer.isEmpty else {
            cancelTimersLocked()
            lock.unlock()
            return
        }
        let itemsToFlush = buffer
        buffer.removeAll()
        cancelTimersLocked()
        lock.unlock()

        notifyFlush(itemsToFlush)
    }

    public func reset() {
        lock.lock()
        buffer.removeAll()
        cancelTimersLocked()
        lock.unlock()
    }

    private func scheduleIdleTimerLocked() {
        idleTimer?.cancel()
        idleTimer = nil

        guard config.idleTimeout > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.idleTimeout)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        idleTimer = timer
    }

    private func scheduleMaxWaitTimerLocked() {
        maxWaitTimer?.cancel()
        maxWaitTimer = nil

        guard config.maxWaitTimeout > 0 else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.maxWaitTimeout)
        timer.setEventHandler { [weak self] in
            self?.flush()
        }
        timer.resume()
        maxWaitTimer = timer
    }

    private func cancelTimersLocked() {
        idleTimer?.cancel()
        idleTimer = nil
        maxWaitTimer?.cancel()
        maxWaitTimer = nil
    }

    private func notifyFlush(_ items: [Element]) {
        guard !items.isEmpty else { return }
        onFlush(items)
    }

    deinit {
        reset()
    }
}
