import Foundation

public struct StepBatch: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var steps: Int
    public var synced: Bool

    public init(id: UUID = UUID(), start: Date, end: Date, steps: Int, synced: Bool = false) {
        self.id = id; self.start = start; self.end = end; self.steps = steps; self.synced = synced
    }

    public var syncIdentifier: String { "padsteps.steps.\(id.uuidString)" }
}

public struct WalkRecording: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let deviceID: UUID
    public var deviceName: String
    public let startedAt: Date
    public var endedAt: Date?
    public var batches: [StepBatch] = []
    public var openBatch: StepBatch?
    public var lastCounter: Int?
    public var lastDeviceSeconds: Int?
    public var lastObservedAt: Date?

    public init(id: UUID = UUID(), deviceID: UUID, deviceName: String, startedAt: Date = Date()) {
        self.id = id; self.deviceID = deviceID; self.deviceName = deviceName; self.startedAt = startedAt
    }

    public var steps: Int { batches.reduce(0) { $0 + $1.steps } + (openBatch?.steps ?? 0) }
    public var syncedSteps: Int { batches.filter(\.synced).reduce(0) { $0 + $1.steps } }
    public var isFinished: Bool { endedAt != nil }

    /// Only changes since the first observed counter are recorded. A mid-walk
    /// connection never imports an unobserved session's old steps.
    public mutating func observe(_ telemetry: PadTelemetry, at now: Date) {
        guard endedAt == nil, telemetry.motion != .unknown,
              (0...65535).contains(telemetry.steps),
              (0...65535).contains(telemetry.elapsedSeconds), now >= startedAt else { return }
        guard let previous = lastCounter, let previousTime = lastObservedAt,
              let previousSeconds = lastDeviceSeconds else {
            lastCounter = telemetry.steps
            lastDeviceSeconds = telemetry.elapsedSeconds
            lastObservedAt = now
            return
        }
        guard now > previousTime else { return }
        let delta: Int
        if telemetry.steps >= previous && telemetry.elapsedSeconds >= previousSeconds {
            delta = telemetry.steps - previous
        } else if telemetry.elapsedSeconds < previousSeconds {
            // Reset observed on a subsequent belt session. Count only that
            // session's new counter, never negative differences.
            delta = telemetry.steps
        } else if previous > 65000 && telemetry.steps < 1000 {
            delta = 65536 - previous + telemetry.steps
        } else {
            // A backwards counter without an elapsed-time reset is malformed.
            return
        }
        // Reject impossible discontinuities rather than adding fictitious data.
        // Reconnection gaps may legitimately include steps measured while away.
        let elapsed = now.timeIntervalSince(previousTime)
        guard Double(delta) <= max(12, elapsed * 5) else { return }
        lastCounter = telemetry.steps
        lastDeviceSeconds = telemetry.elapsedSeconds
        lastObservedAt = now
        guard delta > 0 else {
            if let batch = openBatch, now.timeIntervalSince(batch.start) >= 30 { closeBatch() }
            return
        }
        if openBatch == nil {
            openBatch = StepBatch(start: max(startedAt, previousTime), end: now, steps: delta)
        } else {
            openBatch?.end = now
            openBatch?.steps += delta
        }
        if let batch = openBatch, now.timeIntervalSince(batch.start) >= 30 { closeBatch() }
    }

    public mutating func closeBatch() {
        if let batch = openBatch, batch.steps > 0, batch.end > batch.start { batches.append(batch) }
        openBatch = nil
    }

    public mutating func finish(at date: Date = Date()) {
        closeBatch()
        endedAt = max(date, startedAt, lastObservedAt ?? startedAt)
    }

    public mutating func markSynced(_ batchID: UUID) {
        guard let index = batches.firstIndex(where: { $0.id == batchID }) else { return }
        batches[index].synced = true
    }
}
