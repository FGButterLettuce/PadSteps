import XCTest
import CryptoKit
@testable import PadStepsCore

final class WorkoutCoverageTests: XCTestCase {
    private let trustedClientID = "test-recorder.apps.googleusercontent.com"
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private func range(_ start: Int, _ end: Int) -> WorkoutTimeRange {
        .init(start: epoch.addingTimeInterval(Double(start)), end: epoch.addingTimeInterval(Double(end)))
    }
    func testUndetectedWalkIsSavedInFullAndFullyDetectedWalkAddsNothing() {
        XCTAssertEqual(WorkoutCoverage.missing(in: range(0, 600), covered: []), [range(0, 600)])
        XCTAssertTrue(WorkoutCoverage.missing(in: range(0, 600), covered: [range(-30, 620)]).isEmpty)
    }
    func testOnlyTheActualUncoveredPrefixAndSuffixAreExported() {
        XCTAssertEqual(WorkoutCoverage.missing(in: range(0, 3050), covered: [range(246, 3019)]), [range(0, 246), range(3019, 3050)])
    }
    func testUnionOfNativeWorkoutsDoesNotDoubleSubtractOverlaps() {
        XCTAssertEqual(WorkoutCoverage.missing(in: range(0, 600), covered: [range(100, 300), range(250, 500), range(150, 200)]), [range(0, 100), range(500, 600)])
    }
    func testBoundaryJitterDoesNotCreateTinyExtraWorkouts() {
        XCTAssertTrue(WorkoutCoverage.missing(in: range(0, 600), covered: [range(3, 596)]).isEmpty)
        XCTAssertEqual(WorkoutCoverage.missing(in: range(0, 4), covered: []), [range(0, 4)])
    }
    func testRejectedRetryCannotClearAnUncertainGapAttempt() {
        var plan = WorkoutGapExport(gaps: [range(0, 100),range(500,600)])
        plan.creationStarted = ["rejected":true,"uncertain":true]
        plan.rejectedCreations = ["rejected"]
        let retry = plan.retryingRejectedCreations()
        XCTAssertEqual(retry.creationStarted?["rejected"],false)
        XCTAssertEqual(retry.creationStarted?["uncertain"],true)
    }
    func testMultipleGapCarriersImportOneFullSessionStepIdentity() throws {
        let key = Curve25519.Signing.PrivateKey()
        let full = range(0, 600)
        let sample = PadObservation(.init(steps: 900, elapsedSeconds: 600, distanceMetres: 700), at: full.end)
        var walk = AutomaticWalk(observedStart: full.start, baselineSteps: 0, baselineSeconds: 0, baselineMetres: 0, last: sample)
        walk.stop = full.end
        func carrier(_ name: String, _ segment: WorkoutTimeRange) throws -> [String: Any] {
            let receipt = MeasuredWalkReceipt(walk: walk, resource: name, carrier: segment, gap: true, clientID: trustedClientID)
            return ["name": name, "exercise": ["exerciseType": "WALKING", "notes": try receipt.signedNote(privateKey: key.rawRepresentation),
                "interval": ["startTime": ISO8601DateFormatter().string(from: segment.start), "endTime": ISO8601DateFormatter().string(from: segment.end)],
                "metricsSummary": ["averageHeartRateBeatsPerMinute": "110"]]]
        }
        let first = try carrier("users/111/dataTypes/exercise/dataPoints/222", range(0, 100))
        let second = try carrier("users/111/dataTypes/exercise/dataPoints/333", range(500, 600))
        let a = try XCTUnwrap(PadStepImport.parse(JSONSerialization.data(withJSONObject: first), recorderClientID: trustedClientID, correctionPublicKey: key.publicKey.rawRepresentation))
        let b = try XCTUnwrap(PadStepImport.parse(JSONSerialization.data(withJSONObject: second), recorderClientID: trustedClientID, correctionPublicKey: key.publicKey.rawRepresentation))
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a.syncIdentifier, b.syncIdentifier)
        XCTAssertEqual(a.steps, 900)
        XCTAssertEqual(a.start, full.start); XCTAssertEqual(a.end, full.end)
        XCTAssertNil(try PadStepImport.parse(JSONSerialization.data(withJSONObject: first), recorderClientID: trustedClientID))
        var changed = first; var exercise = changed["exercise"] as! [String: Any]
        exercise["interval"] = ["startTime": ISO8601DateFormatter().string(from: epoch.addingTimeInterval(5)), "endTime": ISO8601DateFormatter().string(from: epoch.addingTimeInterval(100))]
        changed["exercise"] = exercise
        XCTAssertNil(try PadStepImport.parse(JSONSerialization.data(withJSONObject: changed), recorderClientID: trustedClientID, correctionPublicKey: key.publicKey.rawRepresentation))
    }
}
