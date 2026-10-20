import Foundation
import NookPluginSDK

actor GoogleAPI {
    private var credential: GoogleCredential
    private let http: GoogleHTTP
    private let save: (GoogleCredential) throws -> Void
    private var active = true
    private var refreshTask: Task<GoogleTokenResponse, Error>?
    init(credential: GoogleCredential, http: GoogleHTTP = GoogleHTTP(), save: @escaping (GoogleCredential) throws -> Void = GoogleKeychain.save) { self.credential = credential; self.http = http; self.save = save }
    func invalidate() { active = false; http.close(); refreshTask?.cancel(); refreshTask = nil }
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard active else { throw CancellationError() }
        if !forceRefresh, credential.expiresAt > Date().addingTimeInterval(60) { return credential.accessToken }
        if refreshTask == nil {
            var values = ["client_id": credential.client.clientID, "refresh_token": credential.refreshToken, "grant_type": "refresh_token"]
            if let secret = credential.client.clientSecret { values["client_secret"] = secret }
            refreshTask = Task { try await http.token(values) }
        }
        guard let pending = refreshTask else { throw GoogleFailure.reconnect }
        do {
            let token = try await pending.value
            guard active else { throw CancellationError() }
            credential.accessToken = token.access_token
            credential.expiresAt = Date().addingTimeInterval(token.expires_in)
            if let refresh = token.refresh_token { credential.refreshToken = refresh }
            if let scope = token.scope { credential.scopes = Set(scope.split(separator: " ").map(String.init)) }
            try save(credential)
            refreshTask = nil
            return credential.accessToken
        } catch { refreshTask = nil; throw error }
    }
    private func get<T: Decodable>(_ type: T.Type, host: String = "www.googleapis.com", path: String, query: [URLQueryItem] = [], retry: Bool = true) async throws -> T {
        try Task.checkCancellation()
        let token = try await accessToken()
        guard active, ["www.googleapis.com", "gmail.googleapis.com", "tasks.googleapis.com"].contains(host),
              var components = URLComponents(string: "https://\(host)\(path)") else { throw GoogleFailure.malformed }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw GoogleFailure.malformed }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let data = try await http.data(request)
            try Task.checkCancellation()
            guard active else { throw CancellationError() }
            return try JSONDecoder().decode(type, from: data)
        } catch GoogleFailure.reconnect where retry {
            _ = try await accessToken(forceRefresh: true)
            return try await get(type, host: host, path: path, query: query, retry: false)
        }
    }
    private func pages<T: Decodable>(_ type: T.Type, host: String = "www.googleapis.com", path: String, query: [URLQueryItem] = []) async throws -> [T] {
        var values: [T] = [], cursor: String?, seen = Set<String>()
        for _ in 0..<100 {
            let q = query + (cursor.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page = try await get(GooglePage<T>.self, host: host, path: path, query: q)
            values += page.items ?? []
            guard values.count <= 50_000 else { throw GoogleFailure.pageLimit }
            guard let next = page.nextPageToken, !next.isEmpty else { return values }
            guard seen.insert(next).inserted else { throw GoogleFailure.malformed }
            cursor = next
        }
        throw GoogleFailure.pageLimit
    }
    private static func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))! }
    func calendars() async throws -> [GoogleCalendar] {
        try await pages(GoogleCalendar.self, path: "/calendar/v3/users/me/calendarList", query: [.init(name: "maxResults", value: "250")]).filter { $0.deleted != true }
    }
    func events(calendar: GoogleCalendar, date: Date) async throws -> [AgendaEntry] {
        let start = Calendar.current.startOfDay(for: date)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        let formatter = ISO8601DateFormatter()
        let rows = try await pages(GoogleEvent.self, path: "/calendar/v3/calendars/\(Self.segment(calendar.id))/events", query: [
            .init(name: "timeMin", value: formatter.string(from: start)), .init(name: "timeMax", value: formatter.string(from: end)),
            .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"), .init(name: "showDeleted", value: "false"), .init(name: "maxResults", value: "2500")])
        return rows.compactMap { $0.agenda(calendar: calendar) }
    }
    func calendarEvents(calendar: GoogleCalendar, start: Date, end: Date) async throws -> [PluginCalendarEvent] {
        let formatter = ISO8601DateFormatter()
        let rows = try await pages(GoogleEvent.self, path: "/calendar/v3/calendars/\(Self.segment(calendar.id))/events", query: [
            .init(name: "timeMin", value: formatter.string(from: start)), .init(name: "timeMax", value: formatter.string(from: end)),
            .init(name: "singleEvents", value: "true"), .init(name: "orderBy", value: "startTime"), .init(name: "showDeleted", value: "false"), .init(name: "maxResults", value: "2500")])
        return try rows.filter { $0.status != "cancelled" }.map { try $0.sdkEvent(calendar: calendar) }
    }
    func calendarEvent(_ reference: PluginCalendarReference, calendar: GoogleCalendar) async throws -> PluginCalendarEvent? {
        do {
            let event = try await get(GoogleEvent.self, path: "/calendar/v3/calendars/\(Self.segment(reference.calendar))/events/\(Self.segment(reference.event))")
            guard event.status != "cancelled" else { return nil }
            let value = try event.sdkEvent(calendar: calendar)
            guard value.reference == reference else { throw GoogleFailure.malformed }; return value
        } catch GoogleFailure.http(let code) where [404,410].contains(code) { return nil }
    }
    func inbox() async throws -> [GoogleMessage] {
        let list = try await get(GoogleMessageList.self, host: "gmail.googleapis.com", path: "/gmail/v1/users/me/messages", query: [.init(name: "labelIds", value: "INBOX"), .init(name: "maxResults", value: "20")])
        var messages: [GoogleMessage] = []
        for ref in list.messages ?? [] {
            messages.append(try await get(GoogleMessage.self, host: "gmail.googleapis.com", path: "/gmail/v1/users/me/messages/\(Self.segment(ref.id))", query: [.init(name: "format", value: "metadata"), .init(name: "metadataHeaders", value: "From"), .init(name: "metadataHeaders", value: "Subject"), .init(name: "metadataHeaders", value: "Date")]))
        }
        return messages.sorted { ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast) }
    }
    func tasks() async throws -> [GoogleTask] {
        let lists = try await pages(GoogleTaskList.self, host: "tasks.googleapis.com", path: "/tasks/v1/users/@me/lists", query: [.init(name: "maxResults", value: "100")])
        var tasks: [GoogleTask] = []
        for list in lists {
            tasks += try await pages(GoogleTask.self, host: "tasks.googleapis.com", path: "/tasks/v1/lists/\(Self.segment(list.id))/tasks", query: [.init(name: "maxResults", value: "100"), .init(name: "showCompleted", value: "false"), .init(name: "showDeleted", value: "false")])
        }
        return tasks.filter { $0.deleted != true && $0.status != "completed" }
    }
    func recentFiles() async throws -> [GoogleFile] {
        let list = try await get(GoogleFileList.self, path: "/drive/v3/files", query: [.init(name: "q", value: "trashed = false"), .init(name: "pageSize", value: "25"), .init(name: "orderBy", value: "modifiedTime desc"), .init(name: "fields", value: "files(id,name,mimeType,modifiedTime,webViewLink)")])
        return list.files ?? []
    }
}
