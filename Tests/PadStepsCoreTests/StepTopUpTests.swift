import XCTest
@testable import PadStepsCore

final class StepTopUpTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var end: Date { start.addingTimeInterval(600) }
    func record(_ steps: Int, _ version: Int) -> VersionedStepRecord {
        .init(start: start, end: end, steps: steps, version: version)
    }
    func plan(_ existing: [VersionedStepRecord], prior: StepExportLedger? = nil, pending: StepExportIntent? = nil, legacy: Bool = false, google: Int = 500) -> StepTopUpDecision {
        StepTopUp.plan(padSteps: 2000, googleSteps: google, start: start, end: end,
            existing: existing, prior: prior, pending: pending, legacyConfirmed: legacy)
    }
    func testNewWalkExportsOnlyShortfall() { XCTAssertEqual(plan([]), .save(steps: 1500, version: 1)) }
    func testRepeatedSyncAdoptsOneExistingTrialOrExport() {
        XCTAssertEqual(plan([record(1500, 2)], legacy: true), .adopt(steps: 1500, version: 2))
    }
    func testDelayedGoogleSyncReplacesInsteadOfAdding() {
        XCTAssertEqual(plan([record(1700, 1)], prior: .init(steps: 1700, version: 1)), .save(steps: 1500, version: 2))
    }
    func testLegacyFullRecordCanMigrateButUnknownPartialCannot() {
        XCTAssertEqual(plan([record(2000, 1)], legacy: true), .save(steps: 1500, version: 2))
        if case .review = plan([record(1900, 1)], legacy: true) {} else { XCTFail("Unknown quantity must not be overwritten") }
    }
    func testDeletedConfirmedRecordNeverReappears() {
        if case .review = plan([], prior: .init(steps: 1500, version: 2)) {} else { XCTFail("Deleted confirmed record must not be recreated") }
        if case .review = plan([], legacy: true) {} else { XCTFail("Legacy deletion must be protected") }
    }
    func testPendingWriteAdoptsCompletedTransactionOrReplacesKnownOldVersion() {
        let intent = StepExportIntent(previous: .init(steps: 1700, version: 1), steps: 1500, version: 2)
        XCTAssertEqual(plan([record(1500, 2)], pending: intent), .adopt(steps: 1500, version: 2))
        XCTAssertEqual(plan([record(1700, 1)], pending: intent), .save(steps: 1500, version: 2))
        if case .review = plan([], pending: intent) {} else { XCTFail("Missing uncertain update must be reviewed") }
    }
    func testNoTopUpWhenGoogleAlreadyCoversWalkAndZeroTransitionsKeepVersion() {
        XCTAssertEqual(plan([], google: 2200), .covered(version: 0))
        XCTAssertEqual(plan([record(1500, 2)], prior: .init(steps: 1500, version: 2), google: 2000), .remove(version: 3))
        XCTAssertEqual(plan([], prior: .init(steps: 0, version: 3)), .save(steps: 1500, version: 4))
    }
    func testDuplicateOrDifferentIntervalIsNeverReplaced() {
        if case .review = plan([record(1500, 1), record(1500, 1)]) {} else { XCTFail("Duplicate samples must be reviewed") }
        if case .review = plan([.init(start: start.addingTimeInterval(10), end: end, steps: 1500, version: 1)]) {} else { XCTFail("Wrong interval must be reviewed") }
    }
    func testKnownZeroGoogleCountExportsTheMeasuredPadCount() {
        XCTAssertEqual(plan([], google: 0), .save(steps: 2000, version: 1))
    }
    func testInterruptedRemovalRequiresAnAcknowledgedDelete() {
        var intent = StepExportIntent(previous: .init(steps: 1500, version: 2), steps: 0, version: 3)
        if case .review = plan([], pending: intent) {} else { XCTFail("Unacknowledged missing deletion must stay protected") }
        intent.writeAcknowledged = true
        XCTAssertEqual(plan([], pending: intent), .covered(version: 3))
    }
    func testMalformedPriorVersionDoesNotOverflowOrWrite() {
        if case .review = plan([], prior: .init(steps: 0, version: Int.max)) {} else { XCTFail("Invalid versions must be reviewed") }
    }
    func testUnknownGoogleCountCannotBecomeZero() {
        if case .review = StepTopUp.plan(padSteps: 2000, googleSteps: nil, start: start, end: end, existing: [], prior: nil, pending: nil, legacyConfirmed: false) {} else { XCTFail("Unknown must never become a guessed zero") }
    }
}
