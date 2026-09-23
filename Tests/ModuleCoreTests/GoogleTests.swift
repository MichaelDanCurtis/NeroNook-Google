import XCTest
import NookPluginSDK
@testable import ModuleApp

final class GoogleTests: XCTestCase {
    @MainActor func testDisconnectedProductionCollectionsHaveValidDateActions() throws {
        let date = try XCTUnwrap(GoogleDates.day("2026-09-23"))
        let presentation = GoogleCollections.build(store: .shared, selectedDay: date)
        let snapshot = PluginSnapshot(title: "Google", status: "Disconnected", panels: presentation.panels)
        try snapshot.validate()
        XCTAssertEqual(presentation.panels.compactMap { $0.collection?.layout }, [.calendar, .inbox, .tasks, .files])
        for day in try XCTUnwrap(presentation.panels.first?.collection?.days) {
            XCTAssertEqual(presentation.dates[day.action.id], day.date)
            XCTAssertNotNil(snapshot.enabledDisplayAction(day.action.id))
        }
    }

    func testMonthGridUsesLocalDaysAcrossDSTAndMonthBoundaries() throws {
        for value in ["2024-02-29", "2024-03-10", "2024-11-03", "2026-12-31"] {
            let selected = try XCTUnwrap(GoogleDates.day(value, calendar: pacific))
            let days = GoogleCollectionDates.days(containing: selected, calendar: pacific)
            XCTAssertEqual(days.count, 42)
            XCTAssertEqual(Set(days).count, 42)
            XCTAssertEqual(pacific.component(.weekday, from: days[0]), pacific.firstWeekday)
            XCTAssertTrue(days.contains { pacific.isDate($0, inSameDayAs: selected) })
            for pair in zip(days, days.dropFirst()) {
                XCTAssertEqual(pacific.dateComponents([.day], from: pair.0, to: pair.1).day, 1)
                XCTAssertEqual(pacific.component(.hour, from: pair.1), 0)
            }
        }
    }
    func testGoogleFailuresDistinguishRepairPathsWithoutLeakingResponseText() throws {
        func failure(_ reason: String, status: Int = 403, modern: Bool = false) -> GoogleFailure {
            let body: [String: Any] = ["error": ["message": "private-token-never-display", modern ? "details" : "errors": [["reason": reason]]]]
            return GoogleResponseFailure.classify(status: status, data: try! JSONSerialization.data(withJSONObject: body))
        }
        XCTAssertEqual(failure("accessNotConfigured"), .apiDisabled)
        XCTAssertEqual(failure("SERVICE_DISABLED", modern: true), .apiDisabled)
        XCTAssertEqual(failure("insufficientPermissions"), .missingScope)
        XCTAssertEqual(failure("ACCESS_TOKEN_SCOPE_INSUFFICIENT", modern: true), .missingScope)
        XCTAssertEqual(failure("domainPolicy"), .organizationPolicy)
        XCTAssertEqual(failure("dailyLimitExceeded"), .quotaExceeded)
        XCTAssertEqual(failure("userRateLimitExceeded"), .rateLimited)
        XCTAssertEqual(failure("unknown", status: 429), .rateLimited)
        XCTAssertEqual(failure("unknown", status: 503), .serviceUnavailable)
        XCTAssertEqual(failure("unknown"), .permission)
        XCTAssertFalse(failure("unknown").localizedDescription.contains("private-token"))
        XCTAssertEqual(GoogleResponseFailure.classify(status: 401, data: Data()), .reconnect)
        XCTAssertEqual(GoogleResponseFailure.classify(status: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8)), .reconnect)
        XCTAssertEqual(GoogleResponseFailure.classify(status: 403, data: Data("not json".utf8)), .permission)
        XCTAssertTrue(GoogleFailure.missingScope.invalidatesData)
        XCTAssertFalse(GoogleFailure.rateLimited.invalidatesData)
    }
    func testEmptyGoogleItemTitleRemainsAValidDisplayCard() throws {
        for title in ["", "   ", "\n", String(repeating: "文", count: 200)] {
            let snapshot = PluginSnapshot(title: "Google", status: "Connected", panels: [.init("tasks", "Tasks", cards: [.init("task_0", title: GoogleCardText.title(title))])])
            try snapshot.validate()
        }
    }
    private var pacific: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    func testPKCEKnownVectorAndFormEncoding() {
        XCTAssertEqual(GoogleOAuthProtocol.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(String(data: GoogleOAuthProtocol.form(["code": "x+y&z=1 /?"]), encoding: .utf8), "code=x%2By%26z%3D1%20%2F%3F")
    }
    func testOAuthRejectsMissingWrongDuplicateStateAndForeignPaths() throws {
        XCTAssertEqual(try GoogleOAuthProtocol.callbackCode(target: "/oauth/callback?code=good%2Bcode&state=expected", expectedState: "expected"), "good+code")
        for target in ["/oauth/callback?code=x", "/oauth/callback?code=x&state=wrong", "/oauth/callback?code=x&state=expected&state=expected", "/oauth/callback?code=x&code=y&state=expected", "/favicon.ico?code=x&state=expected"] {
            XCTAssertThrowsError(try GoogleOAuthProtocol.callbackCode(target: target, expectedState: "expected"))
        }
        XCTAssertThrowsError(try GoogleOAuthProtocol.callbackCode(target: "/oauth/callback?error=access_denied&state=expected", expectedState: "expected")) { XCTAssertEqual($0 as? GoogleFailure, .cancelled) }
    }
    func testCalendarAllDayDSTAndExclusiveEnd() throws {
        let data = Data(#"{"id":"trip","summary":"Trip","start":{"date":"2026-03-08"},"end":{"date":"2026-03-09"},"iCalUID":"trip@example.com","eventType":"fromGmail"}"#.utf8)
        let event = try JSONDecoder().decode(GoogleEvent.self, from: data)
        let calendar = try JSONDecoder().decode(GoogleCalendar.self, from: Data(#"{"id":"primary","summary":"Personal"}"#.utf8))
        let entry = try XCTUnwrap(event.agenda(calendar: calendar, displayCalendar: pacific))
        XCTAssertEqual(entry.end.timeIntervalSince(entry.start), 23 * 3600)
        XCTAssertFalse(entry.isMultiDay(calendar: pacific))
        XCTAssertEqual(entry.source, "Gmail · Personal")
        XCTAssertEqual(AgendaMerge.merge([entry], on: entry.start, calendar: pacific).count, 1)
        XCTAssertTrue(AgendaMerge.merge([entry], on: entry.end, calendar: pacific).isEmpty)
        XCTAssertNil(GoogleDates.day("2026-02-31", calendar: pacific))
    }
    func testRecurringOccurrencesAreNotCollapsedButDualSourceCopyIs() throws {
        let calendar = try JSONDecoder().decode(GoogleCalendar.self, from: Data(#"{"id":"primary"}"#.utf8))
        func event(_ hour: Int) throws -> AgendaEntry {
            let json = "{\"id\":\"occurrence\(hour)\",\"iCalUID\":\"recurring\",\"summary\":\"Meeting\",\"start\":{\"dateTime\":\"2026-09-20T\(hour):00:00-07:00\"},\"end\":{\"dateTime\":\"2026-09-20T\(hour):30:00-07:00\"}}"
            return try XCTUnwrap(JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8)).agenda(calendar: calendar))
        }
        let one = try event(10), two = try event(14)
        let copy = AgendaEntry(id: "mac-copy", title: one.title, start: one.start, end: one.end, isAllDay: false, source: "Mac", colorHex: "#fff", location: nil, url: nil, meetURL: nil, externalID: one.externalID, nativeID: "native", isTask: false)
        let merged = AgendaMerge.merge([one, copy, two], on: one.start, calendar: pacific)
        XCTAssertEqual(merged.map(\.id), [one.id, two.id])
    }
    func testCancelledGoogleEventsAndUnsafeLinksAreExcluded() throws {
        let event = try JSONDecoder().decode(GoogleEvent.self, from: Data(#"{"id":"gone","status":"cancelled"}"#.utf8))
        let calendar = try JSONDecoder().decode(GoogleCalendar.self, from: Data(#"{"id":"primary"}"#.utf8))
        XCTAssertNil(event.agenda(calendar: calendar))
        XCTAssertNil(GoogleEvent.safeURL("javascript:alert(1)"))
        XCTAssertNil(GoogleEvent.safeURL("file:///etc/passwd"))
        XCTAssertNotNil(GoogleEvent.safeURL("https://calendar.google.com/"))
    }
    @MainActor func testLoopbackCallbackRoundTrip() async throws {
        let listener = GoogleLoopback(state: "test-state")
        let redirect = try await listener.start()
        XCTAssertEqual(redirect.host, "127.0.0.1")
        var components = URLComponents(url: redirect, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "code", value: "test-code"), .init(name: "state", value: "test-state")]
        var wrong = components
        wrong.queryItems = [.init(name: "code", value: "bad"), .init(name: "state", value: "wrong")]
        let (_, rejection) = try await URLSession.shared.data(from: wrong.url!)
        XCTAssertEqual((rejection as? HTTPURLResponse)?.statusCode, 400)
        let (body, response) = try await URLSession.shared.data(from: components.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("test-code"))
        let code = try await listener.waitForCode()
        XCTAssertEqual(code, "test-code")
        listener.cancel()
    }
    @MainActor func testLoopbackCancellationDoesNotHang() async throws {
        let listener = GoogleLoopback(state: "test-state")
        _ = try await listener.start()
        listener.cancel()
        do { _ = try await listener.waitForCode(); XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? GoogleFailure, .cancelled) }
    }
    func testAPIReadsEveryCalendarPageWithoutSendingTokenInURL() async throws {
        let recorder = GoogleRequestRecorder()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GoogleStubProtocol.self]
        GoogleStubProtocol.recorder = recorder
        let credential = GoogleCredential(accessToken: "fixture-access", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600), scopes: [.init(GoogleService.calendar.scope)], email: "fixture@example.test", subject: "fixture", client: .init(clientID: "fixture.apps.googleusercontent.com", clientSecret: nil))
        let api = GoogleAPI(credential: credential, http: GoogleHTTP(configuration: config), save: { _ in XCTFail("A valid fixture token should not refresh") })
        let calendars = try await api.calendars()
        XCTAssertEqual(calendars.map(\.id), ["first", "second"])
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
        XCTAssertTrue(requests.allSatisfy { !$0.url!.absoluteString.contains("fixture-access") })
        XCTAssertTrue(requests[1].url!.absoluteString.contains("pageToken=page2"))
        await api.invalidate()
        do { _ = try await api.calendars(); XCTFail("Disconnected clients must not send requests") } catch {}
        XCTAssertEqual(recorder.snapshot().count, 2)
    }
    func testExpiredTokenRefreshAndCredentialPersistence() async throws {
        let recorder = GoogleRequestRecorder()
        GoogleStubProtocol.recorder = recorder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleStubProtocol.self]
        let credential = GoogleCredential(accessToken: "expired", refreshToken: "fixture-refresh", expiresAt: .distantPast, scopes: [GoogleService.calendar.scope], email: "fixture@example.test", subject: "fixture", client: .init(clientID: "fixture.apps.googleusercontent.com", clientSecret: nil))
        let api = GoogleAPI(credential: credential, http: GoogleHTTP(configuration: configuration), save: { value in recorder.saved(value) })
        _ = try await api.calendars()
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.first?.url?.host, "oauth2.googleapis.com")
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(requests.dropFirst().first?.value(forHTTPHeaderField: "Authorization"), "Bearer renewed-fixture")
        XCTAssertEqual(recorder.savedTokens().first?.refreshToken, "fixture-refresh")
        XCTAssertEqual(recorder.savedTokens().first?.accessToken, "renewed-fixture")
        await api.invalidate()
    }

}
private final class GoogleRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var credentials: [GoogleCredential] = []
    func saved(_ value: GoogleCredential) { lock.lock(); defer { lock.unlock() }; credentials.append(value) }
    func savedTokens() -> [GoogleCredential] { lock.lock(); defer { lock.unlock() }; return credentials }
    func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; requests.append(request) }
    func snapshot() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}
private final class GoogleStubProtocol: URLProtocol, @unchecked Sendable {
    static var recorder = GoogleRequestRecorder()
    override class func canInit(with request: URLRequest) -> Bool { ["www.googleapis.com", "oauth2.googleapis.com"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.recorder.record(request)
        let second = request.url!.absoluteString.contains("pageToken=page2")
        let body = request.url?.host == "oauth2.googleapis.com" ? #"{"access_token":"renewed-fixture","expires_in":3600}"# : second ? #"{"items":[{"id":"second"}]}"# : #"{"items":[{"id":"first"}],"nextPageToken":"page2"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
