import AppKit
import SwiftUI
import Combine
import CryptoKit
import NookPluginSDK

@MainActor final class GooglePlugin: ObservableObject {
    let store = GoogleWorkspaceStore.shared
    @Published var settingsVisible = false
    private var session: UUID?
    private var sequence: UInt64 = 0
    private var input = PluginLines()
    private var timer: Timer?
    private var observations = Set<AnyCancellable>()
    private var agendaEnabled = false
    private var selectedDay = Calendar.current.startOfDay(for: Date())
    private var links: [String: URL] = [:]
    private var activity: NSObjectProtocol?
    private var started = false
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
                    guard !data.isEmpty else { self.store.stop(); exit(0) }
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
            session = message.session; agendaEnabled = message.features?.contains("agenda-v1") == true
            emit(.init(type: "ready", pluginID: id, session: message.session, features: ["dashboard-v1", "panels-v1", "control-cards-v1", "agenda-v1"]))
            start(); publish(); return
        }
        guard message.session == session else { exit(1) }
        if message.type == "agendaRequest", let date = message.agendaDate, date.timeIntervalSince1970.isFinite {
            selectedDay = Calendar.current.startOfDay(for: date); store.showDate(selectedDay); publishAgenda()
        }
        if message.type == "action", let action = message.action {
            if action == "configure" { configure() }
            else if action == "refresh" { store.sync() }
            else if let url = links[action], url.scheme == "https", url.user == nil, url.password == nil { NSWorkspace.shared.open(url) }
        }
    }
    private func publish() {
        guard let session else { return }
        links = [:]
        func card(_ key: String, title: String, subtitle: String, value: String = "", url: URL? = nil) -> PluginControlCard {
            let action = "open_" + SHA256.hash(data: Data((url?.absoluteString ?? key).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            if let url { links[action] = url }
            return .init(key, title: String(title.prefix(80)), subtitle: String(subtitle.prefix(100)), value: String(value.prefix(100)), actions: url == nil ? [] : [.init(action, "Open", symbol: "arrow.up.right")])
        }
        func empty(_ service: GoogleService) -> [PluginControlCard] {
            [.init("empty_" + service.rawValue, title: store.enabled(service) ? "No items" : "Enable " + service.title, detail: store.errors[service] ?? (store.connected ? "Choose services in Settings." : "Sign in using the gear button."), symbol: "globe")]
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
        let snapshot = PluginSnapshot(title: "Google Workspace", status: String(status.prefix(500)), activity: String(status.prefix(100)), actions: [.init("refresh", "Refresh", enabled: store.connected && store.syncing.isEmpty, symbol: "arrow.clockwise")], panels: [
            .init("calendar", "Calendar", cards: events.isEmpty ? empty(.calendar) : events),
            .init("inbox", "Inbox", cards: inbox.isEmpty ? empty(.gmail) : inbox),
            .init("tasks", "Tasks", cards: tasks.isEmpty ? empty(.tasks) : tasks),
            .init("files", "Files", cards: files.isEmpty ? empty(.drive) : files)
        ])
        guard (try? snapshot.validate()) != nil else { return }
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
            GoogleWorkspaceView().padding(18).frame(width: 720, height: 405).preferredColorScheme(.dark)
                .sheet(isPresented: $plugin.settingsVisible) {
                    VStack { HStack { Text("Google Workspace Settings").font(.headline); Spacer(); Button("Done") { plugin.settingsVisible = false } }.padding(); GoogleSettingsView() }.frame(width: 580, height: 650)
                }
                .onAppear { if plugin.hosted { NSApp.windows.first { $0.canBecomeKey }?.orderOut(nil) } }
        }.windowResizability(.contentSize)
    }
}
