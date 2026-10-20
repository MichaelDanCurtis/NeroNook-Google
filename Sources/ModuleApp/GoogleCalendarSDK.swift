import Foundation
import NookPluginSDK

extension GoogleEvent {
    func sdkEvent(calendar: GoogleCalendar) throws -> PluginCalendarEvent {
        guard status != "cancelled", let start, let end, let from = GoogleDates.eventTime(start), let to = GoogleDates.eventTime(end) else { throw GoogleFailure.malformed }
        let occurrence: String
        if recurringEventId != nil {
            guard let originalStartTime else { throw GoogleFailure.malformed }
            if let day = originalStartTime.date { occurrence = "day:" + day }
            else { guard let date = GoogleDates.eventTime(originalStartTime) else { throw GoogleFailure.malformed }; occurrence = String(date.timeIntervalSince1970) }
        }
        else { occurrence = "single" }
        let value = PluginCalendarEvent(reference: .init(calendar: calendar.id, event: id, occurrence: occurrence),
            title: PluginCalendarContract.bounded(summary?.isEmpty == false ? summary! : "Untitled event", bytes: 180),
            calendarName: PluginCalendarContract.bounded(calendar.title, bytes: 120), start: from, end: to, allDay: start.date != nil,
            url: htmlLink.flatMap { URL(string: $0) }.flatMap { PluginCalendarContract.safeURL($0) ? $0 : nil },
            meetingURL: hangoutLink.flatMap { URL(string: $0) }.flatMap { PluginCalendarContract.safeURL($0) ? $0 : nil })
        try value.validate(); return value
    }
}
