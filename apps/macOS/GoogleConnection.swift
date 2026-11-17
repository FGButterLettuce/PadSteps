import AppKit
import CryptoKit
import Network
import Security
import PadStepsCore

enum PadError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct GoogleHTTPError: LocalizedError {
    let status: Int
    var isTransient: Bool { status == 429 || status >= 500 }
    var errorDescription: String? { "Google Health returned HTTP \(status). Your walk is preserved locally." }
}

struct GoogleRefreshUnavailable: LocalizedError {
    let status: Int
    var errorDescription: String? { "Google could not refresh access right now (HTTP \(status)). Existing authorization is retained; queued walks retry automatically." }
}

@MainActor
final class GoogleConnection: ObservableObject {
    struct Token: Codable {
        var access: String
        var refresh: String
        var expires: Date
    }
    @Published var connected = false
    @Published var authorizationURL: URL?
    @Published var message = "Connect Google Health to save workouts."
    private var token: Token?
    private var listener: NWListener?
    private var timeout: Task<Void, Never>?
    private var verifier = ""
    private var state = ""
    private var redirect = ""
    private var receivedCode = false
    private let service = (Bundle.main.bundleIdentifier ?? "org.padsteps.desktop") + ".google"
    private var client: [String: String] = [:]
    var clientID: String { client["client_id"] ?? "" }
    private var refreshTask: Task<Token, Error>?
    private var listenerReady = false
    private var retryKeychain = true
    private var lastKeychainAttempt = Date.distantPast
    let storage: URL

    init(storage: URL) {
        self.storage = storage
        if let url = Bundle.main.url(forResource: "oauth-client", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let installed = json["installed"] as? [String: Any] {
            client["client_id"] = installed["client_id"] as? String
            client["client_secret"] = installed["client_secret"] as? String
        }
        restoreIfAvailable(force: true)
    }

    func restoreIfAvailable(force: Bool = false) {
        guard retryKeychain, authorizationURL == nil,
              force || Date().timeIntervalSince(lastKeychainAttempt) >= 30 else { return }
        lastKeychainAttempt = Date()
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: "oauth",
                                  kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
                                  kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data, let saved = try? JSONDecoder().decode(Token.self, from: data) {
            token = saved; connected = !saved.refresh.isEmpty
            retryKeychain = false
            if connected { message = "Google Health connected" }
        } else if [errSecInteractionNotAllowed, errSecNotAvailable].contains(status) {
            message = "Waiting for this Mac to unlock before restoring Google access."
        } else {
            retryKeychain = false
        }
    }

    private func persist(_ token: Token) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecAttrAccount as String: "oauth"]
        let data = try JSONEncoder().encode(token)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PadError.message("Couldn’t save Google access in Keychain (\(status)).") }
        self.token = token; connected = true; retryKeychain = false
        if authorizationURL == nil { message = "Google Health connected • automatic saves enabled" }
    }

    private func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PadError.message("Couldn’t prepare secure sign-in.")
        }
        return Data(bytes).base64URL
    }

    func prepareSignIn() async {
        guard authorizationURL == nil else { return }
        do {
            guard client["client_id"] != nil else { throw PadError.message("The Google desktop client is missing from this build.") }
            verifier = try random(); state = try random(); receivedCode = false
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let server = try NWListener(using: parameters)
            listener = server
            listenerReady = false
            server.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.receive(connection, accumulated: Data()) }
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                server.stateUpdateHandler = { [weak self] status in
                    Task { @MainActor in
                        guard let self, !self.listenerReady else { return }
                        switch status {
                        case .ready: self.listenerReady = true; continuation.resume()
                        case .failed: self.listenerReady = true; continuation.resume(throwing: PadError.message("Couldn’t start local Google sign-in."))
                        default: break
                        }
                    }
                }
                server.start(queue: .main)
            }
            guard let port = server.port else { throw PadError.message("No local sign-in port is available.") }
            redirect = "http://127.0.0.1:\(port.rawValue)/"
            let scopes = ["activity_and_fitness.readonly", "activity_and_fitness.writeonly", "health_metrics_and_measurements.readonly"]
                .map { "https://www.googleapis.com/auth/googlehealth.\($0)" }.joined(separator: " ")
            var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            url.queryItems = ["client_id": client["client_id"]!, "redirect_uri": redirect,
                              "response_type": "code", "state": state, "scope": scopes,
                              "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL,
                              "code_challenge_method": "S256", "access_type": "offline",
                              "prompt": "consent"]
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            authorizationURL = url.url
            try Data(url.url!.absoluteString.utf8).write(to: storage.appendingPathComponent("google-sign-in-url.txt"), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storage.appendingPathComponent("google-sign-in-url.txt").path)
            message = "Finish Google sign-in to enable automatic saves."
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1800))
                guard !Task.isCancelled else { return }
                self?.endSignIn(); self?.message = "Sign-in expired. Connect Google Health again."
            }
        } catch { endSignIn(); message = error.localizedDescription }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        if connection.state == .setup { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = accumulated; bytes.append(data ?? Data())
                guard bytes.count < 16384, error == nil else { connection.cancel(); return }
                guard let text = String(data: bytes, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection, accumulated: bytes) } else { connection.cancel() }
                    return
                }
                let request = text.components(separatedBy: "\r\n")[0].components(separatedBy: " ")
                guard request.count >= 2, request[0] == "GET",
                      let parts = URLComponents(string: "http://127.0.0.1" + request[1]), parts.path == "/" else {
                    connection.cancel(); return
                }
                let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
                guard query["state"] == self.state, !self.receivedCode else { connection.cancel(); return }
                self.receivedCode = true
                let body = "PadSteps received your authorization. You can return to the app."
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                do {
                    guard let code = query["code"] else { throw PadError.message("Google authorization was cancelled.") }
                    let json = try await self.tokenRequest(["code": code, "code_verifier": self.verifier,
                                                           "redirect_uri": self.redirect, "grant_type": "authorization_code"])
                    guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
                        throw PadError.message("Google didn’t grant offline access. Connect again and approve background access.")
                    }
                    let granted = Set((json["scope"] as? String ?? "").split(separator: " ").map(String.init))
                    let needed = ["activity_and_fitness.readonly", "activity_and_fitness.writeonly", "health_metrics_and_measurements.readonly"]
                    guard needed.allSatisfy({ granted.contains("https://www.googleapis.com/auth/googlehealth.\($0)") }) else {
                        throw PadError.message("Approve workout read/write and health-metrics read access to finish connecting.")
                    }
                    try self.persist(Token(access: access, refresh: refresh, expires: Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600)))
                    self.message = "Google Health connected • automatic saves enabled"
                } catch { self.message = error.localizedDescription }
                self.endSignIn()
            }
        }
    }

    private func endSignIn() {
        timeout?.cancel(); timeout = nil; listener?.cancel(); listener = nil; authorizationURL = nil
        try? FileManager.default.removeItem(at: storage.appendingPathComponent("google-sign-in-url.txt"))
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var all = fields; all["client_id"] = client["client_id"]; all["client_secret"] = client["client_secret"]
        var components = URLComponents(); components.queryItems = all.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.timeoutInterval = 30
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard status == 200, let json else {
            if fields["grant_type"] == "refresh_token", OAuthRecovery.requiresReconnect(status: status, error: json?["error"] as? String) {
                connected = false; retryKeychain = false
                message = "Google authorization was rejected. Reconnect to resume automatic saves."
                throw PadError.message("Reconnect Google Health to restore access. Saved walks remain queued.")
            }
            throw GoogleRefreshUnavailable(status: status)
        }
        return json
    }

    private func accessToken(force: Bool = false) async throws -> String {
        guard let saved = token, !saved.refresh.isEmpty else { throw PadError.message("Connect Google Health first.") }
        if !force && saved.expires.timeIntervalSinceNow > 120 { return saved.access }
        if let task = refreshTask { return try await task.value.access }
        let task = Task { () throws -> Token in
            let json = try await tokenRequest(["refresh_token": saved.refresh, "grant_type": "refresh_token"])
            guard let access = json["access_token"] as? String else { throw PadError.message("Google did not return an access token.") }
            let fresh = Token(access: access, refresh: json["refresh_token"] as? String ?? saved.refresh,
                              expires: Date().addingTimeInterval(json["expires_in"] as? Double ?? 3600))
            try persist(fresh); return fresh
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.access
    }

    func request(_ method: String = "GET", _ resource: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        guard !resource.contains("://"), !resource.contains("..") else { throw PadError.message("Invalid Google resource.") }
        var url = URLComponents(string: "https://health.googleapis.com/v4/" + resource)!
        if !query.isEmpty { url.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        func make(_ bearer: String) throws -> URLRequest {
            var request = URLRequest(url: url.url!); request.httpMethod = method; request.timeoutInterval = 30
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
            if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            return request
        }
        var (data, response) = try await URLSession.shared.data(for: make(try await accessToken()))
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            (data, response) = try await URLSession.shared.data(for: make(try await accessToken(force: true)))
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw GoogleHTTPError(status: status) }
        if data.isEmpty { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func pages(_ resource: String, query: [String: String]) async throws -> [[String: Any]] {
        var parameters = query; var points: [[String: Any]] = []
        for _ in 0..<100 {
            let response = try await request("GET", resource, query: parameters)
            points += response["dataPoints"] as? [[String: Any]] ?? []
            guard let next = response["nextPageToken"] as? String, !next.isEmpty else { return points }
            parameters["pageToken"] = next
        }
        throw PadError.message("Google returned too many pages. This walk needs review.")
    }

    func verifyConnection() async {
        guard connected else { return }
        do {
            _ = try await accessToken(force: true)
            let identity = try await request("GET", "users/me/identity")
            guard identity["healthUserId"] is String else { throw PadError.message("Google did not identify your health account.") }
            let check: [String: Any] = ["checkedAt": PadMonitor.iso(Date()), "refreshVerified": true, "identityReadVerified": true]
            try JSONSerialization.data(withJSONObject: check).write(to: storage.appendingPathComponent("google-connection-check.json"), options: .atomic)
            message = "Google Health connected • automatic saves enabled"
        } catch { message = error.localizedDescription }
    }
}

extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
