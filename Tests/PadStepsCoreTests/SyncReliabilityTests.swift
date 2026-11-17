import XCTest
@testable import PadStepsCore

@MainActor
final class SyncReliabilityTests: XCTestCase {
    @MainActor final class Gate {
        var starts = 0
        var cancellations = 0
        var held: [CheckedContinuation<Void, Never>] = []
        var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []
        func operation() async {
            starts += 1
            let ready = arrivals.filter { $0.0 <= starts }; arrivals.removeAll { $0.0 <= starts }
            for value in ready { value.1.resume() }
            await withCheckedContinuation { held.append($0) }
            if Task.isCancelled { cancellations += 1 }
        }
        func started(_ count: Int) async {
            if starts >= count { return }
            await withCheckedContinuation { arrivals.append((count,$0)) }
        }
        func release() { let values = held; held = []; for value in values { value.resume() } }
    }
    func testExpiredObserverDoesNotCancelTheForegroundSyncItJoined() async {
        let gate = Gate(); let run = SharedSyncRun { await gate.operation() }
        let foreground = Task { await run.run() }
        await gate.started(1)
        let observer = Task { await run.run() }
        for _ in 0..<1000 { if run.waiterCount == 2 { break }; await Task.yield() }
        XCTAssertEqual(run.waiterCount,2)
        observer.cancel()
        let observerResult = await observer.value
        XCTAssertFalse(observerResult)
        gate.release()
        let foregroundResult = await foreground.value
        XCTAssertTrue(foregroundResult)
        XCTAssertEqual(gate.starts,1); XCTAssertEqual(gate.cancellations,0)
    }
    func testForegroundCanJoinBackgroundWorkBeforeItsOwnerExpires() async {
        let gate = Gate(); let run = SharedSyncRun { await gate.operation() }
        let background = Task { await run.run() }; await gate.started(1)
        let foreground = Task { await run.run() }
        for _ in 0..<1000 { if run.waiterCount == 2 { break }; await Task.yield() }
        background.cancel(); _ = await background.value
        gate.release()
        let result = await foreground.value
        XCTAssertTrue(result); XCTAssertEqual(gate.cancellations,0)
    }
    func testARequestDuringCancellationWaitsForTheOldRunThenRestarts() async {
        let gate = Gate(); let run = SharedSyncRun { await gate.operation() }
        let first = Task { await run.run() }; await gate.started(1)
        first.cancel(); _ = await first.value
        let next = Task { await run.run() }
        for _ in 0..<1000 { if run.waiterCount == 1 { break }; await Task.yield() }
        XCTAssertEqual(gate.starts,1,"Two syncs must never write concurrently")
        gate.release(); await gate.started(2); gate.release()
        let result = await next.value
        XCTAssertTrue(result); XCTAssertEqual(gate.cancellations,1)
    }
    func testExplicitStopCancelsAllWaitersWithoutHangingThem() async {
        let gate = Gate(); let run = SharedSyncRun { await gate.operation() }
        let first = Task { await run.run() }; await gate.started(1)
        run.cancelAll()
        let result = await first.value
        XCTAssertFalse(result); gate.release()
    }
}
