import XCTest
@testable import PadStepsCore

final class StepTransportMigrationTests: XCTestCase {
    private func legacy() -> PadStepImport {
        .init(resource: "users/111/dataTypes/exercise/dataPoints/222", userID: "111",
              start: Date(timeIntervalSince1970: 1_800_000_000),
              end: Date(timeIntervalSince1970: 1_800_000_600), steps: 900)
    }
    func testLocalFeedMigrationAcceptsUnchangedMeasurementsAndAdoptsExistingSteps() {
        let old = legacy()
        var migrated = PadStepImport(resource: old.resource, userID: old.userID,
            start: old.start.addingTimeInterval(0.0004), end: old.end.addingTimeInterval(0.0004), steps: old.steps)
        migrated.sessionID = UUID(); migrated.legacyResource = old.resource
        XCTAssertNotEqual(old, migrated, "Transport metadata really did change")
        XCTAssertTrue(old.hasSameMeasurements(as: migrated))
        XCTAssertTrue(migrated.hasSameMeasurements(as: old))
        let decision = StepTopUp.plan(padSteps: migrated.steps, googleSteps: 400, start: migrated.start, end: migrated.end,
            existing: [.init(start: old.start, end: old.end, steps: 500, version: 2)], prior: .init(steps: 500, version: 2), pending: nil, legacyConfirmed: true)
        XCTAssertEqual(decision, .adopt(steps: 500, version: 2), "Migration must not write a new copy or bump the version")
    }
    func testTwoGapCarriersAndTheLocalFeedDescribeOneMeasuredSession() {
        let old = legacy(); let session = UUID()
        var a = old; a.sessionID = session; a.legacyResource = old.resource
        var b = PadStepImport(resource: "users/111/dataTypes/exercise/dataPoints/333", userID: old.userID, start: old.start, end: old.end, steps: old.steps)
        b.sessionID = session; b.legacyResource = old.resource
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSameMeasurements(as: b))
        XCTAssertEqual(a.syncIdentifier, b.syncIdentifier)
    }
    func testChangedCountsIntervalsOrIdentityAreStillRejected() {
        let original = legacy()
        let changedSteps = PadStepImport(resource: original.resource, userID: original.userID, start: original.start, end: original.end, steps: 901)
        let changedTime = PadStepImport(resource: original.resource, userID: original.userID, start: original.start.addingTimeInterval(2), end: original.end, steps: original.steps)
        let changedIdentity = PadStepImport(resource: "users/111/dataTypes/exercise/dataPoints/999", userID: original.userID, start: original.start, end: original.end, steps: original.steps)
        XCTAssertFalse(original.hasSameMeasurements(as: changedSteps))
        XCTAssertFalse(original.hasSameMeasurements(as: changedTime))
        XCTAssertFalse(original.hasSameMeasurements(as: changedIdentity))
    }
    func testOneSessionCannotArriveUnderTwoHealthIdentities() throws {
        let session = UUID(); var first = legacy(); first.sessionID = session; first.legacyResource = first.resource
        var other = PadStepImport(resource: "users/111/dataTypes/exercise/dataPoints/333",userID: "111",start: first.start,end: first.end,steps: first.steps)
        other.sessionID = session; other.legacyResource = other.resource
        XCTAssertThrowsError(try PadStepImport.coalescing([first,other]))
        other.legacyResource = first.resource
        XCTAssertEqual(try PadStepImport.coalescing([first,other]).count,1)
    }
    func testMalformedSavedResourceIsRejectedWithoutAnIdentityCrash() {
        let invalid = PadStepImport(resource: "",userID: "111",start: Date(timeIntervalSince1970: 1000),end: Date(timeIntervalSince1970: 1600),steps: 900)
        XCTAssertFalse(invalid.isValidMeasurement)
        XCTAssertFalse(invalid.id.isEmpty)
        XCTAssertThrowsError(try PadStepImport.coalescing([invalid]))
    }

}
