import AppKit
import Combine
import SwiftUI

@MainActor
final class GoogleWorkspaceStore: ObservableObject {
    static let shared = GoogleWorkspaceStore()
    @Published private(set) var email: String?
    @Published private(set) var grantedScopes = Set<String>()
    @Published private(set) var isConnecting = false
    @Published private(set) var syncing = Set<GoogleService>()
    @Published private(set) var failures: [GoogleService: GoogleFailure] = [:]
    @Published private(set) var errors: [GoogleService: String] = [:]
    @Published private(set) var accountError: String?
    @Published private(set) var lastSynced: [GoogleService: Date] = [:]
    @Published private(set) var calendars: [GoogleCalendar] = []
    @Published private(set) var calendarEntries: [String: [AgendaEntry]] = [:]
    @Published private(set) var messages: [GoogleMessage] = []
    @Published private(set) var tasks: [GoogleTask] = []
    @Published private(set) var files: [GoogleFile] = []
    @Published private(set) var client: GoogleClientConfiguration?
    @Published var requestedServices: Set<GoogleService> = [.calendar] {
        didSet { UserDefaults.standard.set(requestedServices.map(\.rawValue), forKey: "google.services"); servicesChanged(from: oldValue) }
    }
    private var api: GoogleAPI?
    private let auth = GoogleAuthorization()
    private var authTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var generation = UUID()
    private var authGeneration = UUID()
    private var timer: Timer?
    private var displayedDate = Date()
    private var selectedCalendarIDs: Set<String>? {
        get { (UserDefaults.standard.array(forKey: "google.calendarIDs") as? [String]).map(Set.init) }
        set { UserDefaults.standard.set(newValue.map(Array.init), forKey: "google.calendarIDs") }
    }
    private static var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("NeroNook-Plugins/cafe.nero.plugin.google/google-client.json")
    }
    func importPreviousSetup() {
        guard !connected, !isConnecting else { return }
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NeroNook/google-client.json")
        do {
            let bytes = try Data(contentsOf: old)
            let configuration = try JSONDecoder().decode(GoogleClientConfiguration.self, from: bytes)
            try FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(configuration).write(to: Self.configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configURL.path)
            client = configuration
            if let prior = UserDefaults.standard.persistentDomain(forName: "local.neronook.preview"), let services = prior["google.services"] as? [String] { requestedServices = Set(services.compactMap(GoogleService.init)) }
            accountError = nil
        } catch { accountError = "Previous Google setup was not found. Import your Google Desktop client below." }
    }
    private init() {
        if let services = UserDefaults.standard.array(forKey: "google.services") as? [String] { requestedServices = Set(services.compactMap(GoogleService.init)) }
        if let url = Bundle.main.url(forResource: "GoogleOAuthClient", withExtension: "json"), let data = try? Data(contentsOf: url) { client = try? GoogleClientConfiguration.imported(data) }
        if client == nil, let data = try? Data(contentsOf: Self.configURL) { client = try? JSONDecoder().decode(GoogleClientConfiguration.self, from: data) }
    }
    func start() {
        do {
            if let saved = try GoogleKeychain.load() { apply(saved); sync() }
        } catch { accountError = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.sync() } }
    }
    func stop() { timer?.invalidate(); timer = nil; cancelSignIn(); syncTask?.cancel() }
    var connected: Bool { email != nil }
    func enabled(_ service: GoogleService) -> Bool { connected && requestedServices.contains(service) && grantedScopes.contains(service.scope) }
    var needsAccessUpdate: Bool { requestedServices.contains { !grantedScopes.contains($0.scope) } }
    func importConfiguration(_ url: URL) {
        guard !isConnecting else { return }
        do {
            let config = try GoogleClientConfiguration.imported(Data(contentsOf: url))
            try FileManager.default.createDirectory(at: Self.configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: Self.configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.configURL.path)
            client = config; accountError = nil
        } catch { accountError = "Could not import a Google Desktop client. Choose the JSON downloaded from Google Cloud's Clients page." }
    }
    func connect() {
        guard !isConnecting else { return }
        guard let client else { accountError = GoogleFailure.configuration.localizedDescription; return }
        accountError = nil; isConnecting = true
        let attempt = UUID(); authGeneration = attempt
        let services = requestedServices
        authTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await auth.connect(client: client, services: services)
                try Task.checkCancellation()
                guard authGeneration == attempt else { return }
                // Invalidate old in-flight refreshes before saving the new account.
                generation = UUID(); syncTask?.cancel()
                await api?.invalidate()
                try Task.checkCancellation()
                try GoogleKeychain.save(credential)
                if email != credential.email { selectedCalendarIDs = nil }
                clearData(); apply(credential); sync()
            } catch is CancellationError {} catch { if authGeneration == attempt { accountError = error.localizedDescription } }
            if authGeneration == attempt { isConnecting = false; authTask = nil }
        }
    }
    func cancelSignIn() { authGeneration = UUID(); auth.cancel(); authTask?.cancel(); authTask = nil; isConnecting = false }
    func disconnect() async {
        cancelSignIn(); generation = UUID(); syncTask?.cancel(); syncTask = nil
        await api?.invalidate(); api = nil
        do { try GoogleKeychain.remove(); accountError = nil }
        catch { accountError = error.localizedDescription }
        email = nil; grantedScopes = []; clearData(); selectedCalendarIDs = nil
    }
    private func apply(_ credential: GoogleCredential) {
        api = GoogleAPI(credential: credential); email = credential.email; grantedScopes = credential.scopes
        if client == nil { client = credential.client }
    }
    private func clearData() { calendars = []; calendarEntries = [:]; messages = []; tasks = []; files = []; lastSynced = [:]; errors = [:]; failures = [:]; syncing = [] }
    private func servicesChanged(from old: Set<GoogleService>) {
        if !requestedServices.contains(.calendar) { calendars = []; calendarEntries = [:] }
        if !requestedServices.contains(.gmail) { messages = [] }
        if !requestedServices.contains(.tasks) { tasks = [] }
        if !requestedServices.contains(.drive) { files = [] }
        guard api != nil else { return }
        sync()
    }
    func isCalendarSelected(_ id: String) -> Bool { selectedCalendarIDs?.contains(id) ?? true }
    func setCalendar(_ id: String, selected: Bool) {
        var ids = selectedCalendarIDs ?? Set(calendars.map(\.id))
        if selected { ids.insert(id) } else { ids.remove(id) }
        selectedCalendarIDs = ids
        calendarEntries = [:]
        sync()
    }
    func showDate(_ date: Date) {
        guard GoogleDates.key(displayedDate) != GoogleDates.key(date) else { return }
        displayedDate = date
        sync()
    }
    func sync() {
        guard let api, connected else { return }
        syncTask?.cancel()
        let run = UUID(); generation = run
        let date = displayedDate
        let services = Set(requestedServices.filter(enabled))
        syncing = services
        syncTask = Task { [weak self] in
            guard let self else { return }
            for service in GoogleService.allCases where services.contains(service) {
                guard generation == run, !Task.isCancelled else { return }
                do {
                    switch service {
                    case .calendar:
                        let remote = try await api.calendars()
                        let selected = remote.filter { self.isCalendarSelected($0.id) }
                        let days = Calendar.current.isDateInToday(date) ? [date] : [Date(), date]
                        var updated: [String: [AgendaEntry]] = [:]
                        for day in days {
                            var entries: [AgendaEntry] = []
                            for calendar in selected { entries += try await api.events(calendar: calendar, date: day) }
                            updated[GoogleDates.key(day)] = entries
                        }
                        guard generation == run, !Task.isCancelled else { return }
                        calendars = remote; calendarEntries = updated
                    case .gmail:
                        let value = try await api.inbox()
                        guard generation == run, !Task.isCancelled else { return }; messages = value
                    case .tasks:
                        let value = try await api.tasks()
                        guard generation == run, !Task.isCancelled else { return }; tasks = value
                    case .drive:
                        let value = try await api.recentFiles()
                        guard generation == run, !Task.isCancelled else { return }; files = value
                    }
                    lastSynced[service] = Date(); errors[service] = nil; failures[service] = nil
                } catch {
                    guard generation == run, !Task.isCancelled else { return }
                    errors[service] = error.localizedDescription
                    failures[service] = error as? GoogleFailure
                    if failures[service]?.invalidatesData == true {
                        lastSynced[service] = nil
                        switch service { case .calendar: calendarEntries = [:]; case .gmail: messages = []; case .tasks: tasks = []; case .drive: files = [] }
                    }
                }
                syncing.remove(service)
            }
            if generation == run { syncTask = nil }
        }
    }
    func agenda(on date: Date) -> [AgendaEntry] {
        var result = enabled(.calendar) ? calendarEntries[GoogleDates.key(date)] ?? [] : []
        if enabled(.tasks) {
            result += tasks.compactMap { task in
                guard let due = task.due, let start = GoogleDates.day(due), let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return nil }
                return AgendaEntry(id: "google-task:\(task.id)", title: task.title ?? "Untitled task", start: start, end: end, isAllDay: true, source: "Google Tasks", colorHex: "#34A853", location: nil, url: GoogleEvent.safeURL(task.webViewLink) ?? URL(string: "https://tasks.google.com/"), meetURL: nil, externalID: nil, nativeID: nil, isTask: true)
            }
        }
        return result
    }
    func openMessage(_ message: GoogleMessage) {
        guard let email else { return }
        var url = URLComponents(string: "https://mail.google.com/mail/u/")!
        url.queryItems = [.init(name: "authuser", value: email)]
        url.fragment = "inbox/\(message.threadId ?? message.id)"
        if let url = url.url { NSWorkspace.shared.open(url) }
    }
}
