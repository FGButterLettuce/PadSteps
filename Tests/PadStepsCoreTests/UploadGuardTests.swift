import XCTest
@testable import PadStepsCore

final class UploadGuardTests: XCTestCase {
    func testTimeoutOrCrashWithNoResourceNeverRepeatsPost() {
        XCTAssertNotEqual(UploadGuard.decide(attempted: true, matchingNames: [], hasOverlap: false, operationName: nil), .create)
    }
    func testSuccessfulPostRecoveredAfterCrashAdoptsExistingResource() {
        XCTAssertEqual(UploadGuard.decide(attempted: true, matchingNames: ["workout-1"], hasOverlap: true, operationName: nil), .adopt("workout-1"))
    }
    func testPendingOperationIsResumedWithoutCreatingAnotherWorkout() {
        XCTAssertEqual(UploadGuard.decide(attempted: true, matchingNames: [], hasOverlap: false, operationName: "operations/1"), .resolveOperation("operations/1"))
    }
    func testFitbitAutoWorkoutBlocksDuplicateImport() {
        if case .review = UploadGuard.decide(attempted: false, matchingNames: [], hasOverlap: true, operationName: nil) {} else { XCTFail("Must review overlapping Fitbit workout") }
    }
    func testOnlyFreshNonoverlappingWalkCanCreate() {
        XCTAssertEqual(UploadGuard.decide(attempted: false, matchingNames: [], hasOverlap: false, operationName: nil), .create)
    }
}
