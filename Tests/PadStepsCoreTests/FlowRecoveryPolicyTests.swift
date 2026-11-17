import XCTest
@testable import PadStepsCore

final class FlowRecoveryPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_100_000)
    func testGoogleOutageOrRateLimitDoesNotDiscardOfflineAuthorization() {
        XCTAssertFalse(OAuthRecovery.requiresReconnect(status: 503, error: nil))
        XCTAssertFalse(OAuthRecovery.requiresReconnect(status: 429, error: "temporarily_unavailable"))
        XCTAssertFalse(OAuthRecovery.requiresReconnect(status: 200, error: nil))
        XCTAssertTrue(OAuthRecovery.requiresReconnect(status: 400, error: "invalid_grant"))
        XCTAssertTrue(OAuthRecovery.requiresReconnect(status: 401, error: "invalid_client"))
    }
    func testNewWalkPrecedesBackfillAndUnchangedOldHistoryIsNotPolledForever() {
        func walk(_ name: String, _ age: TimeInterval) -> PadStepImport {
            .init(resource: "users/111/dataTypes/exercise/dataPoints/\(name)", userID: "111", start: now.addingTimeInterval(-age-600), end: now.addingTimeInterval(-age), steps: 900)
        }
        let historical = walk("old",4*86400), recent = walk("recent",600), fresh = walk("new",0)
        let candidates = [StepCheckCandidate(walk: historical, state: "confirmed", checkedAt: now.addingTimeInterval(-86400)),
                          StepCheckCandidate(walk: recent, state: "confirmed", checkedAt: now.addingTimeInterval(-10)),
                          StepCheckCandidate(walk: fresh)]
        XCTAssertEqual(StepCheckSchedule.due(candidates, now: now).map(\.id),[fresh.id])
        XCTAssertEqual(StepCheckSchedule.due(candidates, now: now, force: true).first?.id,fresh.id)
    }
    func testCancelledOrUnconfirmedHealthWriteIsNotFrozenAsOldHistory() {
        let old = PadStepImport(resource: "users/111/dataTypes/exercise/dataPoints/old", userID: "111", start: now.addingTimeInterval(-5*86400-600), end: now.addingTimeInterval(-5*86400), steps: 900)
        let candidate = StepCheckCandidate(walk: old, state: "attempted", checkedAt: now.addingTimeInterval(-5*86400), hasPendingWrite: true)
        XCTAssertEqual(StepCheckSchedule.due([candidate],now: now).count,1)
    }
    func testLateWorkoutAuditsDoNotIgnoreWalksBeyondTheFirstTwenty() {
        var walks: [AutomaticWalk] = (0..<30).map { index in
            let end = now.addingTimeInterval(-Double(index * 600))
            let sample = PadObservation(.init(steps: 900,elapsedSeconds: 600),at: end)
            var walk = AutomaticWalk(observedStart: end.addingTimeInterval(-600),baselineSteps: 0,baselineSeconds: 0,baselineMetres: 0,last: sample)
            walk.stop = end; walk.status = "saved"; return walk
        }
        let first = Set(WorkoutAuditSchedule.due(walks,now: now).map(\.id))
        for index in walks.indices where first.contains(walks[index].id) { walks[index].lastGoogleAudit = now }
        let next = Set(WorkoutAuditSchedule.due(walks,now: now.addingTimeInterval(60),limit: 10).map(\.id))
        XCTAssertEqual(first.count,20); XCTAssertEqual(next.count,10); XCTAssertTrue(first.isDisjoint(with: next))
    }
}
