import XCTest
import CryptoKit
@testable import PadStepsCore

final class MeasuredWalkFeedTests: XCTestCase {
    private func walk() -> AutomaticWalk {
        let end = Date(timeIntervalSince1970: 1_800_000_600)
        let sample = PadObservation(.init(steps: 900, elapsedSeconds: 600, distanceMetres: 700), at: end)
        var value = AutomaticWalk(observedStart: end.addingTimeInterval(-600), baselineSteps: 0, baselineSeconds: 0, baselineMetres: 0, last: sample)
        value.stop = end
        return value
    }
    func testStepsCanSyncWithNoGoogleWorkoutAndKeepOneIdentity() throws {
        let key = Curve25519.Signing.PrivateKey(), measured = walk()
        let feed = MeasuredWalkFeed(account: "111", clientID: "recorder", sessions: [.init(walk: measured)])
        let data = try feed.signed(privateKey: key.rawRepresentation)
        let imported = try MeasuredWalkFeed.imports(data, publicKey: key.publicKey.rawRepresentation, account: "111", clientID: "recorder")
        XCTAssertEqual(imported.count, 1); XCTAssertEqual(imported[0].steps, 900)
        XCTAssertEqual(imported[0].sessionID, measured.id)
        XCTAssertEqual(imported[0].start, measured.start)
        XCTAssertEqual(try MeasuredWalkFeed.imports(data, publicKey: key.publicKey.rawRepresentation, account: "111", clientID: "recorder")[0].syncIdentifier, imported[0].syncIdentifier)
    }
    func testExistingGoogleStepIdentitySurvivesWorkoutRemoval() throws {
        let key = Curve25519.Signing.PrivateKey()
        var measured = walk(); measured.resourceName = "users/111/dataTypes/exercise/dataPoints/222"
        var gap = WorkoutGapExport(gaps: [])
        gap.legacyResource = measured.resourceName; measured.gapExport = gap
        let data = try MeasuredWalkFeed(account: "111", clientID: "recorder", sessions: [.init(walk: measured)]).signed(privateKey: key.rawRepresentation)
        let imported = try MeasuredWalkFeed.imports(data, publicKey: key.publicKey.rawRepresentation, account: "111", clientID: "recorder")
        XCTAssertEqual(imported[0].id, "google_111_222")
        XCTAssertEqual(imported[0].steps, 900)
    }
    func testWrongPairingOrAccountCannotInjectSteps() throws {
        let key = Curve25519.Signing.PrivateKey()
        let data = try MeasuredWalkFeed(account: "111", clientID: "recorder", sessions: [.init(walk: walk())]).signed(privateKey: key.rawRepresentation)
        XCTAssertThrowsError(try MeasuredWalkFeed.imports(data, publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation, account: "111", clientID: "recorder"))
        XCTAssertThrowsError(try MeasuredWalkFeed.imports(data, publicKey: key.publicKey.rawRepresentation, account: "999", clientID: "recorder"))
        XCTAssertThrowsError(try MeasuredWalkFeed.imports(data, publicKey: key.publicKey.rawRepresentation, account: "111", clientID: "different"))
    }
    func testDuplicatedSessionOrCrossAccountLegacyReferenceIsRejected() throws {
        let key = Curve25519.Signing.PrivateKey(); var measured = walk()
        let item = MeasuredWalkFeed.Session(walk: measured)
        let duplicated = try MeasuredWalkFeed(account: "111", clientID: "recorder", sessions: [item,item]).signed(privateKey: key.rawRepresentation)
        XCTAssertThrowsError(try MeasuredWalkFeed.imports(duplicated, publicKey: key.publicKey.rawRepresentation, account: "111", clientID: "recorder"))
        measured.resourceName = "users/999/dataTypes/exercise/dataPoints/222"
        let changed = try MeasuredWalkFeed(account: "111", clientID: "recorder", sessions: [.init(walk: measured)]).signed(privateKey: key.rawRepresentation)
        XCTAssertThrowsError(try MeasuredWalkFeed.imports(changed, publicKey: key.publicKey.rawRepresentation, account: "111", clientID: "recorder"))
        measured.resourceName = "users/111/dataTypes/exercise/dataPoints/222"
        var duplicateAlias = measured; duplicateAlias.id = UUID()
        let aliases = try MeasuredWalkFeed(account: "111", clientID: "recorder", sessions: [.init(walk: measured),.init(walk: duplicateAlias)]).signed(privateKey: key.rawRepresentation)
        XCTAssertThrowsError(try MeasuredWalkFeed.imports(aliases, publicKey: key.publicKey.rawRepresentation, account: "111", clientID: "recorder"))
    }
}
