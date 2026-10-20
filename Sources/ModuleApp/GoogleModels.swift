import Foundation
import CryptoKit

struct GoogleClientConfiguration: Codable, Equatable {
    let clientID: String
    let clientSecret: String?
    static func imported(_ data: Data) throws -> Self {
        struct Download: Decodable { let installed: Installed }
        struct Installed: Decodable { let client_id: String; let client_secret: String? }
        let value = try JSONDecoder().decode(Download.self, from: data).installed
        guard value.client_id.hasSuffix(".apps.googleusercontent.com"), !value.client_id.contains(where: \.isWhitespace) else { throw GoogleFailure.configuration }
        return Self(clientID: value.client_id, clientSecret: value.client_secret)
    }
}

enum GoogleService: String, CaseIterable, Identifiable, Codable {
    case calendar, gmail, tasks, drive
    var id: String { rawValue }
    var title: String { switch self { case .calendar: return "Google Calendar"; case .gmail: return "Gmail"; case .tasks: return "Google Tasks"; case .drive: return "Drive, Docs, Sheets & Slides" } }
    var scope: String { "https://www.googleapis.com/auth/" + (self == .calendar ? "calendar.readonly" : self == .gmail ? "gmail.metadata" : self == .tasks ? "tasks.readonly" : "drive.metadata.readonly") }
    var apiName: String { switch self { case .calendar: return "calendar-json.googleapis.com"; case .gmail: return "gmail.googleapis.com"; case .tasks: return "tasks.googleapis.com"; case .drive: return "drive.googleapis.com" } }
    var detail: String { switch self {
    case .calendar: return "Events, invitations, Meet links and bookings already added by Google."
    case .gmail: return "Recent inbox senders, subjects and unread status. No message bodies or attachments."
    case .tasks: return "Open tasks, with due dates shown in your agenda."
    case .drive: return "Recent file names and links. File contents stay in Google."
    } }
}

enum GoogleFailure: LocalizedError, Equatable {
    case configuration, cancelled, invalidCallback, signInExpired, reconnect, permission, keychain(Int32), http(Int), malformed, pageLimit
    case apiDisabled, missingScope, organizationPolicy, rateLimited, quotaExceeded, serviceUnavailable
    var invalidatesData: Bool { [.reconnect, .permission, .apiDisabled, .missingScope, .organizationPolicy].contains(self) }
    var errorDescription: String? { switch self {
    case .apiDisabled: return "This API is disabled in the app’s Google Cloud project. Enable the service, then sync again; signing in again will not enable it."
    case .missingScope: return "Google has not granted the access this service needs. Choose Update Google access and allow this service."
    case .organizationPolicy: return "This account’s organization blocks the service. Ask its administrator to allow NeroNook, or select another account."
    case .rateLimited: return "Google is limiting requests. Wait a little before syncing again; your sign-in is still connected."
    case .quotaExceeded: return "The app’s Google API quota has been reached. Try later or check the project’s quota; reconnecting will not reset it."
    case .serviceUnavailable: return "Google is temporarily unavailable. Try syncing again later."
    case .configuration: return "Google sign-in needs its one-time app setup. Expand Developer setup below."
    case .cancelled: return "Google sign-in was cancelled."
    case .invalidCallback: return "The sign-in response could not be verified. Please try again."
    case .signInExpired: return "Sign-in timed out. Please try again."
    case .reconnect: return "Your Google connection expired or was revoked. Reconnect your account."
    case .permission: return "Google denied this request without a recognized repair reason. Check this service’s access in Google settings."
    case .keychain: return "NeroNook could not access its saved Google connection in Keychain."
    case .http(let code): return "Google could not complete the request (\(code)). Try syncing again."
    case .malformed: return "Google returned an unexpected response. Please retry."
    case .pageLimit: return "This account returned more items than can be loaded at once. Narrow your calendar selection."
    } }
}

/// Classify documented reasons; never display arbitrary response bodies or credentials.
enum GoogleResponseFailure {
    static func classify(status: Int, data: Data) -> GoogleFailure {
        if status == 401 { return .reconnect }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if root?["error"] as? String == "invalid_grant" { return .reconnect }
        let error = root?["error"] as? [String: Any]
        let legacy = error?["errors"] as? [[String: Any]] ?? []
        let details = error?["details"] as? [[String: Any]] ?? []
        let reasons = Set((legacy + details).compactMap { ($0["reason"] as? String)?.lowercased() })
        if !reasons.isDisjoint(with: ["service_disabled", "accessnotconfigured", "servicedisabled"]) { return .apiDisabled }
        if !reasons.isDisjoint(with: ["access_token_scope_insufficient", "insufficientpermissions", "insufficientauthenticationscopes"]) { return .missingScope }
        if reasons.contains("domainpolicy") { return .organizationPolicy }
        if !reasons.isDisjoint(with: ["dailylimitexceeded", "quota_exceeded", "quotaexceeded"]) { return .quotaExceeded }
        if status == 429 || !reasons.isDisjoint(with: ["ratelimitexceeded", "userratelimitexceeded", "rate_limit_exceeded"]) { return .rateLimited }
        if (500...599).contains(status) { return .serviceUnavailable }
        return status == 403 ? .permission : .http(status)
    }
}

enum GoogleOAuthProtocol {
    static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func challenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map { "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
    static func callbackCode(target: String, expectedState: String) throws -> String {
        guard let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/oauth/callback" else { throw GoogleFailure.invalidCallback }
        let fields = Dictionary(grouping: url.queryItems ?? [], by: \.name)
        guard fields["state"]?.count == 1, fields["state"]?.first?.value == expectedState else { throw GoogleFailure.invalidCallback }
        if fields["error"] != nil { throw GoogleFailure.cancelled }
        guard fields["code"]?.count == 1, let code = fields["code"]?.first?.value, !code.isEmpty else { throw GoogleFailure.invalidCallback }
        return code
    }
}

struct GoogleCredential: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var scopes: Set<String>
    var email: String
    var subject: String
    var client: GoogleClientConfiguration
}
struct GoogleTokenResponse: Decodable {
    let access_token: String
    let expires_in: Double
    let refresh_token: String?
    let scope: String?
}
struct GoogleProfile: Decodable { let sub: String; let email: String }
struct GooglePage<T: Decodable>: Decodable { let items: [T]?; let nextPageToken: String? }
struct GoogleCalendar: Decodable, Identifiable {
    let id: String
    let summary: String?
    let backgroundColor: String?
    let timeZone: String?
    let primary: Bool?
    let deleted: Bool?
    var title: String { summary ?? id }
}
struct GoogleEventTime: Decodable { let date: String?; let dateTime: String?; let timeZone: String? }
struct GoogleEvent: Decodable {
    let id: String
    let summary: String?
    let status: String?
    let iCalUID: String?
    let start: GoogleEventTime?
    let end: GoogleEventTime?
    let location: String?
    let htmlLink: String?
    let hangoutLink: String?
    let eventType: String?
    let recurringEventId: String?
    let originalStartTime: GoogleEventTime?
}
struct GoogleTaskList: Decodable { let id: String; let title: String? }
struct GoogleTask: Decodable, Identifiable { let id: String; let title: String?; let due: String?; let status: String?; let webViewLink: String?; let deleted: Bool? }
struct GoogleMessageReference: Decodable { let id: String }
struct GoogleMessageList: Decodable { let messages: [GoogleMessageReference]? }
struct GoogleMessage: Decodable, Identifiable {
    struct Header: Decodable { let name: String; let value: String }
    struct Payload: Decodable { let headers: [Header]? }
    let id: String
    let threadId: String?
    let internalDate: String?
    let labelIds: [String]?
    let payload: Payload?
    func header(_ name: String) -> String { payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? "" }
    var unread: Bool { labelIds?.contains("UNREAD") == true }
    var receivedAt: Date? { internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) } }
}
struct GoogleFile: Decodable, Identifiable { let id: String; let name: String?; let mimeType: String?; let modifiedTime: String?; let webViewLink: String? }
struct GoogleFileList: Decodable { let files: [GoogleFile]? }

struct AgendaEntry: Identifiable, Equatable {
    let id: String
    var title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let source: String
    let colorHex: String
    let location: String?
    let url: URL?
    let meetURL: URL?
    let externalID: String?
    let nativeID: String?
    let isTask: Bool
    func isMultiDay(calendar: Calendar = .current) -> Bool { end > start && !calendar.isDate(start, inSameDayAs: end.addingTimeInterval(-1)) }
}

enum GoogleDates {
    static func timestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func day(_ value: String, calendar: Calendar = .current) -> Date? {
        let parts = value.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let result = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: result) == components else { return nil }
        return result
    }
    static func eventTime(_ time: GoogleEventTime, calendar: Calendar = .current) -> Date? {
        if let date = time.date { return day(date, calendar: calendar) }
        guard let value = time.dateTime else { return nil }
        if let date = timestamp(value) { return date }
        guard let zoneName = time.timeZone, let zone = TimeZone(identifier: zoneName) else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; f.isLenient = false
        return f.date(from: value)
    }
    static func key(_ date: Date, calendar: Calendar = .current) -> String { String(calendar.startOfDay(for: date).timeIntervalSince1970) }
}

extension GoogleEvent {
    func agenda(calendar: GoogleCalendar, displayCalendar: Calendar = .current) -> AgendaEntry? {
        guard status != "cancelled", let start, let end,
              let from = GoogleDates.eventTime(start, calendar: displayCalendar),
              let to = GoogleDates.eventTime(end, calendar: displayCalendar), to >= from else { return nil }
        return AgendaEntry(id: "google:\(calendar.id):\(id):\(from.timeIntervalSince1970)", title: summary ?? "Untitled event", start: from, end: to, isAllDay: start.date != nil,
            source: eventType == "fromGmail" ? "Gmail · \(calendar.title)" : "Google · \(calendar.title)", colorHex: calendar.backgroundColor ?? "#4285F4", location: location,
            url: Self.safeURL(htmlLink), meetURL: Self.safeURL(hangoutLink), externalID: iCalUID, nativeID: nil, isTask: false)
    }
    static func safeURL(_ value: String?) -> URL? { guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }; return url }
}

enum AgendaMerge {
    static func merge(_ entries: [AgendaEntry], on date: Date, hideAllDay: Bool = false, hideMultiDay: Bool = false, calendar: Calendar = .current) -> [AgendaEntry] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        var seen = Set<String>()
        return entries.filter { event in
            guard event.start < end, event.end > start || (event.start == event.end && event.start >= start),
                  !hideAllDay || !event.isAllDay, !hideMultiDay || !event.isMultiDay(calendar: calendar) else { return false }
            let identity = event.externalID.map { "\($0)#\(event.start.timeIntervalSince1970)" } ?? event.id
            return seen.insert(identity).inserted
        }.sorted { a, b in
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.start != b.start { return a.start < b.start }
            return a.id < b.id
        }
    }
}
