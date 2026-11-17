import XCTest
@testable import PadStepsCore

final class GapReconciliationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var full: WorkoutTimeRange { .init(start: start,end: start.addingTimeInterval(600)) }
    private let pending = "users/111/dataTypes/exercise/dataPoints/padsteps-ticket"
    private let assigned = "users/111/dataTypes/exercise/dataPoints/222"
    func testLateGoogleDetectionCannotDiscardAnUnconfirmedCreation() throws {
        var plan = WorkoutGapExport(gaps: [full],resources: [pending]); plan.creationStarted = [pending:true]
        XCTAssertThrowsError(try plan.replacingCoverage([],makePending: { self.pending }))
        XCTAssertThrowsError(try plan.resolvingCreations(candidates: []))
        let resolved = try plan.resolvingCreations(candidates: [.init(resource: assigned,range: full)])
        let covered = try resolved.replacingCoverage([],makePending: { self.pending })
        XCTAssertTrue(covered.resources.isEmpty)
        XCTAssertEqual(covered.retiredResources,[assigned],"Only a real, verified resource may be retired")
    }
    func testUnsentOrRejectedTicketsNeverBecomeGoogleDeleteTargets() throws {
        var plan = WorkoutGapExport(gaps: [full],resources: [pending])
        let unused = try plan.replacingCoverage([],makePending: { self.pending })
        XCTAssertTrue(unused.retiredResources.isEmpty)
        plan.creationStarted = [pending:true]; plan.rejectedCreations = [pending]
        let rejected = try plan.replacingCoverage([],makePending: { self.pending })
        XCTAssertTrue(rejected.retiredResources.isEmpty)
    }
    func testNewGapAfterReplanningDoesNotReuseAnOldAttemptMarker() throws {
        var plan = WorkoutGapExport(gaps: [full],resources: [assigned]); plan.creationStarted = [pending:true]
        let parts = [WorkoutTimeRange(start: start,end: start.addingTimeInterval(100)),WorkoutTimeRange(start: start.addingTimeInterval(500),end: full.end)]
        let fresh = "users/111/dataTypes/exercise/dataPoints/padsteps-new-ticket"
        let changed = try plan.replacingCoverage(parts,makePending: { fresh })
        XCTAssertEqual(changed.resources,[assigned,fresh]); XCTAssertNil(changed.creationStarted?[fresh])
    }
    func testOldRetiredLocalTicketCanBeRecoveredWithoutQueryingItsInvalidName() throws {
        var plan = WorkoutGapExport(gaps: [],retiredResources: [pending]); plan.creationStarted = [pending:true]
        let resolved = try plan.resolvingCreations(candidates: [.init(resource: assigned,range: full)])
        XCTAssertEqual(resolved.retiredResources,[assigned])
    }
    func testDuplicateCandidatesOrResourceReferencesHoldThePlan() {
        var plan = WorkoutGapExport(gaps: [full],resources: [pending]); plan.creationStarted = [pending:true]
        XCTAssertThrowsError(try plan.resolvingCreations(candidates: [.init(resource: assigned,range: full),.init(resource: "other",range: full)]))
        plan.resources = [assigned,assigned]; plan.gaps = [full,full]
        XCTAssertThrowsError(try plan.replacingCoverage([full],makePending: { self.pending }))
    }
    func testAutomaticBackoffRetryClearsOnlyAnExplicitRejection() {
        var plan = WorkoutGapExport(gaps: [full],resources: [pending])
        plan.creationStarted = [pending:true,"unknown":true]
        plan.rejectedCreations = [pending]
        plan.retryAfter = [pending:start.addingTimeInterval(60),"unknown":start]
        XCTAssertEqual(plan.retryingDueCreations(at: start).creationStarted?[pending],true)
        let due = plan.retryingDueCreations(at: start.addingTimeInterval(61))
        XCTAssertEqual(due.creationStarted?[pending],false)
        XCTAssertEqual(due.creationStarted?["unknown"],true,"Elapsed time cannot turn an unknown write into a rejected one")
        XCTAssertNil(plan.retryingRejectedCreations().retryAfter?[pending],
                     "A manual retry must not leave an old transient retry timer attached to a new rejection")
    }
}
