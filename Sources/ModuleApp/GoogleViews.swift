import SwiftUI
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
    @State private var page = "Inbox"
    @State private var unreadOnly = false
    @State private var showSettings = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(google.email ?? "Your Google workspace", systemImage: "globe").font(.headline).lineLimit(1)
                Spacer()
                if !google.syncing.isEmpty { ProgressView().controlSize(.small) }
                Button { google.sync() } label: { Image(systemName: "arrow.clockwise") }.help("Sync Google").disabled(!google.connected || !google.syncing.isEmpty)
                Button { showSettings = true } label: { Image(systemName: "gearshape") }.help("Google settings")
            }
            Picker("Google service", selection: $page) { Text("Inbox").tag("Inbox"); Text("Tasks").tag("Tasks"); Text("Files").tag("Files") }.pickerStyle(.segmented)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showSettings) { VStack(spacing: 0) { HStack { Text("Google").font(.headline); Spacer(); Button("Done") { showSettings = false } }.padding(); GoogleSettingsView() }.frame(width: 560, height: 560) }
    }
    private var service: GoogleService { page == "Inbox" ? .gmail : page == "Tasks" ? .tasks : .drive }
    @ViewBuilder private var content: some View {
        if !google.enabled(service) {
            ContentUnavailableView { Label(google.connected ? "Enable \(service.title)" : "Connect Google", systemImage: "globe") } description: { Text(service.detail) } actions: { Button("Google account settings…") { showSettings = true } }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let error = google.errors[service] { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                if let date = google.lastSynced[service] { Text("Updated \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                if page == "Inbox" {
                    Toggle("Unread only", isOn: $unreadOnly).toggleStyle(.checkbox).font(.caption)
                    let messages = google.messages.filter { !unreadOnly || $0.unread }
                    if messages.isEmpty { empty(google.syncing.contains(.gmail) ? "Loading your inbox…" : "No messages in the latest 20 inbox items") }
                    else { ScrollView { LazyVStack(spacing: 6) { ForEach(messages) { message in
                        Button { google.openMessage(message) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Circle().fill(message.unread ? Color.blue : Color.clear).frame(width: 6, height: 6).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 3) { Text(message.header("Subject").isEmpty ? "(No subject)" : message.header("Subject")).fontWeight(message.unread ? .semibold : .regular).lineLimit(1); Text(message.header("From")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer(); if let date = message.receivedAt { Text(date, style: .date).font(.caption2).foregroundStyle(.secondary) }
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help("Open in Gmail")
                    } } } }
                } else if page == "Tasks" {
                    if google.tasks.isEmpty { empty(google.syncing.contains(.tasks) ? "Loading tasks…" : "No open Google tasks") }
                    else { ScrollView { LazyVStack(spacing: 6) { ForEach(google.tasks) { task in
                        Button { NSWorkspace.shared.open(GoogleEvent.safeURL(task.webViewLink) ?? URL(string: "https://tasks.google.com/")!) } label: {
                            HStack { Image(systemName: "circle").foregroundStyle(.green); Text(task.title ?? "Untitled task"); Spacer(); if let due = task.due, let date = GoogleDates.day(due) { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) } }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).help("Open in Google Tasks")
                    } } } }
                } else {
                    if google.files.isEmpty { empty(google.syncing.contains(.drive) ? "Loading files…" : "No recent Google Drive files") }
                    else { ScrollView { LazyVStack(spacing: 6) { ForEach(google.files) { file in
                        Button { if let url = GoogleEvent.safeURL(file.webViewLink) { NSWorkspace.shared.open(url) } } label: {
                            HStack { Image(systemName: file.mimeType?.contains("spreadsheet") == true ? "tablecells" : file.mimeType?.contains("presentation") == true ? "rectangle.on.rectangle" : "doc.text").foregroundStyle(.blue); Text(file.name ?? "Untitled file").lineLimit(1); Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.secondary) }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(GoogleEvent.safeURL(file.webViewLink) == nil)
                    } } } }
                }
            }
        }
    }
    private func empty(_ text: String) -> some View { Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
