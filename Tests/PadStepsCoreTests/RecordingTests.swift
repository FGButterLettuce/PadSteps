import Foundation
import Testing
@testable import PadStepsCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func sample(_ steps: Int, _ seconds: Int) -> PadTelemetry {
    PadTelemetry(steps: steps, elapsedSeconds: seconds)
}

@Test func connectingMidWalkCountsOnlyNewSteps() {
    var walk = WalkRecording(deviceID: UUID(), deviceName: "P2 Max", startedAt: epoch)
    walk.observe(sample(500, 300), at: epoch)
    walk.observe(sample(505, 303), at: epoch.addingTimeInterval(3))
    walk.observe(sample(505, 304), at: epoch.addingTimeInterval(4))
    #expect(walk.steps == 5)
    #expect(walk.batches.isEmpty)
    walk.finish(at: epoch.addingTimeInterval(5))
    #expect(walk.batches.count == 1)
    #expect(walk.steps == 5)
}

@Test func restartsPreserveTheBaselineAndPendingSteps() throws {
    var walk = WalkRecording(deviceID: UUID(), deviceName: "P2 Max", startedAt: epoch)
    walk.observe(sample(0, 0), at: epoch)
    walk.observe(sample(5, 3), at: epoch.addingTimeInterval(3))
    let saved = try JSONEncoder().encode(walk)
    var restored = try JSONDecoder().decode(WalkRecording.self, from: saved)
    restored.observe(sample(11, 8), at: epoch.addingTimeInterval(8))
    restored.finish(at: epoch.addingTimeInterval(9))
    #expect(restored.steps == 11)
    #expect(restored.batches[0].id == walk.openBatch?.id)
}

@Test func countsNewBeltSessionAfterCounterReset() {
    var walk = WalkRecording(deviceID: UUID(), deviceName: "P2 Max", startedAt: epoch)
    walk.observe(sample(98, 98), at: epoch)
    walk.observe(sample(100, 100), at: epoch.addingTimeInterval(2))
    walk.observe(sample(3, 2), at: epoch.addingTimeInterval(5))
    #expect(walk.steps == 5)
}

@Test func backwardsOrOutOfOrderDataCannotAddSteps() {
    var walk = WalkRecording(deviceID: UUID(), deviceName: "P2 Max", startedAt: epoch)
    walk.observe(sample(100, 100), at: epoch)
    walk.observe(sample(40, 101), at: epoch.addingTimeInterval(1))
    walk.observe(sample(102, 102), at: epoch.addingTimeInterval(2))
    walk.observe(sample(103, 103), at: epoch.addingTimeInterval(1))
    #expect(walk.steps == 2)
}

@Test func impossibleJumpIsNotWrittenToHealth() {
    var walk = WalkRecording(deviceID: UUID(), deviceName: "P2 Max", startedAt: epoch)
    walk.observe(sample(0, 0), at: epoch)
    walk.observe(sample(4000, 1), at: epoch.addingTimeInterval(1))
    #expect(walk.steps == 0)
}

@Test func batchesHaveStableIdentifiersAcrossRetries() throws {
    var walk = WalkRecording(deviceID: UUID(), deviceName: "P2 Max", startedAt: epoch)
    walk.observe(sample(0, 0), at: epoch)
    walk.observe(sample(30, 30), at: epoch.addingTimeInterval(30))
    let identifier = walk.batches[0].syncIdentifier
    var restored = try JSONDecoder().decode(WalkRecording.self, from: JSONEncoder().encode(walk))
    #expect(restored.batches[0].syncIdentifier == identifier)
    restored.markSynced(restored.batches[0].id)
    #expect(restored.syncedSteps == 30)
    restored.finish(at: epoch.addingTimeInterval(40))
    restored.observe(sample(70, 70), at: epoch.addingTimeInterval(70))
    #expect(restored.steps == 30)
}

@Test func realCounterWrapIsHandled() {
    var walk = WalkRecording(deviceID: UUID(), deviceName: "P2 Max", startedAt: epoch)
    walk.observe(sample(65534, 40000), at: epoch)
    walk.observe(sample(1, 40002), at: epoch.addingTimeInterval(2))
    #expect(walk.steps == 3)
}
