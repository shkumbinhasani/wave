import Foundation

/// Accepts wakeups from any thread, keeping at most one action queued.
/// The serial target queue (the main queue in the app) owns action execution.
final class CoalescedAction {
    private let queue: DispatchQueue
    private let action: () -> Void
    private let lock = NSLock()
    private var pending = false

    init(queue: DispatchQueue = .main, action: @escaping () -> Void) {
        self.queue = queue
        self.action = action
    }

    func schedule() {
        let shouldEnqueue = lock.withLock {
            guard !pending else { return false }
            pending = true
            return true
        }
        guard shouldEnqueue else { return }

        queue.async { [weak self] in
            guard let self else { return }
            // Clear before executing so a wakeup during the action schedules
            // another pass. Clearing afterwards could lose terminal updates.
            self.lock.withLock { self.pending = false }
            self.action()
        }
    }
}
