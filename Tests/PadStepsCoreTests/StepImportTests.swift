import XCTest
@testable import PadStepsCore

final class StepImportTests: XCTestCase {
    private let trustedClientID = "test-recorder.apps.googleusercontent.com"
    private func parse(_ data: Data) throws -> PadStepImport? {
        try PadStepImport.parse(data, recorderClientID: trustedClientID)
    }
    private func point(steps: String = "1200", source: String = "test-recorder.apps.googleusercontent.com", start: String = "2025-01-15T06:50:45.091Z", end: String = "2025-01-15T07:24:08.091Z") -> Data {
        Data("""
        {"name":"users/1000000000000000001/dataTypes/exercise/dataPoints/2000000000000000002","dataSource":{"platform":"GOOGLE_WEB_API","application":{"googleWebClientId":"\(source)"}},"exercise":{"exerciseType":"WALKING","interval":{"startTime":"\(start)","endTime":"\(end)"},"metricsSummary":{"steps":"\(steps)"}}}
        """.utf8)
    }
    func testExistingProofUsesIdenticalSyncIdentityAndIsAdopted() throws {
        let walk = try XCTUnwrap(parse(point()))
        XCTAssertEqual(walk.syncIdentifier, "padsteps.google_1000000000000000001_2000000000000000002.steps")
        let record = SavedStepRecord(start: walk.start, end: walk.end, steps: 1200)
        XCTAssertEqual(walk.decision(existing: [record], previouslyConfirmed: false), .adopt)
        XCTAssertEqual(walk.decision(existing: [record], previouslyConfirmed: true), .adopt)
    }
    func testDeletedConfirmedOrConflictingRecordsNeverSaveAgain() throws {
        let walk = try XCTUnwrap(parse(point()))
        XCTAssertEqual(walk.decision(existing: [], previouslyConfirmed: true), .review)
        let record = SavedStepRecord(start: walk.start, end: walk.end, steps: 1199)
        XCTAssertEqual(walk.decision(existing: [record], previouslyConfirmed: false), .review)
        XCTAssertEqual(walk.decision(existing: [record, record], previouslyConfirmed: false), .review)
        XCTAssertEqual(walk.decision(existing: [], previouslyConfirmed: false), .save)
    }
    func testNativeFitbitAndOtherPartnersAreExcludedBeforeDecodingCounters() throws {
        XCTAssertNil(try parse(point(source: "other-app")))
        XCTAssertNil(try parse(Data("{\"exercise\":{\"exerciseType\":\"WALKING\"},\"dataSource\":{\"platform\":\"FITBIT\"}}".utf8)))
    }
    func testMissingLocalRecorderConfigurationRejectsImports() throws {
        XCTAssertNil(try PadStepImport.parse(point(), recorderClientID: ""))
        XCTAssertNil(try PadStepImport.parse(point(), recorderClientID: "   "))
    }
    func testInvalidCountsOrIntervalAreRejected() {
        for steps in ["0", "-1", "100000", "bad"] { XCTAssertThrowsError(try parse(point(steps: steps))) }
        XCTAssertThrowsError(try parse(point(end: "2025-01-15T06:49:00Z")))
    }
    func testPlainAndFractionalGoogleDatesAndNumericCountersWork() throws {
        XCTAssertNotNil(try parse(point(start: "2025-01-15T06:50:45Z")))
        let numeric = String(decoding: point(), as: UTF8.self).replacingOccurrences(of: "\"steps\":\"1200\"", with: "\"steps\":1200")
        XCTAssertEqual(try parse(Data(numeric.utf8))?.steps, 1200)
    }
}
