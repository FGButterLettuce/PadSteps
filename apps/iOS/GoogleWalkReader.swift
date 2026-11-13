import GoogleSignIn
import UIKit
import PadStepsCore

/// Read-only phone client. Mac credentials and Google write access never enter this app.
@MainActor
final class GoogleWalkReader {
    static let scope = "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly"
    var email: String? { GIDSignIn.sharedInstance.currentUser?.profile?.email }
    var configured: Bool { Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String != nil }
    private var restoring: Task<Void, Error>?

    func restore() async throws {
        guard configured else { throw ProofError.message("The iPhone Google client is not configured yet.") }
        if GIDSignIn.sharedInstance.currentUser == nil {
            if let restoring { try await restoring.value; return }
            let task = Task { _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn() }
            restoring = task
            defer { restoring = nil }
            try await task.value
        }
    }

    func signIn() async throws {
        guard configured else { throw ProofError.message("The iPhone Google client has not been configured in this build.") }
        if let restoring { try? await restoring.value }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else {
            throw ProofError.message("Open PadSteps on your iPhone to sign in.")
        }
        while let presented = controller.presentedViewController { controller = presented }
        _ = try await GIDSignIn.sharedInstance.signIn(withPresenting: controller,
             hint: nil, additionalScopes: [Self.scope])
    }

    func get(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        try Task.checkCancellation()
        try await restore()
        guard let current = GIDSignIn.sharedInstance.currentUser,
              current.grantedScopes?.contains(Self.scope) == true else {
            throw ProofError.message("Connect Google Health and allow read access to activity and fitness.")
        }
        let user = try await current.refreshTokensIfNeeded()
        var components = URLComponents(string: "https://health.googleapis.com/v4/\(path)")!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("Bearer \(user.accessToken.tokenString)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ProofError.message("Google Health read failed (\(code)). Retry syncing; reconnect Google if access was revoked.")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProofError.message("Google Health returned an unreadable response.")
        }
        return object
    }

    func userID() async throws -> String {
        let identity = try await get("users/me/identity")
        guard let id = identity["healthUserId"] as? String, !id.isEmpty, id.allSatisfy(\.isNumber) else {
            throw ProofError.message("Google Health account identity could not be verified.")
        }
        return id
    }

    func walks(from start: Date, to end: Date, account: String) async throws -> [PadStepImport] {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let filter = "exercise.interval.civil_start_time >= \"\(f.string(from: start))\" AND exercise.interval.civil_start_time < \"\(f.string(from: end))\""
        var result: [String: PadStepImport] = [:]
        var page: String?; var seen = Set<String>()
        repeat {
            var query = [URLQueryItem(name: "filter", value: filter), URLQueryItem(name: "pageSize", value: "25")]
            if let page { query.append(URLQueryItem(name: "pageToken", value: page)) }
            // All sources: iOS OAuth has a different client ID from our Mac recorder.
            let response = try await get("users/me/dataTypes/exercise/dataPoints", query: query)
            for point in response["dataPoints"] as? [[String: Any]] ?? [] {
                if let walk = try PadStepImport.parse(JSONSerialization.data(withJSONObject: point),
                    recorderClientID: Bundle.main.object(forInfoDictionaryKey: "PadStepsRecorderClientID") as? String ?? "",
                    correctionPublicKey: (Bundle.main.object(forInfoDictionaryKey: "PadStepsCorrectionPublicKey") as? String).flatMap { Data(base64Encoded: $0) }) {
                    guard walk.userID == account else { throw ProofError.message("Workout account did not match the signed-in Google Health account.") }
                    // A local bound protects against widened API civil-time interpretations.
                    if walk.start >= start, walk.start < end, walk.end <= Date() {
                        if let old = result[walk.id], old != walk { throw ProofError.message("Google returned conflicting copies of a walk.") }
                        result[walk.id] = walk
                    }
                }
            }
            page = response["nextPageToken"] as? String
            if let value = page, !value.isEmpty {
                guard seen.insert(value).inserted, seen.count <= 100 else { throw ProofError.message("Google pagination did not finish. No sync cursor was advanced.") }
            } else { page = nil }
        } while page != nil
        return result.values.sorted { $0.start < $1.start }
    }
}
