import SwiftUI
import NookPluginSDK
import AppKit
import UniformTypeIdentifiers

struct GoogleSettingsView: View {
    @ObservedObject private var google = GoogleWorkspaceStore.shared
    var body: some View {
        Form {
            Section("Google account") {
                if let email = google.email {
                    Label(email, systemImage: "person.crop.circle.badge.checkmark")
                    HStack {
                        Button(google.needsAccessUpdate ? "Update Google access…" : "Reconnect…") { google.connect() }
                        Button("Disconnect on this Mac") { Task { await google.disconnect() } }
                    }.disabled(google.isConnecting)
                } else {
                    Text("Bring your Google events, inbox and tasks into your nook.")
                    Button("Sign in with Google") { google.connect() }.disabled(google.isConnecting)
                }
                if google.isConnecting {
                    HStack { ProgressView().controlSize(.small); Text("Finish signing in in your browser"); Spacer(); Button("Cancel") { google.cancelSignIn() } }
                }
                if let error = google.accountError { Text(error).foregroundStyle(.orange).font(.callout) }
                if google.client == nil, google.accountError == nil {
                    Text("Google sign-in needs to be configured for this development build.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Choose what appears") {
                Text("Works with personal Gmail and Google Workspace accounts.").font(.caption).foregroundStyle(.secondary)
                ForEach(GoogleService.allCases) { service in
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(service.title, isOn: Binding(get: { google.requestedServices.contains(service) }, set: { selected in
                            if selected { google.requestedServices.insert(service) } else { google.requestedServices.remove(service) }
                        })).disabled(google.isConnecting)
                        Text(service.detail).font(.caption).foregroundStyle(.secondary)
                        if google.connected, google.requestedServices.contains(service), !google.enabled(service) {
                            Text("Use Update Google access to enable this service.").font(.caption).foregroundStyle(.orange)
                        }
                        if let error = google.errors[service] { Text(error).font(.caption).foregroundStyle(.orange) }
                        if google.failures[service] == .apiDisabled {
                            Link("Enable \(service.title) API", destination: URL(string: "https://console.cloud.google.com/apis/library/" + service.apiName)!)
                        } else if google.failures[service] == .missingScope {
                            Button("Update Google access") { google.connect() }.disabled(google.isConnecting)
                        }
                    }
                }
                Text("NeroNook reads the services you select. It does not send mail, edit events, or change your files. Turning a service off stops fetching and clears its view.").font(.caption).foregroundStyle(.secondary)
            }
            if google.enabled(.calendar), !google.calendars.isEmpty {
                Section("Google calendars in your agenda") {
                    ForEach(google.calendars) { calendar in
                        Toggle(isOn: Binding(get: { google.isCalendarSelected(calendar.id) }, set: { google.setCalendar(calendar.id, selected: $0) })) {
                            Label { Text(calendar.title) } icon: { Circle().fill(Color(hex: calendar.backgroundColor ?? "#4285F4")).frame(width: 9, height: 9) }
                        }
                    }
                }
            }
            Section("Sync") {
                if google.connected {
                    Button("Sync now") { google.sync() }.disabled(!google.syncing.isEmpty)
                    ForEach(GoogleService.allCases.filter { google.enabled($0) }) { service in
                        LabeledContent(service.title) {
                            if google.syncing.contains(service) { ProgressView().controlSize(.small) }
                            else if let date = google.lastSynced[service] { Text(date, style: .relative).font(.caption) }
                            else { Text("Not synced").font(.caption) }
                        }
                    }
                }
                Text("Refreshes every five minutes while NeroNook runs, when changing dates, or when you choose Sync now. Data is kept in memory; sign-in credentials are stored in macOS Keychain.").font(.caption).foregroundStyle(.secondary)
                Link("Manage Google's events from Gmail", destination: URL(string: "https://calendar.google.com/calendar/u/0/r/settings")!)
                Link("Manage NeroNook's Google access", destination: URL(string: "https://myaccount.google.com/connections")!)
            }
            Section {
                DisclosureGroup("Developer setup") {
                    Button("Import previous Nook setup") { google.importPreviousSetup() }.disabled(google.connected || google.isConnecting)
                    Text("Imports client configuration and selected services. Sign in again in this independent plugin; your old connection is preserved.").font(.caption).foregroundStyle(.secondary)
                    Text("Import the Desktop app OAuth client JSON for NeroNook. Enable Calendar, Gmail, Tasks and Drive APIs in that Google Cloud project. A published build supplies its own registered client.").font(.caption).foregroundStyle(.secondary)
                    Button(google.client == nil ? "Import Google client…" : "Replace Google client…", action: importClient).disabled(google.connected || google.isConnecting)
                    Link("Open Google Cloud clients", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
                }
            }
        }.formStyle(.grouped)
    }
    private func importClient() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.prompt = "Use Google Client"
        panel.begin { result in if result == .OK, let url = panel.url { Task { @MainActor in google.importConfiguration(url) } } }
    }
}

struct GoogleWorkspaceView: View {
    @ObservedObject private var google = GoogleWorkspaceStore.shared
    @State private var page = "calendar"
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var showSettings = false
    var body: some View {
        let presentation = GoogleCollections.build(store: google, selectedDay: day)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Google").font(.headline)
                Spacer()
                Text(google.email ?? "Connect your account").font(.caption).foregroundStyle(.secondary)
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Google settings")
            }
            Picker("Google service", selection: $page) { ForEach(presentation.panels) { Text($0.title).tag($0.id) } }.pickerStyle(.segmented)
            if let collection = presentation.panels.first(where: { $0.id == page })?.collection {
                PluginCollectionView(collection: collection) { action in
                    if action == "refresh" { google.sync() }
                    else if let date = presentation.dates[action] { day = date; google.showDate(date) }
                    else if let url = presentation.links[action] { NSWorkspace.shared.open(url) }
                }.id(page).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.sheet(isPresented: $showSettings) {
            VStack(spacing: 0) { HStack { Text("Google Settings").font(.headline); Spacer(); Button("Done") { showSettings = false } }.padding(); GoogleSettingsView() }.frame(width: 580, height: 650)
        }
    }
}
