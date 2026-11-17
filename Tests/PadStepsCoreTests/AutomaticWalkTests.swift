import XCTest
@testable import PadStepsCore

final class AutomaticWalkTests: XCTestCase {
    let epoch = Date(timeIntervalSince1970: 100_000)
    func sample(_ steps: Int, _ seconds: Int, moving: Bool = true) -> PadTelemetry {
        PadTelemetry(steps: steps, elapsedSeconds: seconds, speedKmh: moving ? 4.5 : 0,
                     distanceMetres: steps / 10 * 10, motion: moving ? .running : .idle)
    }
    func testReconnectPreservesCumulativeStepsAndRequiresFreshConfirmedStop() throws {
        var recorder = AutomaticRecorder()
        XCTAssertNil(recorder.observe(sample(0, 0, moving: false), at: epoch))
        XCTAssertNil(recorder.observe(sample(1, 1), at: epoch.addingTimeInterval(1)))
        XCTAssertNil(recorder.observe(sample(990, 668), at: epoch.addingTimeInterval(668)))
        recorder.disconnected()
        XCTAssertNil(recorder.observe(sample(4500, 3000), at: epoch.addingTimeInterval(3000)))
        XCTAssertEqual(recorder.active?.steps, 4500)
        var restored = try JSONDecoder().decode(AutomaticRecorder.self, from: JSONEncoder().encode(recorder))
        for i in 0..<4 { XCTAssertNil(restored.observe(sample(6000, 4000, moving: false), at: epoch.addingTimeInterval(Double(4000 + i)))) }
        let walk = try XCTUnwrap(restored.observe(sample(6000, 4000, moving: false), at: epoch.addingTimeInterval(4004)))
        XCTAssertEqual(walk.steps, 6000); XCTAssertEqual(walk.seconds, 4000)
        XCTAssertEqual(walk.start, epoch); XCTAssertEqual(walk.status, "waitingHeartRate")
        XCTAssertNil(restored.active)
        XCTAssertNil(restored.observe(sample(6000, 4000, moving: false), at: epoch.addingTimeInterval(4005)))
    }
    func testOldIdleSessionIsNotImportedAndResetBeginsNewWalk() {
        var r = AutomaticRecorder()
        _ = r.observe(sample(6000, 4000, moving: false), at: epoch)
        _ = r.observe(sample(1, 1), at: epoch.addingTimeInterval(10))
        XCTAssertEqual(r.active?.steps, 1)
        XCTAssertEqual(r.active?.seconds, 1)
    }
    func testCounterResetDuringDisconnectRequiresReview() {
        var r = AutomaticRecorder()
        _ = r.observe(sample(100, 60), at: epoch)
        r.disconnected()
        let walk = r.observe(sample(0, 0, moving: false), at: epoch.addingTimeInterval(30))
        XCTAssertEqual(walk?.status, "review")
        XCTAssertEqual(walk?.steps, 100)
    }
    func testSparseStopMessagesDoNotCompleteWithoutFiveConfirmations() {
        var r = AutomaticRecorder()
        _ = r.observe(sample(1, 1), at: epoch)
        XCTAssertNil(r.observe(sample(100, 60, moving: false), at: epoch.addingTimeInterval(60)))
        r.disconnected()
        XCTAssertNil(r.observe(sample(100, 60, moving: false), at: epoch.addingTimeInterval(100)))
        XCTAssertNotNil(r.active)
    }
    func testHeartRateNeedsBothBoundariesAndNoLongGaps() throws {
        let end = epoch.addingTimeInterval(60)
        let complete = stride(from: 0, through: 60, by: 3).map { HeartObservation(at: epoch.addingTimeInterval(Double($0)), bpm: 120) }
        XCTAssertEqual(try HeartSummary.calculate(complete, start: epoch, end: end).average, 120)
        XCTAssertThrowsError(try HeartSummary.calculate(Array(complete.dropLast(3)), start: epoch, end: end))
        XCTAssertThrowsError(try HeartSummary.calculate([complete[0], complete.last!], start: epoch, end: end))
    }
    func testUnequalSamplingDoesNotBiasHeartRateMean() throws {
        let points = [HeartObservation(at: epoch, bpm: 100), HeartObservation(at: epoch.addingTimeInterval(1), bpm: 100),
                      HeartObservation(at: epoch.addingTimeInterval(2), bpm: 100), HeartObservation(at: epoch.addingTimeInterval(12), bpm: 140)]
        XCTAssertEqual(try HeartSummary.calculate(points, start: epoch, end: epoch.addingTimeInterval(12)).average, 117)
    }
    func testDistanceResetCannotReuseAnIncompatibleIdleBaseline() {
        var recorder = AutomaticRecorder()
        _ = recorder.observe(PadTelemetry(steps: 0, elapsedSeconds: 0, distanceMetres: 100, motion: .idle), at: epoch)
        _ = recorder.observe(PadTelemetry(steps: 1, elapsedSeconds: 1, speedKmh: 3, distanceMetres: 0), at: epoch.addingTimeInterval(1))
        _ = recorder.observe(PadTelemetry(steps: 100, elapsedSeconds: 60, speedKmh: 3, distanceMetres: 200), at: epoch.addingTimeInterval(60))
        XCTAssertEqual(recorder.active?.metres,200)
    }
    func testDisconnectedWalkCanBeFinishedForReviewWithoutRepeatingItsCounters() throws {
        var recorder = AutomaticRecorder()
        _ = recorder.observe(sample(100,60),at: epoch)
        let id = recorder.active!.id
        recorder.disconnected()
        let review = try XCTUnwrap(recorder.finishForReview())
        XCTAssertEqual(review.id,id); XCTAssertEqual(review.steps,100)
        XCTAssertTrue(review.canConfirmRecordedTotals); XCTAssertFalse(review.needsSync)
        XCTAssertNil(recorder.active)
        _ = recorder.observe(sample(110,66),at: epoch.addingTimeInterval(6))
        XCTAssertEqual(recorder.active?.steps,10,"A late reconnect must not record the already-reviewed counters twice")
    }
}
