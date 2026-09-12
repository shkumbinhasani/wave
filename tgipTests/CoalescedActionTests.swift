import XCTest

final class CoalescedActionTests: XCTestCase {
    func testConcurrentBurstQueuesOneAction() {
        let queue = DispatchQueue(label: "test.coalesced-action")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        var calls = 0 // Only accessed on the serial queue.
        let action = CoalescedAction(queue: queue) { calls += 1 }
        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in action.schedule() }
        gate.signal()
        queue.sync { XCTAssertEqual(calls, 1) }
        action.schedule()
        queue.sync { XCTAssertEqual(calls, 2) }
    }

    func testWakeupDuringActionSchedulesAnotherPass() {
        let queue = DispatchQueue(label: "test.coalesced-action.reentrant")
        let finished = expectation(description: "Second pass runs")
        var calls = 0
        var action: CoalescedAction!
        action = CoalescedAction(queue: queue) {
            calls += 1
            if calls == 1 {
                action.schedule()
            } else {
                finished.fulfill()
            }
        }
        action.schedule()
        wait(for: [finished], timeout: 2)
        queue.sync { XCTAssertEqual(calls, 2) }
        action = nil
    }

    func testReleasingOwnerCancelsQueuedAction() {
        let queue = DispatchQueue(label: "test.coalesced-action.release")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        var calls = 0
        var action: CoalescedAction? = CoalescedAction(queue: queue) { calls += 1 }
        weak var weakAction = action
        action?.schedule()
        action = nil
        XCTAssertNil(weakAction)
        gate.signal()
        queue.sync { XCTAssertEqual(calls, 0) }
    }
}
