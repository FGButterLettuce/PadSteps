import XCTest
import CryptoKit
@testable import PadStepsCore

final class WorkoutCorrectionTests: XCTestCase {
    private let recorderClientID = "recorder.apps.googleusercontent.com"
    private let resource = "users/111/dataTypes/exercise/dataPoints/222"
    private func fixture() -> AutomaticWalk {
        let end = Date(timeIntervalSince1970: 1_800_000_600)
        let sample = PadObservation(PadTelemetry(steps: 900, elapsedSeconds: 600, distanceMetres: 700, motion: .idle), at: end)
        var walk = AutomaticWalk(observedStart: end.addingTimeInterval(-600), baselineSteps: 0, baselineSeconds: 0, baselineMetres: 0, last: sample)
        walk.stop = end; walk.averageBPM = 101
        return walk
    }
    private func point(_ walk: AutomaticWalk, note: String) -> [String: Any] {
        let f = ISO8601DateFormatter()
        return ["name": resource, "dataSource": ["platform": "FITBIT", "device": ["displayName": "Tracker"]],
            "exercise": ["exerciseType": "WALKING", "notes": note,
                "interval": ["startTime": f.string(from: walk.start), "endTime": f.string(from: walk.exportEnd)],
                "activeDuration": "600s", "metricsSummary": ["steps": "900", "distanceMillimeters": 700000, "averageHeartRateBeatsPerMinute": "101"]]]
    }
    func testNativeWorkoutNeedsPairedSignatureAndMatchingCountersToImport() throws {
        let key = Curve25519.Signing.PrivateKey(), walk = fixture()
        let proof = WorkoutCorrection(walk: walk, resource: resource, recorderClientID: recorderClientID)
        let note = try proof.signedNote(privateKey: key.rawRepresentation)
        let object = point(walk, note: "Original notes\n" + note)
        let data = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try PadStepImport.parse(data, recorderClientID: recorderClientID))
        XCTAssertEqual(try PadStepImport.parse(data, recorderClientID: recorderClientID, correctionPublicKey: key.publicKey.rawRepresentation)?.steps, 900)
        XCTAssertNil(try PadStepImport.parse(data, recorderClientID: recorderClientID, correctionPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        var changed = object
        var exercise = changed["exercise"] as! [String: Any]
        exercise["metricsSummary"] = ["steps": "901", "distanceMillimeters": 700000, "averageHeartRateBeatsPerMinute": "101"]
        changed["exercise"] = exercise
        XCTAssertNil(try PadStepImport.parse(JSONSerialization.data(withJSONObject: changed), recorderClientID: recorderClientID, correctionPublicKey: key.publicKey.rawRepresentation))
        XCTAssertNil(WorkoutCorrection.verified(note: note, publicKey: key.publicKey.rawRepresentation, recorderClientID: "other-recorder", resource: resource))
        XCTAssertNil(WorkoutCorrection.verified(note: note, publicKey: key.publicKey.rawRepresentation, recorderClientID: recorderClientID, resource: resource + "9"))
        XCTAssertNil(WorkoutCorrection.verified(note: note + "\n" + note, publicKey: key.publicKey.rawRepresentation, recorderClientID: recorderClientID, resource: resource))
    }
    func testPartialOrUnrelatedWorkoutCannotBeCorrectedWithWholeWalkCounts() throws {
        let walk = fixture()
        XCTAssertTrue(try XCTUnwrap(WorkoutConflict(point: point(walk, note: ""))).coversSameWalk(walk))
        var object = point(walk, note: "")
        var exercise = object["exercise"] as! [String: Any]
        exercise["interval"] = ["startTime": ISO8601DateFormatter().string(from: walk.start.addingTimeInterval(-600)), "endTime": ISO8601DateFormatter().string(from: walk.exportEnd)]
        object["exercise"] = exercise
        XCTAssertFalse(try XCTUnwrap(WorkoutConflict(point: object)).coversSameWalk(walk))
        exercise["exerciseType"] = "RUNNING"; object["exercise"] = exercise
        XCTAssertFalse(try XCTUnwrap(WorkoutConflict(point: object)).coversSameWalk(walk))
    }
    func testOnlyRecorderOwnedWorkoutsMayBeCorrected() throws {
        let walk = fixture()
        var object = point(walk,note: "")
        XCTAssertFalse(try XCTUnwrap(WorkoutConflict(point: object)).isOwned(by: "our-client"))
        object["dataSource"] = ["platform": "GOOGLE_WEB_API","application": ["googleWebClientId":"another-client"]]
        XCTAssertFalse(try XCTUnwrap(WorkoutConflict(point: object)).isOwned(by: "our-client"))
        object["dataSource"] = ["platform": "GOOGLE_WEB_API","application": ["googleWebClientId":"our-client"]]
        XCTAssertTrue(try XCTUnwrap(WorkoutConflict(point: object)).isOwned(by: "our-client"))
    }
    func testLateOverlapRetainsItsExistingResourceAndCannotBecomeANewUpload() {
        var walk = fixture(); walk.status = "review"; walk.reviewKind = "lateOverlap"
        walk.resourceName = resource; walk.uploadAttempted = true
        XCTAssertTrue(walk.needsSync)
        XCTAssertTrue(walk.canRecheckSavedOverlap)
        XCTAssertFalse(walk.canRecheckOverlap)
        walk.resourceName = nil
        XCTAssertFalse(walk.needsSync)
        XCTAssertFalse(walk.canRecheckOverlap)
    }
    func testUncertainAttemptsAndCounterResetsCannotBecomeFreshPosts() {
        var walk = fixture(); walk.status = "review"; walk.reviewKind = "overlap"
        XCTAssertTrue(walk.canRecheckOverlap)
        walk.uploadAttempted = true; XCTAssertFalse(walk.canRecheckOverlap)
        walk.uploadAttempted = nil; walk.issue = "Counters reset"; XCTAssertFalse(walk.canRecheckOverlap)
        walk.issue = nil; walk.correctionTarget = resource; XCTAssertFalse(walk.canRecheckOverlap)
        walk.correctionTarget = nil; walk.operationName = "operations/pending"; XCTAssertFalse(walk.canRecheckOverlap)
    }
}
