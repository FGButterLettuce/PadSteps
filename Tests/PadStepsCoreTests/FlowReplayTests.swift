import XCTest
import CryptoKit
@testable import PadStepsCore

@MainActor
final class FlowReplayTests: XCTestCase {
    struct ExportJournal: Codable { var pending: StepExportIntent?; var prior: StepExportLedger? }
    func testPadToSignedFeedToHealthTransactionSurvivesRestartWithNoExtraWorkout() async throws {
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        var recorder = AutomaticRecorder()
        _ = recorder.observe(.init(steps: 0,elapsedSeconds: 0,motion: .idle),at: epoch)
        _ = recorder.observe(.init(steps: 1,elapsedSeconds: 1,speedKmh: 3),at: epoch.addingTimeInterval(1))
        _ = recorder.observe(.init(steps: 900,elapsedSeconds: 600,speedKmh: 3,distanceMetres: 700),at: epoch.addingTimeInterval(600))
        var complete: AutomaticWalk?
        for second in 601...605 { complete = recorder.observe(.init(steps: 900,elapsedSeconds: 600,distanceMetres: 700,motion: .idle),at: epoch.addingTimeInterval(Double(second))) ?? complete }
        let measured = try XCTUnwrap(complete).preparingStepIdentity()
        XCTAssertTrue(measured.canExportMeasuredSteps)
        XCTAssertTrue(WorkoutCoverage.missing(in: .init(start: measured.start,end: measured.exportEnd),covered: [.init(start: measured.start,end: measured.exportEnd)]).isEmpty,"An existing full Google workout needs no app workout")
        let key = Curve25519.Signing.PrivateKey()
        let feed = try MeasuredWalkFeed(account: "111",clientID: "recorder",sessions: [.init(walk: measured)]).signed(privateKey: key.rawRepresentation)
        let imported = try XCTUnwrap(MeasuredWalkFeed.imports(feed,publicKey: key.publicKey.rawRepresentation,account: "111",clientID: "recorder").first)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("export.json")
        let journal = JournalFile(url: url,fresh: ExportJournal())
        var state = journal.initialValue
        var provider: [String: VersionedStepRecord] = [:]
        provider["manual-health-source"] = .init(start: imported.start,end: imported.end,steps: 123,version: 1)
        var writes = 0
        @MainActor func run(_ store: JournalFile<ExportJournal>, google: Int) async throws -> StepExportOutcome {
            try await StepExportTransaction.perform(walk: imported,googleSteps: google,prior: state.prior,pending: state.pending,legacyConfirmed: state.prior != nil,
                read: { provider[imported.syncIdentifier].map { [$0] } ?? [] },
                write: { count, version in
                    writes += 1; provider[imported.syncIdentifier] = .init(start: imported.start,end: imported.end,steps: count,version: version)
                }, remove: { provider[imported.syncIdentifier] = nil },
                persistIntent: { intent in state.pending = intent; try store.save(state) })
        }
        _ = try await run(journal,google: 450)
        XCTAssertEqual(provider[imported.syncIdentifier]?.steps,450)
        // Simulate termination after provider acknowledgement but before the app
        // commits its completed ledger. Recovery reads the actual persisted file.
        let restarted = JournalFile(url: url,fresh: ExportJournal()); state = restarted.initialValue
        guard case .complete(let recovered,let wrote) = try await run(restarted,google: 450) else { return XCTFail("Expected adoption") }
        XCTAssertFalse(wrote); XCTAssertEqual(writes,1)
        state.prior = recovered; state.pending = nil; try restarted.save(state)
        guard case .complete(let covered,_) = try await run(restarted,google: 900) else { return XCTFail("Expected zero top-up") }
        XCTAssertEqual(covered.steps,0)
        XCTAssertNil(provider[imported.syncIdentifier])
        XCTAssertEqual(provider["manual-health-source"]?.steps,123,"Foreign/manual data must remain untouched")
    }
    func testCoverageUnionAcrossManyIntervalShapesNeverCreatesOverlappingGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let full = WorkoutTimeRange(start: start,end: start.addingTimeInterval(600))
        for seed in 0..<100 {
            let covered = (0..<8).map { index -> WorkoutTimeRange in
                let left = (seed * 37 + index * 71) % 700 - 50
                let length = 6 + (seed * 13 + index * 17) % 120
                return .init(start: start.addingTimeInterval(Double(left)),end: start.addingTimeInterval(Double(left+length)))
            }
            let gaps = WorkoutCoverage.missing(in: full,covered: covered)
            for gap in gaps {
                XCTAssertGreaterThan(gap.seconds,5)
                XCTAssertGreaterThanOrEqual(gap.start,full.start); XCTAssertLessThanOrEqual(gap.end,full.end)
                for interval in covered { XCTAssertFalse(gap.start < interval.end && gap.end > interval.start) }
            }
            for pair in zip(gaps,gaps.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.end,pair.1.start) }
            // Every uncovered integer instant outside a tolerated five-second
            // sliver must belong to exactly one emitted gap.
            for second in 0..<600 {
                let point = start.addingTimeInterval(Double(second)+0.5)
                if gaps.contains(where: { point >= $0.start && point < $0.end }) {
                    XCTAssertFalse(covered.contains { point >= $0.start && point < $0.end })
                }
            }
            var run = 0; var expected = 0
            for second in 0...600 {
                let point = start.addingTimeInterval(Double(second)+0.5)
                let uncovered = second < 600 && !covered.contains { point >= $0.start && point < $0.end }
                if uncovered { run += 1 } else { if run > 5 { expected += run }; run = 0 }
            }
            XCTAssertEqual(gaps.reduce(0) { $0 + Int($1.seconds.rounded()) },expected)
        }
    }
}
