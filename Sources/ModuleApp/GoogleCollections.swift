import Foundation
import CryptoKit
import NookPluginSDK

enum GoogleCollectionDates {
    static func days(containing date: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: date)?.start else { return [] }
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: month) }
    }
}

struct GoogleCollectionPresentation {
    var panels: [PluginPanel]
    var links: [String: URL]
    var dates: [String: Date]
}

@MainActor enum GoogleCollections {
    static func build(store: GoogleWorkspaceStore, selectedDay: Date) -> GoogleCollectionPresentation {
        var links: [String: URL] = [:]
        var dates: [String: Date] = [:]
        func open(_ url: URL?, _ label: String) -> PluginAction? {
            guard let url else { return nil }
            let key = "open_" + SHA256.hash(data: Data((url.absoluteString + "|" + label).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            links[key] = url
            return .init(key, label, symbol: "arrow.up.right")
        }
        func text(_ text: String?, fallback: String) -> String {
            let value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? fallback : String(value.prefix(160))
        }
        func status(_ service: GoogleService, scope: String) -> String {
            if let error = store.errors[service] { return String(error.prefix(300)) }
            if store.syncing.contains(service) { return "Syncing…" }
            return scope + (store.lastSynced[service].map { " · Updated " + $0.formatted(date: .omitted, time: .shortened) } ?? "")
        }
        func empty(_ service: GoogleService, normal: String) -> String {
            if let error = store.errors[service] { return String(error.prefix(500)) }
            if !store.connected { return "Sign in with Google using the settings button." }
            if !store.enabled(service) { return "Enable \(service.title) in Google settings." }
            return store.syncing.contains(service) ? "Loading…" : normal
        }
        func itemID(_ prefix: String, _ remote: String) -> String { prefix + "_" + SHA256.hash(data: Data(remote.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
        let inbox = store.messages.prefix(20).enumerated().map { index, message in
            var url = URLComponents(string: "https://mail.google.com/mail/u/")!
            url.queryItems = [.init(name: "authuser", value: store.email ?? "")]; url.fragment = "inbox/" + (message.threadId ?? message.id)
            let from = message.header("From")
            let sender = from.components(separatedBy: "<").first?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            return PluginCollectionItem(itemID("mail", message.id), title: text(message.header("Subject"), fallback: "(No subject)"), subtitle: text(sender, fallback: from), detail: String(from.prefix(500)), date: message.receivedAt, unread: message.unread, action: open(url.url, "Open in Gmail"))
        }
        let tasks = store.tasks.prefix(30).enumerated().map { index, task in
            PluginCollectionItem(itemID("task", task.id), title: text(task.title, fallback: "Untitled task"), subtitle: "Google Tasks", date: task.due.flatMap { GoogleDates.day($0) }, completed: task.status == "completed", action: open(GoogleEvent.safeURL(task.webViewLink) ?? URL(string: "https://tasks.google.com/"), "Open to edit"))
        }
        let files = store.files.prefix(30).enumerated().map { index, file in
            let kind = fileKind(file.mimeType)
            return PluginCollectionItem(itemID("file", file.id), title: text(file.name, fallback: "Untitled file"), category: kind.title, symbol: kind.symbol, date: file.modifiedTime.flatMap(GoogleDates.timestamp), action: open(GoogleEvent.safeURL(file.webViewLink), "Open file"))
        }
        func dateAction(_ date: Date, key: String? = nil, label: String? = nil, symbol: String? = nil) -> PluginAction {
            let id = key ?? itemID("day", GoogleDates.key(date))
            dates[id] = date
            return .init(id, label ?? date.formatted(date: .complete, time: .omitted), symbol: symbol)
        }
        let days = GoogleCollectionDates.days(containing: selectedDay).map { PluginCalendarDay(date: $0, action: dateAction($0)) }
        let month = Calendar.current.dateInterval(of: .month, for: selectedDay)!.start
        let refresh = PluginAction("refresh", "Refresh", enabled: store.connected && store.syncing.isEmpty, symbol: "arrow.clockwise")
        let navigation = [
            dateAction(Calendar.current.date(byAdding: .month, value: -1, to: month)!, key: "previous_month", label: "Previous month", symbol: "chevron.left"),
            dateAction(Calendar.current.startOfDay(for: Date()), key: "today", label: "Today"),
            dateAction(Calendar.current.date(byAdding: .month, value: 1, to: month)!, key: "next_month", label: "Next month", symbol: "chevron.right"), refresh
        ]
        let events = AgendaMerge.merge(store.agenda(on: selectedDay), on: selectedDay).prefix(30).enumerated().map { index, event in
            PluginCollectionItem(itemID("event", event.id), title: text(event.title, fallback: "Untitled event"), subtitle: String(event.source.prefix(200)), category: event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened) + " – " + event.end.formatted(date: .omitted, time: .shortened), date: event.start, action: open(event.url, "Open event"))
        }
        return .init(panels: [
            .init("calendar", "Calendar", collection: .init(.calendar, title: "Calendar", subtitle: status(.calendar, scope: "Selected day"), emptyText: empty(.calendar, normal: "No events on this day"), items: Array(events), selectedDate: selectedDay, days: days, actions: navigation)),
            .init("inbox", "Inbox", collection: .init(.inbox, title: "Inbox", subtitle: status(.gmail, scope: "Latest 20 · Headers only"), emptyText: empty(.gmail, normal: "Your inbox is clear"), items: Array(inbox), actions: [.init("reply_setup", "Nero Flow reply…", symbol: "arrow.triangle.branch"), refresh])),
            .init("tasks", "Tasks", collection: .init(.tasks, title: "Tasks", subtitle: status(.tasks, scope: "Read-only · Open a task to edit"), emptyText: empty(.tasks, normal: "No open tasks"), items: Array(tasks), actions: [refresh])),
            .init("files", "Files", collection: .init(.files, title: "Files", subtitle: status(.drive, scope: "Recent files in Drive"), emptyText: empty(.drive, normal: "No recent files"), items: Array(files), actions: [refresh]))
        ], links: links, dates: dates)
    }
    static func fileKind(_ mime: String?) -> (title: String, symbol: String) {
        switch mime {
        case "application/vnd.google-apps.folder": return ("Folder", "folder.fill")
        case "application/vnd.google-apps.document": return ("Document", "doc.text.fill")
        case "application/vnd.google-apps.spreadsheet": return ("Spreadsheet", "tablecells")
        case "application/vnd.google-apps.presentation": return ("Presentation", "rectangle.on.rectangle")
        case "application/pdf": return ("PDF", "doc.richtext")
        default:
            if mime?.hasPrefix("image/") == true { return ("Image", "photo") }
            if mime?.hasPrefix("video/") == true { return ("Video", "film") }
            return ("File", "doc")
        }
    }
}
