import SwiftUI
import AppKit
import NookPluginSDK

@MainActor enum GoogleReplyWindows {
    private static var window: NSWindow?
    static func show() {
        if window == nil {
            let view = GoogleReplyView().pluginThemed()
            let value = NSWindow(contentRect: .init(x:0,y:0,width:700,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            value.title="Nero Flow · Gmail reply";value.isReleasedWhenClosed=false
            value.contentView=NSHostingView(rootView:view);value.minSize = .init(width:580,height:520)
            value.center();window=value
        }
        NSApp.activate(ignoringOtherApps:true);window?.makeKeyAndOrderFront(nil)
    }
}

struct GoogleReplyView: View {
    @ObservedObject private var store=GoogleWorkspaceStore.shared
    @State private var selected:UUID?
    @State private var bodyText=""
    @State private var message=""
    @State private var settings=false
    var body: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:16) {
            Text("Gmail → Ember → reply draft").font(.title2.weight(.semibold))
            Text("Choose one email, then create the Reply draft starter in Nero Flow. Review the agent’s target and exact task before Send. The agent may use its configured remote backend and tools.").font(.callout).pluginSecondaryText()
            if !store.canReadReply {
                Button("Enable selected-message access…") { settings=true }
                Text("Optional Gmail read access must be enabled and approved in Google sign-in. Your existing inbox connection is unchanged.").font(.caption).pluginSecondaryText()
            }
            Picker("Message for the next run",selection:$store.selectedReplyMessageID) {
                Text("Choose an email").tag("")
                ForEach(store.messages) { item in Text(String((item.header("Subject")+" · "+item.header("From")).prefix(100))).tag(item.id) }
            }.disabled(!store.canReadReply)
            Text("Short plain-text messages only in this first version. Attachments and HTML-only messages are excluded. No body is fetched until you run the workflow.").font(.caption).pluginSecondaryText()
            Divider()
            HStack {
                Text("Local reply drafts").font(.headline);Spacer()
                Picker("Draft",selection:$selected) {
                    Text("Choose a draft").tag(Optional<UUID>.none)
                    ForEach(store.localReplyDrafts.reversed()) { item in Text(String(item.subject.prefix(90))).tag(Optional(item.id)) }
                }.labelsHidden()
            }
            if let draft=store.localReplyDrafts.first(where:{$0.id==selected}) {
                GoogleReplyEditor(draft:draft,bodyText:$bodyText,save:{
                    do { try store.saveReplyEdit(draft.id,body:bodyText);message="Saved on this Mac." } catch { message=error.localizedDescription }
                })

            } else { ContentUnavailableView("No reply selected",systemImage:"envelope.open",description:Text("Completed Nero Flow drafts appear here for editing and review.")) }
            Text(message.isEmpty ? store.replyStatus : message).font(.caption).pluginSecondaryText()
            Text("Saved locally, up to 20 drafts. Not a Gmail draft. Only you can copy it into your mail client.").font(.caption).pluginSecondaryText()
        }.padding(24).frame(maxWidth:.infinity,alignment:.leading)
        }
        .onChange(of:selected) { _, id in bodyText=store.localReplyDrafts.first(where:{$0.id==id})?.body ?? "";message="" }
        .onChange(of:store.latestReplyDraftID) { _, id in selected=id }
        .onAppear { selected=store.localReplyDrafts.last?.id;bodyText=store.localReplyDrafts.last?.body ?? "" }
        .sheet(isPresented:$settings) { GoogleSettingsView(done:{settings=false}) }
    }
}

/// The same editor is used by the live provider and isolated native review.
struct GoogleReplyEditor:View {
    let draft:GoogleLocalReplyDraft
    @Binding var bodyText:String
    var save:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            LabeledContent("To",value:draft.recipient)
            LabeledContent("Subject",value:draft.subject)
            TextEditor(text:$bodyText).font(.body).scrollContentBackground(.hidden).padding(10).frame(height:180).background(.background.opacity(0.5),in:RoundedRectangle(cornerRadius:14))
            HStack {
                Button("Save local edits",action:save)
                Button("Copy reply") { NSPasteboard.general.clearContents();NSPasteboard.general.setString(bodyText,forType:.string) }
                Spacer();Text("Nothing sent").font(.caption).pluginSecondaryText()
            }
        }
    }
}
