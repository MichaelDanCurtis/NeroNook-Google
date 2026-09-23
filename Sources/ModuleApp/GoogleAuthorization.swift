import AppKit
import Network
import Security

struct GoogleKeychain {
    private static let service = "cafe.nero.plugin.google.account"
    static func save(_ credential: GoogleCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "account"]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addition = query
            addition[kSecValueData as String] = data
            addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let result = SecItemAdd(addition as CFDictionary, nil)
            guard result == errSecSuccess else { throw GoogleFailure.keychain(result) }
        } else if status != errSecSuccess { throw GoogleFailure.keychain(status) }
    }
    static func load() throws -> GoogleCredential? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "account", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw GoogleFailure.keychain(status) }
        return try JSONDecoder().decode(GoogleCredential.self, from: data)
    }
    static func remove() throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "account"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoogleFailure.keychain(status) }
    }
}

/// A bounded, loopback-only callback listener. No credentials are ever echoed in HTML or logs.
@MainActor
final class GoogleLoopback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var result: CheckedContinuation<String, Error>?
    private var completed: Result<String, Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var timeout: Task<Void, Never>?
    private let state: String
    init(state: String) { self.state = state }
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        server.stateUpdateHandler = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                switch status {
                case .ready:
                    guard let port = server.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else { self.finish(.failure(GoogleFailure.invalidCallback)); return }
                    self.ready?.resume(returning: url); self.ready = nil
                case .failed: self.finish(.failure(GoogleFailure.invalidCallback))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(GoogleFailure.signInExpired))
        }
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
            server.start(queue: .main)
        }
    }
    func waitForCode() async throws -> String {
        if let completed { return try completed.get() }
        return try await withCheckedThrowingContinuation { result = $0 }
    }
    func cancel() { finish(.failure(GoogleFailure.cancelled)) }
    private func accept(_ connection: NWConnection) {
        guard completed == nil, connections.count < 8 else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: .main)
        receive(connection, accumulated: Data())
        Task { [weak self, weak connection] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, let connection else { return }
            self.close(connection)
        }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.completed == nil else { connection.cancel(); return }
                var buffer = accumulated
                if let data { buffer.append(data) }
                guard buffer.count <= 8192, error == nil else { self.close(connection); return }
                if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                    let first = request.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                    guard first.count == 3, first[0] == "GET" else { self.respond(connection, valid: false); return }
                    let outcome = Result { try GoogleOAuthProtocol.callbackCode(target: String(first[1]), expectedState: self.state) }
                    if case .failure(GoogleFailure.invalidCallback) = outcome { self.respond(connection, valid: false); return }
                    self.respond(connection, valid: true) { self.finish(outcome) }
                } else if isComplete { self.close(connection) }
                else { self.receive(connection, accumulated: buffer) }
            }
        }
    }
    private func respond(_ connection: NWConnection, valid: Bool, after: (() -> Void)? = nil) {
        let body = valid ? "<h1>Return to Google Workspace</h1><p>You can close this tab. Google Workspace is finishing your Google connection.</p>" : "<h1>Invalid sign-in response</h1>"
        let response = "HTTP/1.1 \(valid ? "200 OK" : "400 Bad Request")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection); after?() }
        })
    }
    private func close(_ connection: NWConnection) { connection.cancel(); connections.removeValue(forKey: ObjectIdentifier(connection)) }
    private func finish(_ outcome: Result<String, Error>) {
        guard completed == nil else { return }
        completed = outcome
        ready?.resume(throwing: outcome.failure ?? GoogleFailure.invalidCallback); ready = nil
        result?.resume(with: outcome); result = nil
        timeout?.cancel(); timeout = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }; connections.removeAll()
    }
}
private extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}

final class GoogleHTTP: NSObject, URLSessionTaskDelegate {
    // Google API traffic never follows a redirect carrying authorization to another host.
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        super.init()
    }
    private lazy var session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    func close() { session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func data(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GoogleFailure.malformed }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw GoogleFailure.reconnect
        case 403: throw GoogleFailure.permission
        default:
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["error"] as? String == "invalid_grant" { throw GoogleFailure.reconnect }
            throw GoogleFailure.http(http.statusCode)
        }
    }
    func token(_ values: [String: String]) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.httpBody = GoogleOAuthProtocol.form(values)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: await data(request))
    }
}

@MainActor
final class GoogleAuthorization {
    private var callback: GoogleLoopback?
    private let http = GoogleHTTP()
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleFailure.invalidCallback }
        return GoogleOAuthProtocol.base64URL(Data(bytes))
    }
    func connect(client: GoogleClientConfiguration, services: Set<GoogleService>) async throws -> GoogleCredential {
        let verifier = try Self.random(), state = try Self.random()
        let server = GoogleLoopback(state: state); callback = server
        defer { server.cancel(); callback = nil }
        let redirect = try await server.start()
        try Task.checkCancellation()
        let scopes = Set(services.map(\.scope)).union(["openid", "email"])
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": client.clientID, "redirect_uri": redirect.absoluteString, "response_type": "code", "scope": scopes.sorted().joined(separator: " "), "state": state, "code_challenge": GoogleOAuthProtocol.challenge(for: verifier), "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent select_account"].map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let authorizationURL = url.url, NSWorkspace.shared.open(authorizationURL) else { throw GoogleFailure.invalidCallback }
        let code = try await server.waitForCode()
        try Task.checkCancellation()
        var values = ["client_id": client.clientID, "code": code, "redirect_uri": redirect.absoluteString, "grant_type": "authorization_code", "code_verifier": verifier]
        if let secret = client.clientSecret { values["client_secret"] = secret }
        let token = try await http.token(values)
        guard let refresh = token.refresh_token, !refresh.isEmpty else { throw GoogleFailure.reconnect }
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!)
        request.setValue("Bearer \(token.access_token)", forHTTPHeaderField: "Authorization")
        let profile = try JSONDecoder().decode(GoogleProfile.self, from: await http.data(request))
        return GoogleCredential(accessToken: token.access_token, refreshToken: refresh, expiresAt: Date().addingTimeInterval(token.expires_in), scopes: token.scope.map { Set($0.split(separator: " ").map(String.init)) } ?? scopes, email: profile.email, subject: profile.sub, client: client)
    }
    func cancel() { callback?.cancel() }
}
