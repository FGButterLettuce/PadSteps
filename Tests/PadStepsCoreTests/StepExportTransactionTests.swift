import XCTest
@testable import PadStepsCore

@MainActor
final class StepExportTransactionTests: XCTestCase {
    enum Failure: Error { case disk, afterProviderWrite, readUnavailable }
    final class Adapter {
        var records: [VersionedStepRecord] = []
        var intent: StepExportIntent?
        var prior: StepExportLedger?
        var writes = 0
        var deletes = 0
        var diskUnavailable = false
        var stopAfterProviderWrite = false
        var readUnavailable = false
        var hideReads = false
    }
    private func walk() -> PadStepImport {
        .init(resource: "users/111/dataTypes/exercise/dataPoints/local-session",userID: "111",start: Date(timeIntervalSince1970: 1_800_000_000),end: Date(timeIntervalSince1970: 1_800_000_600),steps: 900)
    }
    private func run(_ adapter: Adapter, google: Int = 400) async throws -> StepExportOutcome {
        let measured = walk()
        return try await StepExportTransaction.perform(walk: measured,googleSteps: google,prior: adapter.prior,pending: adapter.intent,legacyConfirmed: adapter.prior != nil,
            read: {
                if adapter.readUnavailable { throw Failure.readUnavailable }
                if adapter.hideReads { return [] }
                return adapter.records
            }, write: { steps, version in
                adapter.writes += 1
                adapter.records = [.init(start: measured.start,end: measured.end,steps: steps,version: version)]
                if adapter.stopAfterProviderWrite { throw Failure.afterProviderWrite }
            }, remove: {
                adapter.deletes += 1; adapter.records = []
            }, persistIntent: { intent in
                if adapter.diskUnavailable { throw Failure.disk }
                adapter.intent = intent
            })
    }
    func testInterruptedSaveIsAdoptedAfterRestartWithoutAnotherProviderWrite() async throws {
        let store = Adapter(); store.stopAfterProviderWrite = true
        do { _ = try await run(store); XCTFail("Expected an interrupted provider acknowledgement") } catch {}
        XCTAssertEqual(store.writes,1); XCTAssertEqual(store.intent?.writeAcknowledged,false)
        // Recreate the persisted process state while keeping the provider's data.
        let restored = Adapter(); restored.records = store.records
        restored.intent = try JSONDecoder().decode(StepExportIntent.self,from: JSONEncoder().encode(store.intent!))
        let result = try await run(restored)
        guard case .complete(let ledger,let wrote) = result else { return XCTFail("Expected adoption") }
        XCTAssertEqual(ledger.steps,500); XCTAssertFalse(wrote); XCTAssertEqual(restored.writes,0)
        XCTAssertEqual(restored.records.count,1)
    }
    func testDiskFailureBeforeIntentPreventsAnyHealthWrite() async {
        let store = Adapter(); store.diskUnavailable = true
        do { _ = try await run(store); XCTFail("Expected disk failure") } catch {}
        XCTAssertEqual(store.writes,0); XCTAssertTrue(store.records.isEmpty)
    }
    func testReadFailureCannotBeTreatedAsAnEmptyHealthStore() async {
        let store = Adapter(); store.readUnavailable = true
        do { _ = try await run(store); XCTFail("Expected read failure") } catch {}
        XCTAssertEqual(store.writes,0)
    }
    func testGoogleRevisionUpdatesSameRecordAndCompleteCoverageRemovesOnlyTopUp() async throws {
        let store = Adapter()
        guard case .complete(let first,_) = try await run(store) else { return XCTFail("Expected save") }
        store.prior = first; store.intent = nil
        guard case .complete(let second,_) = try await run(store,google: 500) else { return XCTFail("Expected absolute update") }
        XCTAssertEqual(second.steps,400); XCTAssertEqual(second.version,first.version+1); XCTAssertEqual(store.records.count,1)
        store.prior = second; store.intent = nil
        guard case .complete(let covered,_) = try await run(store,google: 900) else { return XCTFail("Expected redundant top-up removal") }
        XCTAssertEqual(covered.steps,0); XCTAssertEqual(store.deletes,1); XCTAssertTrue(store.records.isEmpty)
        store.prior = covered; store.intent = nil
        _ = try await run(store,google: 900)
        XCTAssertEqual(store.writes,2); XCTAssertEqual(store.deletes,1)
    }
    func testMissingConfirmedSampleIsHeldRatherThanRestored() async throws {
        let store = Adapter(); store.prior = .init(steps: 500,version: 2)
        guard case .review = try await run(store) else { return XCTFail("Must preserve a deliberate deletion") }
        XCTAssertEqual(store.writes,0)
    }
    func testDeniedHealthReadAccessDoesNotCauseRepeatedSaves() async throws {
        let store = Adapter(); store.hideReads = true
        do { _ = try await run(store); XCTFail("Readback must be unconfirmed") } catch {}
        XCTAssertEqual(store.writes,1)
        guard case .review = try await run(store) else { return XCTFail("An unreadable store must not trigger another save") }
        XCTAssertEqual(store.writes,1); XCTAssertEqual(store.records.count,1)
        store.hideReads = false
        guard case .complete(_,let wrote) = try await run(store) else { return XCTFail("Expected readback recovery") }
        XCTAssertFalse(wrote); XCTAssertEqual(store.writes,1)
    }
}
