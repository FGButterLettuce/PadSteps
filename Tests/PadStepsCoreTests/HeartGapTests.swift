import XCTest
@testable import PadStepsCore

final class HeartGapTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 100_000)
    private func points(duration: Int, excluding: [ClosedRange<Int>] = [], bpm: (Int) -> Int = { _ in 110 }) -> [HeartObservation] {
        (0...duration).filter { second in !excluding.contains { $0.contains(second) } }
            .map { HeartObservation(at: start.addingTimeInterval(Double($0)), bpm: bpm($0)) }
    }
    func testAnIsolatedBriefGapDoesNotBlockAnOtherwiseCompleteWalk() throws {
        let summary = try HeartSummary.calculate(points(duration: 2700, excluding: [1001...1027]), start: start, end: start.addingTimeInterval(2700))
        XCTAssertEqual(summary.average, 110)
        XCTAssertEqual(summary.maxGap, 28)
        XCTAssertEqual(summary.uncoveredSeconds, 28)
    }
    func testRepeatedBriefGapsStillRejectIncompleteCoverage() {
        let sparse = points(duration: 600, excluding: [101...127, 201...227])
        XCTAssertThrowsError(try HeartSummary.calculate(sparse, start: start, end: start.addingTimeInterval(600)))
    }
    func testLongGapStillBlocksTheWalk() {
        XCTAssertThrowsError(try HeartSummary.calculate(points(duration: 2700, excluding: [1001...1030]), start: start, end: start.addingTimeInterval(2700)))
    }
    func testMissingBoundaryStillWaitsForSync() {
        XCTAssertThrowsError(try HeartSummary.calculate(points(duration: 600, excluding: [0...5]), start: start, end: start.addingTimeInterval(600))) { error in
            guard case HeartCoverageError.waitingForSync = error else { return XCTFail("Expected boundary sync wait") }
        }
    }
    func testGapIsExcludedFromTheAverageRatherThanFilled() throws {
        // The observed segments cover 80 seconds at 100 bpm, and 492 at 140 bpm.
        let summary = try HeartSummary.calculate(points(duration: 600, excluding: [81...108], bpm: { $0 <= 80 ? 100 : 140 }), start: start, end: start.addingTimeInterval(600))
        XCTAssertEqual(summary.average, Int(((80.0 * 100 + 492.0 * 140) / 572).rounded()))
    }
}
