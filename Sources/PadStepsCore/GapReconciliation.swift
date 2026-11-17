import Foundation

public struct OwnedGapCandidate: Sendable {
    public let resource: String
    public let range: WorkoutTimeRange
    public init(resource: String, range: WorkoutTimeRange) { self.resource = resource; self.range = range }
}
public enum GapReconciliationError: LocalizedError {
    case awaitingCreation, duplicates, invalidJournal
    public var errorDescription: String? {
        switch self {
        case .awaitingCreation: return "Waiting for Google to confirm the earlier gap save. Check again searches for that attempt; no extra workout will be created."
        case .duplicates: return "Multiple matching gap records were found. Existing workouts are preserved; show walk files to review them."
        case .invalidJournal: return "The saved workout plan is inconsistent. Existing workouts were preserved; show walk files to inspect the recording."
        }
    }
}
public extension WorkoutGapExport {
    static func isPendingResource(_ value: String) -> Bool { value.split(separator: "/").last?.hasPrefix("padsteps-") == true }

    func resolvingCreations(candidates: [OwnedGapCandidate]) throws -> Self {
        guard Set(resources).count == resources.count else { throw GapReconciliationError.invalidJournal }
        var result = self
        var confirmed = Set(confirmedResources ?? [])
        for (index,name) in resources.enumerated() where Self.isPendingResource(name) && creationStarted?[name] == true && !(rejectedCreations ?? []).contains(name) {
            guard let range = pendingRanges?[name] ?? (index < gaps.count ? gaps[index] : nil) else { throw GapReconciliationError.invalidJournal }
            let matching = candidates.filter { abs($0.range.start.timeIntervalSince(range.start)) < 0.002 && abs($0.range.end.timeIntervalSince(range.end)) < 0.002 }
            guard matching.count <= 1 else { throw GapReconciliationError.duplicates }
            guard let found = matching.first else { throw GapReconciliationError.awaitingCreation }
            result.resources[index] = found.resource; confirmed.insert(found.resource)
        }
        var retired = retiredResources.filter { !Self.isPendingResource($0) }
        for name in retiredResources where Self.isPendingResource(name) {
            guard creationStarted?[name] == true, !(rejectedCreations ?? []).contains(name) else { continue }
            let matching = candidates.filter { point in
                guard !result.resources.contains(point.resource) else { return false }
                if let range = pendingRanges?[name] {
                    return abs(point.range.start.timeIntervalSince(range.start)) < 0.002 && abs(point.range.end.timeIntervalSince(range.end)) < 0.002
                }
                return true // Recover old journals that lost a retired ticket's range.
            }
            guard !matching.isEmpty else { throw GapReconciliationError.awaitingCreation }
            retired += matching.map(\.resource)
        }
        result.confirmedResources = Array(confirmed).sorted()
        result.retiredResources = Array(Set(retired)).sorted()
        return result
    }

    func replacingCoverage(_ desired: [WorkoutTimeRange], makePending: () -> String) throws -> Self {
        guard Set(resources).count == resources.count, desired.allSatisfy({ $0.end > $0.start }) else { throw GapReconciliationError.invalidJournal }
        for name in resources + retiredResources where Self.isPendingResource(name) {
            if creationStarted?[name] == true && !(rejectedCreations ?? []).contains(name) { throw GapReconciliationError.awaitingCreation }
        }
        var result = self
        var assigned: [String] = []
        for index in desired.indices {
            let name = index < resources.count ? resources[index] : makePending()
            guard !assigned.contains(name) else { throw GapReconciliationError.invalidJournal }
            assigned.append(name)
        }
        let retired = retiredResources.filter { !Self.isPendingResource($0) } + resources.filter { !assigned.contains($0) && !Self.isPendingResource($0) }
        result.gaps = desired; result.resources = assigned
        result.retiredResources = Array(Set(retired).subtracting(assigned)).sorted()
        return result
    }
}
