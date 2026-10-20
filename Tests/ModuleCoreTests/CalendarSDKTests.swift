import XCTest
import NookPluginSDK
@testable import ModuleApp

final class CalendarSDKTests: XCTestCase {
    func testRecurringOccurrenceUsesOriginalTimeAfterReschedule() throws {
        let data = Data(#"{"id":"master_20261013T170000Z","summary":"Review","recurringEventId":"master","originalStartTime":{"dateTime":"2026-10-13T17:00:00Z"},"start":{"dateTime":"2026-10-14T19:00:00Z"},"end":{"dateTime":"2026-10-14T20:00:00Z"}}"#.utf8)
        let calendar = try JSONDecoder().decode(GoogleCalendar.self, from: Data(#"{"id":"calendar-one","summary":"Work"}"#.utf8))
        let event = try JSONDecoder().decode(GoogleEvent.self, from: data).sdkEvent(calendar: calendar)
        XCTAssertEqual(event.reference.event, "master_20261013T170000Z")
        XCTAssertEqual(Double(event.reference.occurrence), GoogleDates.timestamp("2026-10-13T17:00:00Z")?.timeIntervalSince1970)
        XCTAssertEqual(event.start, GoogleDates.timestamp("2026-10-14T19:00:00Z")?.timeIntervalSince1970)
    }
    func testAllDayIdentityIsTimezoneIndependentAndUnsafeURLsAreNotExported() throws {
        let calendar = try JSONDecoder().decode(GoogleCalendar.self, from: Data(#"{"id":"calendar","summary":"Work"}"#.utf8))
        let event = try JSONDecoder().decode(GoogleEvent.self, from: Data(#"{"id":"repeat-day","recurringEventId":"master","originalStartTime":{"date":"2026-10-13"},"start":{"date":"2026-10-13"},"end":{"date":"2026-10-14"},"htmlLink":"file:///private/secret","hangoutLink":"https://user:password@example.com"}"#.utf8)).sdkEvent(calendar: calendar)
        XCTAssertEqual(event.reference.occurrence, "day:2026-10-13"); XCTAssertTrue(event.allDay)
        XCTAssertNil(event.url); XCTAssertNil(event.meetingURL)
    }
}
