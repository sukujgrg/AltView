import Foundation

/// A bounded handoff between queues: at most one value and one scheduled job.
/// Producers never wait for network I/O or the consumer's execution.
final class SnapshotMailbox<Value> {
    private let lock = NSLock()
    private var latest: Value?
    private var scheduled = false
    private let queue: DispatchQueue
    private let consume: (Value) -> Void
    init(queue: DispatchQueue, consume: @escaping (Value) -> Void) { self.queue = queue; self.consume = consume }
    func offer(_ value: Value) {
        lock.lock()
        latest = value
        let needsSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if needsSchedule { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        lock.lock()
        let value = latest
        latest = nil
        scheduled = false
        lock.unlock()
        if let value { consume(value) }
    }
}
