import Foundation

public enum UploadDecision: Equatable, Sendable {
    case create
    case adopt(String)
    case resolveOperation(String)
    case review(String)
}

/// A persisted attempt with an uncertain result must never produce a second POST.
public enum UploadGuard {
    public static let overlapMessage = "Google Health already has an overlapping workout. Review it before importing this walk."
    public static func decide(attempted: Bool, matchingNames: [String], hasOverlap: Bool, operationName: String?) -> UploadDecision {
        if matchingNames.count == 1 { return .adopt(matchingNames[0]) }
        if matchingNames.count > 1 { return .review("Multiple matching workouts exist. No additional workout was created.") }
        if attempted {
            if let operationName { return .resolveOperation(operationName) }
            return .review("Upload confirmation was interrupted. Automatic retry is paused to avoid a duplicate.")
        }
        if hasOverlap { return .review(overlapMessage) }
        return .create
    }
}
