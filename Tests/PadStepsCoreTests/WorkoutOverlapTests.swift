import XCTest
@testable import PadStepsCore

final class WorkoutOverlapTests: XCTestCase {
    func testOnlyMissingStepsAreReportedAndUnknownNeverBecomesZero() {
        XCTAssertEqual(StepComparison(pad: 2000, recorded: 450).missing, 1550)
        XCTAssertEqual(StepComparison(pad: 2000, recorded: 2300).missing, 0)
        XCTAssertEqual(StepComparison(pad: 2000, recorded: 2300).excess, 300)
        XCTAssertNil(StepComparison(pad: 2000, recorded: nil).missing)
        XCTAssertNil(StepComparison.rollupCount([:]))
        XCTAssertNil(StepComparison.rollupCount(["rollupDataPoints": []]))
        XCTAssertNil(StepComparison.rollupCount(["rollupDataPoints": [["steps": ["countSum": "-1"]]]]))
        XCTAssertEqual(StepComparison.rollupCount(["rollupDataPoints": [["steps": ["countSum": "450"]]]]), 450)
        XCTAssertNil(StepComparison.rollupCount(["rollupDataPoints": [["steps": ["countSum": "450"]]], "nextPageToken": "more"]))
    }
}
