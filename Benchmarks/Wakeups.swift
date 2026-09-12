import Foundation

// Original GhosttyRuntime.wakeup_cb, with a private serial queue standing in
// for a busy main queue. The pending flag was only checked after dispatch.
private final class LegacyWakeup {
    let queue: DispatchQueue
    let action: () -> Void
    private var pending = false

    init(queue: DispatchQueue, action: @escaping () -> Void) {
        self.queue = queue
        self.action = action
    }

    func schedule() {
        queue.async {
            guard !self.pending else { return }
            self.pending = true
            self.queue.async {
                self.pending = false
                self.action()
            }
        }
    }
}

@main
struct WakeupBenchmark {
    static func runBurst(count: Int, legacy: Bool) -> Double {
        let queue = DispatchQueue(label: "benchmark.wakeups")
        let gate = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        queue.async { ready.signal(); gate.wait() }
        ready.wait()
        let before = LegacyWakeup(queue: queue) { finished.signal() }
        let after = CoalescedAction(queue: queue) { finished.signal() }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<count {
            if legacy { before.schedule() } else { after.schedule() }
        }
        gate.signal()
        precondition(finished.wait(timeout: .now() + 10) == .success)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        withExtendedLifetime((before, after)) {}
        return elapsed
    }

    static func main() throws {
        let count = 50_000
        _ = runBurst(count: count, legacy: true)
        _ = runBurst(count: count, legacy: false)
        var before: [Double] = [], after: [Double] = []
        for i in 0..<15 {
            if i.isMultiple(of: 2) {
                before.append(runBurst(count: count, legacy: true))
                after.append(runBurst(count: count, legacy: false))
            } else {
                after.append(runBurst(count: count, legacy: false))
                before.append(runBurst(count: count, legacy: true))
            }
        }
        let result: [String: Any] = [
            "wakeups": count, "samples": before.count,
            "before_ms": before, "after_ms": after,
            "before_median_ms": before.sorted()[before.count / 2],
            "after_median_ms": after.sorted()[after.count / 2],
            "before_enqueued_blocks": count + 1, "after_enqueued_blocks": 1,
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
