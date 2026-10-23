import AppKit
import SwiftUI
import Combine
import CryptoKit
import NookPluginSDK

enum GoogleCardText {
    static func title(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled item" : String(trimmed.prefix(80))
    }
}

@MainActor final class GooglePlugin: ObservableObject {
    let store = GoogleWorkspaceStore.shared
    @Published var settingsVisible = false
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var input = PluginLines()
    private var timer: Timer?
    private var observations = Set<AnyCancellable>()
    private var agendaEnabled = false
    private var collectionsEnabled = false
    private var dateActions: [String: Date] = [:]
    private var selectedDay = Calendar.current.startOfDay(for: Date())
    private var links: [String: URL] = [:]
    private var activity: NSObjectProtocol?
    private var started = false
    private var calendarReads: [UUID: Task<Void, Never>] = [:]
    private var seenReads = Set<UUID>()
    let hosted = CommandLine.arguments.contains("--neronook-plugin")
    let id = "cafe.nero.plugin.google"
    init() {
        if hosted {
            NSApplication.shared.setActivationPolicy(.accessory)
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Serve Google module updates")
            FileHandle.standardInput.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                Task { @MainActor in
                    guard let self else { return }
                    guard !data.isEmpty else { for task in self.calendarReads.values { task.cancel() }; self.store.stop(); exit(0) }
                    do { for message in try self.input.append(data) { self.receive(message) } } catch { exit(1) }
                }
            }
        } else { start() }
        store.objectWillChange.sink { [weak self] _ in Task { @MainActor in self?.publish() } }.store(in: &observations)
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.publish() } }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func start() { guard !started else { return }; started = true; if !CommandLine.arguments.contains("--protocol-test") { store.start() } }
    func configure() {
        settingsVisible = true; NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
    }
    private func receive(_ message: PluginMessage) {
        guard message.pluginID == id else { exit(1) }
        if session == nil {
            guard message.type == "hello" else { exit(1) }
            session = message.session; PluginAppearanceStore.shared.beginSession(pluginID:id,session:message.session); agendaEnabled = message.features?.contains("agenda-v1") == true
            collectionsEnabled = message.features?.contains("collections-v1") == true
            emit(.init(type: "ready", pluginID: id, session: message.session, features: ["appearance-v1", "dashboard-v1", "panels-v1", "control-cards-v1", "agenda-v1", "collections-v1", "actions-v1"]))
            if message.features?.contains("actions-v1") == true {
                var list = PluginCalendarContract.list, read = PluginCalendarContract.read
                list.title = "Read Google Calendar events for a selected day"; read.title = "Verify a linked Google Calendar event"
                emit(.init(type: "bus", pluginID: id, session: message.session, bus: .init(.register, registration: .init(actions: [list, read, PluginMailReplyContract.read, PluginMailReplyContract.review]))))
            }
            start(); publish(); return
        }
        guard message.session == session else { exit(1) }; if message.type == "appearance" { _ = PluginAppearanceStore.shared.receive(message); return }
        if let bus = message.bus {
            if bus.operation == .cancel { calendarReads[bus.requestID]?.cancel(); return }
            if bus.operation == .execute {
                guard !seenReads.contains(bus.requestID), seenReads.count < 4096, calendarReads.count < 4,
                      bus.address?.plugin == id, [PluginCalendarContract.list.id, PluginCalendarContract.read.id, PluginMailReplyContract.read.id, PluginMailReplyContract.review.id].contains(bus.address?.name ?? ""), let values = bus.values else { return }
                seenReads.insert(bus.requestID)
                calendarReads[bus.requestID] = Task { [weak self] in
                    guard let self else { return }; defer { self.calendarReads[bus.requestID] = nil }
                    do {
                        guard !CommandLine.arguments.contains("--protocol-test") else { throw GoogleFailure.permission }
                        let mail = [PluginMailReplyContract.read.id, PluginMailReplyContract.review.id].contains(bus.address!.name)
                        let result = try await mail ? self.store.mailReplyAction(bus.address!.name, values: values) : self.store.calendarRead(bus.address!.name, values: values)
                        if bus.address!.name == PluginMailReplyContract.review.id { GoogleReplyWindows.show() }
                        self.emit(.init(type: "bus", pluginID: self.id, session: message.session, bus: .init(.update, requestID: bus.requestID, update: .init(.succeeded, message: "Google action completed", values: result))))
                    } catch { self.emit(.init(type: "bus", pluginID: self.id, session: message.session, bus: .init(.update, requestID: bus.requestID, update: .init(error is CancellationError ? .cancelled : .failed, message: String(error.localizedDescription.prefix(240)))))) }
                }; return
            }
        }
        if message.type == "agendaRequest", let date = message.agendaDate, date.timeIntervalSince1970.isFinite {
            selectedDay = Calendar.current.startOfDay(for: date); store.showDate(selectedDay); publishAgenda()
        }
        if message.type == "action", let action = message.action {
            if action == "configure" { configure() }
            else if action == "refresh" { store.sync() }
            else if action == "reply_setup" { GoogleReplyWindows.show() }
            else if let date = dateActions[action] { selectedDay = date; store.showDate(date); publish() }
            else if let url = links[action], url.scheme == "https", url.user == nil, url.password == nil { NSWorkspace.shared.open(url) }
        }
    }
    private func publish() {
        guard let session else { return }
        links = [:]
        func card(_ key: String, title: String, subtitle: String, value: String = "", url: URL? = nil) -> PluginControlCard {
            let action = "open_" + SHA256.hash(data: Data((url?.absoluteString ?? key).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            if let url { links[action] = url }
            return .init(key, title: GoogleCardText.title(title), subtitle: String(subtitle.prefix(100)), value: String(value.prefix(100)), actions: url == nil ? [] : [.init(action, "Open", symbol: "arrow.up.right")])
        }
        func empty(_ service: GoogleService) -> [PluginControlCard] {
            [.init("empty_" + service.rawValue, title: store.errors[service] != nil ? service.title + " needs attention" : store.enabled(service) ? "No items" : "Enable " + service.title, detail: store.errors[service] ?? (store.connected ? "Choose services in Settings." : "Sign in using the gear button."), symbol: "globe")]
        }
        let inbox = Array(store.messages.prefix(20).enumerated()).map { index, m in
            var url = URLComponents(string: "https://mail.google.com/mail/u/")!
            url.queryItems = [.init(name: "authuser", value: store.email ?? "")]; url.fragment = "inbox/" + (m.threadId ?? m.id)
            return card("mail_\(index)", title: m.header("Subject").isEmpty ? "(No subject)" : m.header("Subject"), subtitle: m.header("From"), value: m.unread ? "Unread" : "Read", url: url.url)
        }
        let tasks = Array(store.tasks.prefix(30).enumerated()).map { i, t in card("task_\(i)", title: t.title ?? "Untitled task", subtitle: t.due.flatMap(GoogleDates.timestamp).map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "No due date", url: GoogleEvent.safeURL(t.webViewLink) ?? URL(string: "https://tasks.google.com/")) }
        let files = Array(store.files.prefix(30).enumerated()).map { i, f in card("file_\(i)", title: f.name ?? "Untitled file", subtitle: f.mimeType ?? "Drive file", url: GoogleEvent.safeURL(f.webViewLink)) }
        let events = Array(AgendaMerge.merge(store.agenda(on: selectedDay), on: selectedDay).prefix(30).enumerated()).map { i, e in card("event_\(i)", title: e.title, subtitle: e.source, value: e.isAllDay ? "All day" : e.start.formatted(date: .omitted, time: .shortened), url: e.url) }
        let status = store.accountError ?? (!store.syncing.isEmpty ? "Syncing Google…" : store.email ?? "Connect your Google account")
        var snapshot = PluginSnapshot(title: "Google", status: String(status.prefix(500)), activity: String(status.prefix(100)), actions: [.init("refresh", "Refresh", enabled: store.connected && store.syncing.isEmpty, symbol: "arrow.clockwise", placement: .menu)], panels: [
            .init("calendar", "Calendar", cards: events.isEmpty ? empty(.calendar) : events),
            .init("inbox", "Inbox", cards: inbox.isEmpty ? empty(.gmail) : inbox),
            .init("tasks", "Tasks", cards: tasks.isEmpty ? empty(.tasks) : tasks),
            .init("files", "Files", cards: files.isEmpty ? empty(.drive) : files)
        ])
        dateActions = [:]
        if collectionsEnabled {
            let presentation = GoogleCollections.build(store: store, selectedDay: selectedDay)
            snapshot.panels = presentation.panels; snapshot.actions = []
            links = presentation.links; dateActions = presentation.dates
        }
        do { try snapshot.validate() }
        catch {
            // A malformed remote item must not silence the plugin heartbeat.
            links = [:]
            let fallback = PluginSnapshot(title: "Google", status: "Some Google items could not be displayed. Open Google settings or refresh.", activity: "Google display needs attention", actions: [.init("refresh", "Refresh", enabled: store.connected, placement: .menu)], panels: snapshot.panels?.map { .init($0.id, $0.title, cards: [.init("display_error", title: "Unable to display these items", detail: "The account is still connected. Try refreshing or open Google settings.")]) })
            emit(.init(type: "snapshot", pluginID: id, session: session, snapshot: fallback)); publishAgenda(); return
        }
        emit(.init(type: "snapshot", pluginID: id, session: session, snapshot: snapshot)); publishAgenda()
    }
    private func publishAgenda() {
        guard agendaEnabled, let session else { return }
        for day in Set([selectedDay, Calendar.current.startOfDay(for: Date())]) {
            let relevant = [GoogleService.calendar, .tasks].filter { store.enabled($0) }
            let dates = relevant.compactMap { store.lastSynced[$0] }
            let fetched = dates.min() ?? Date()
            let entries: [PluginAgendaEntry] = relevant.allSatisfy({ store.errors[$0] == nil && store.lastSynced[$0] != nil }) ? AgendaMerge.merge(store.agenda(on: day), on: day).prefix(64).compactMap { e in
                let entry = PluginAgendaEntry(id: String(e.id.prefix(512)), title: String(e.title.prefix(300)), start: e.start, end: e.end, allDay: e.isAllDay, source: String(e.source.prefix(100)), color: e.colorHex, location: e.location.map { String($0.prefix(300)) }, url: e.url, meetingURL: e.meetURL, externalID: e.externalID, isTask: e.isTask)
                return (try? entry.validate()) != nil ? entry : nil
            } : []
            emit(.init(type: "agenda", pluginID: id, session: session, agenda: .init(date: day, fetchedAt: fetched, expiresAt: fetched.addingTimeInterval(600), entries: entries)))
        }
    }
    private func emit(_ message: PluginMessage) {
        var message = message
        if message.type != "ready" { sequence += 1 }; message.sequence = sequence
        do { try FileHandle.standardOutput.write(contentsOf: message.encoded()) } catch { store.stop(); exit(0) }
    }
}

@main struct GoogleModuleApp: App {
    @StateObject private var plugin: GooglePlugin
    init() { let model = GooglePlugin(); _plugin = StateObject(wrappedValue: model) }
    var body: some Scene {
        WindowGroup {
            GoogleWorkspaceView().pluginThemed().padding(18).frame(width: 720, height: 405)
                .sheet(isPresented: $plugin.settingsVisible) {
                    GoogleSettingsView(done: { plugin.settingsVisible = false })
                }
                .onAppear { if plugin.hosted { NSApp.windows.first { $0.canBecomeKey }?.orderOut(nil) } }
        }.windowResizability(.contentSize)
    }
}
