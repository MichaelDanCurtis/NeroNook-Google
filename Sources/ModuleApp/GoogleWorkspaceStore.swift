import AppKit
import Combine
import SwiftUI
import NookPluginSDK

@MainActor
final class GoogleWorkspaceStore: ObservableObject {
    static let shared = GoogleWorkspaceStore()
    @Published private(set) var email: String?
    @Published private(set) var grantedScopes = Set<String>()
    @Published private(set) var restoring = false
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
    @Published var mailWorkflowAccess = UserDefaults.standard.bool(forKey: "google.mailWorkflowAccess") {
        didSet { replySelectionEpoch=UUID(); UserDefaults.standard.set(mailWorkflowAccess,forKey:"google.mailWorkflowAccess"); if !mailWorkflowAccess { replyDrafts?.resetReferences(); selectedReplyMessageID=""; clearReplyBatch() } }
    }
    @Published var selectedReplyMessageID = "" { didSet { if selectedReplyMessageID != oldValue { replySelectionEpoch=UUID() } } }
    private var replySelectionEpoch=UUID()
    @Published private(set) var selectedReplyMessageIDs: [String] = []
    private let replySelection = GoogleReplySelectionStore()
    @Published var replyStatus = ""
    @Published private(set) var latestReplyDraftID: UUID?
    private var replyAccount = ""
    lazy var replyDrafts: GoogleReplyDraftStore? = {
        guard let folder = try? PluginStorage.directory(id:"cafe.nero.plugin.google") else { return nil }
        return try? GoogleReplyDraftStore(directory:folder)
    }()
    private var api: GoogleAPI?
    private let auth = GoogleAuthorization()
    private var restoreTask: Task<Void, Never>?
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
        restoreAccount(allowUI: false)
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.sync() } }
    }
    func restoreAccount(allowUI: Bool = true) {
        guard !connected, !isConnecting, !restoring else { return }
        restoring = true
        restoreTask?.cancel(); let attempt = UUID(); authGeneration = attempt
        restoreTask = Task { [weak self] in
            defer { if self?.authGeneration == attempt { self?.restoring = false; self?.restoreTask = nil } }
            do {
                let credential = try await Task.detached { try GoogleKeychain.load(allowUI: allowUI) }.value
                guard !Task.isCancelled, let self, self.authGeneration == attempt else { return }
                if let credential { self.apply(credential); self.accountError = nil; self.sync() }
                else if allowUI { self.accountError = "No saved account. Choose Sign in to connect Google." }
            } catch {
                guard let self, self.authGeneration == attempt, !Task.isCancelled else { return }
                self.accountError = "The saved Google account could not be restored. Choose Use saved sign-in in Settings, or sign in again."
            }
        }
    }
    func stop() { timer?.invalidate(); timer = nil; restoreTask?.cancel(); restoreTask = nil; restoring = false; cancelSignIn(); syncTask?.cancel() }
    var connected: Bool { email != nil }
    func enabled(_ service: GoogleService) -> Bool { connected && requestedServices.contains(service) && grantedScopes.contains(service.scope) }
    var needsAccessUpdate: Bool { requestedServices.contains { !grantedScopes.contains($0.scope) } || (mailWorkflowAccess && requestedServices.contains(.gmail) && !grantedScopes.contains("https://www.googleapis.com/auth/gmail.readonly")) }
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
        restoreTask?.cancel(); restoreTask = nil; restoring = false
        guard let client else { accountError = GoogleFailure.configuration.localizedDescription; return }
        accountError = nil; isConnecting = true
        let attempt = UUID(); authGeneration = attempt
        let services = requestedServices
        authTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credential = try await auth.connect(client: client, services: services, mailWorkflowAccess: mailWorkflowAccess)
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
    func cancelSignIn() { restoreTask?.cancel(); restoreTask = nil; restoring = false; authGeneration = UUID(); auth.cancel(); authTask?.cancel(); authTask = nil; isConnecting = false }
    func disconnect() async {
        cancelSignIn(); generation = UUID(); syncTask?.cancel(); syncTask = nil
        await api?.invalidate(); api = nil
        do { try GoogleKeychain.remove(); accountError = nil }
        catch { accountError = error.localizedDescription }
        email = nil; grantedScopes = []; clearData(); selectedCalendarIDs = nil
    }
    private func apply(_ credential: GoogleCredential) {
        replyDrafts?.resetReferences(); selectedReplyMessageID=""; clearReplyBatch(); replyAccount=credential.subject
        api = GoogleAPI(credential: credential); email = credential.email; grantedScopes = credential.scopes
        if client == nil { client = credential.client }
    }
    private func clearData() { latestReplyDraftID=nil; replyDrafts?.resetReferences();selectedReplyMessageID=""; clearReplyBatch();replyAccount=""; calendars = []; calendarEntries = [:]; messages = []; tasks = []; files = []; lastSynced = [:]; errors = [:]; failures = [:]; syncing = [] }
    private func servicesChanged(from old: Set<GoogleService>) {
        if !requestedServices.contains(.calendar) { calendars = []; calendarEntries = [:] }
        if !requestedServices.contains(.gmail) { messages = []; replyDrafts?.resetReferences(); selectedReplyMessageID=""; clearReplyBatch() }
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
    var canReadReply: Bool { enabled(.gmail) && mailWorkflowAccess && grantedScopes.contains("https://www.googleapis.com/auth/gmail.readonly") }
    var localReplyDrafts: [GoogleLocalReplyDraft] { replyDrafts?.drafts.filter{$0.account==replyAccount} ?? [] }
    private func clearReplyBatch() { selectedReplyMessageIDs=[]; replySelection.reset() }
    func selectReplyMessage(_ id: String, selected: Bool) {
        guard canReadReply, messages.contains(where:{$0.id==id}) else { return }
        var ids=selectedReplyMessageIDs.filter{$0 != id}
        if selected { ids.append(id) }
        do { try replySelection.select(ids, account:replyAccount); selectedReplyMessageIDs=ids; replyStatus="\(ids.count) of 5 messages selected" }
        catch { replyStatus="Choose at most five messages." }
    }
    func mailReplyAction(_ action:String,values:[String:PluginValue]) async throws -> [String:PluginValue] {
        guard canReadReply,let api,let vault=replyDrafts else { throw GoogleFailure.missingScope }
        let epoch=generation,selection=replySelectionEpoch,account=replyAccount
        if action==PluginMailReplyBatchContract.list.id {
            return try replySelection.list(values:values,headers:Dictionary(uniqueKeysWithValues:messages.map{($0.id,$0.header("Subject"))}),account:account)
        }
        if action==PluginMailReplyBatchContract.read.id {
            try PluginMailReplyBatchContract.read.input.validate(values)
            guard case .string(let reference)=values["reference"] else { throw GoogleFailure.malformed }
            let messageID=try replySelection.message(reference,account:account), selectionID=replySelection.id
            let message=try await api.replyMessage(messageID)
            try Task.checkCancellation()
            guard generation==epoch, replyAccount==account, canReadReply, replySelection.id==selectionID,
                  try replySelection.message(reference,account:account)==messageID, message.id==messageID else { throw GoogleReplyProblem.stale }
            return try vault.context(message,account:account)
        }
        if action==PluginMailReplyContract.read.id {
            try PluginMailReplyContract.read.input.validate(values)
            guard messages.contains(where:{$0.id==selectedReplyMessageID}) else { throw GoogleReplyProblem.selection }
            let message=try await api.replyMessage(selectedReplyMessageID)
            try Task.checkCancellation()
            guard generation==epoch,replySelectionEpoch==selection,replyAccount==account,canReadReply else { throw GoogleReplyProblem.stale }
            return try vault.context(message,account:account)
        }
        try PluginMailReplyContract.review.input.validate(values)
        guard action==PluginMailReplyContract.review.id,case .string(let reference)=values["reference"],case .string(let reply)=values["reply"],case .boolean(let truncated)=values["truncated"] else { throw GoogleFailure.malformed }
        let draft=try vault.create(reference:reference,reply:reply,truncated:truncated,account:account)
        latestReplyDraftID=draft.id
        replyStatus="Local reply draft ready · nothing sent or saved to Gmail"
        return ["draft_id":.string(draft.id.uuidString),"status":.string(replyStatus)]
    }
    func saveReplyEdit(_ id:UUID,body:String) throws {
        guard connected,let vault=replyDrafts else { throw GoogleReplyProblem.stale }
        try vault.update(id,body:body,account:replyAccount);replyStatus="Local edits saved · nothing sent"
    }
    func calendarRead(_ action: String, values: [String: PluginValue]) async throws -> [String: PluginValue] {
        guard enabled(.calendar), let api else { throw GoogleFailure.missingScope }
        let calendars = try await api.calendars().filter { self.isCalendarSelected($0.id) }
        guard calendars.count <= 16 else { throw GoogleFailure.pageLimit }
        let result: [String: PluginValue]
        if action == PluginCalendarContract.list.id {
            let range = try PluginCalendarContract.range(values)
            var events: [PluginCalendarEvent] = []
            for calendar in calendars { try Task.checkCancellation(); events += try await api.calendarEvents(calendar: calendar, start: range.start, end: range.end); guard events.count <= 10000 else { throw GoogleFailure.pageLimit } }
            events.sort { $0.start == $1.start ? $0.reference.event < $1.reference.event : $0.start < $1.start }
            result = try PluginCalendarContract.page(events, offset: range.offset)
        } else {
            let reference = try PluginCalendarContract.reference(values)
            guard let calendar = calendars.first(where: { $0.id == reference.calendar }) else { throw GoogleFailure.permission }
            result = try PluginCalendarContract.result(try await api.calendarEvent(reference, calendar: calendar))
        }
        try Task.checkCancellation(); guard enabled(.calendar), self.api === api else { throw CancellationError() }
        return result
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
