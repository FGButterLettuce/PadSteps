import XCTest
@testable import PadStepsCore

final class JournalSafetyTests: XCTestCase {
    struct Value: Codable { var version = 1; var count = 0 }
    func testUnreadableJournalCannotBeOverwrittenByStartupOrSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("journal.json"), original = Data("broken journal, preserve for recovery".utf8)
        try original.write(to: url)
        let store = JournalFile(url: url, fresh: Value())
        XCTAssertFalse(store.readable)
        XCTAssertThrowsError(try store.save(Value(count: 99)))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testUnknownJournalVersionIsPreserved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("journal.json")
        let data = try JSONEncoder().encode(Value(version: 2,count: 7)); try data.write(to: url)
        let store = JournalFile(url: url, fresh: Value(), validate: { $0.version == 1 })
        XCTAssertFalse(store.readable); XCTAssertThrowsError(try store.save(Value()))
        XCTAssertEqual(try Data(contentsOf: url),data)
    }
    func testUnlockCanRestoreTheJournalWithoutResettingItsContents() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("journal.json")
        try Data("temporarily unreadable".utf8).write(to: url)
        let store = JournalFile(url: url, fresh: Value())
        XCTAssertNil(store.reloadIfAvailable())
        try JSONEncoder().encode(Value(count: 17)).write(to: url)
        XCTAssertEqual(store.reloadIfAvailable()?.count,17)
        XCTAssertTrue(store.readable)
        XCTAssertNil(store.reloadIfAvailable(),"A healthy live journal must not be replaced by a stale disk snapshot")
    }
    func testNewAndExistingHealthyJournalRemainWritable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("journal.json")
        let new = JournalFile(url: url, fresh: Value())
        XCTAssertTrue(new.readable); try new.save(Value(count: 12))
        let restored = JournalFile(url: url, fresh: Value())
        XCTAssertTrue(restored.readable); XCTAssertEqual(restored.initialValue.count,12)
    }
}
