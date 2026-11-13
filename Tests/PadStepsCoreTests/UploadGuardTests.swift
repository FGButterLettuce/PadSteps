import XCTest
@testable import PadStepsCore

final class UploadGuardTests: XCTestCase {
    func testDeletedOverlapCanBeRecheckedWithoutLosingSafety() throws {
        let data = Data("""
        {"id":"11111111-1111-1111-1111-111111111111","stepWraps":0,"clockWraps":0,"observedStart":1000,"stop":1100,"baselineSteps":0,"baselineSeconds":0,"baselineMetres":0,"last":{"at":1100,"steps":120,"seconds":100,"metres":80,"moving":false},"status":"review","detail":"Google Health already has an overlapping workout. Review it before importing this walk."}
        """.utf8)
        let walk = try JSONDecoder().decode(AutomaticWalk.self, from: data)
        XCTAssertTrue(walk.needsSync, "Sync now must recheck a deleted overlap")
    }

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
