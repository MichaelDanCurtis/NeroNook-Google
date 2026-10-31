import XCTest
import AppKit
import SwiftUI
import NookPluginSDK
@testable import ModuleApp

final class ReplyNativeViewTests:XCTestCase {
    @MainActor func testOptionalOfflineNativeDraftReview() async throws {
        guard let path=ProcessInfo.processInfo.environment["NEROFLOW_UI_DIR"] else { throw XCTSkip("Offline native export is opt-in.") }
        let directory=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        _=NSApplication.shared
        let draft=GoogleLocalReplyDraft(id:UUID(),account:"authored-account",messageID:"abc123",threadID:"def456",recipient:"Pat <pat@example.test>",subject:"Re: Friday meeting",body:"Friday works for me. Could we meet after 2 PM?",created:Date())
        for (name,scheme) in [("light",ColorScheme.light),("dark",ColorScheme.dark)] {
            let root=NSHostingView(rootView:VStack(alignment:.leading,spacing:16) {
                Text("Review reply draft").font(.title2)
                GoogleReplyEditor(draft:draft,bodyText:.constant(draft.body),save:{})
                Text("Saved locally. Nothing sent or saved to Gmail.").font(.caption)
            }.padding(24).pluginThemed().environment(\.colorScheme,scheme).frame(width:700,height:420))
            let window=NSWindow(contentRect:.init(x:0,y:0,width:700,height:420),styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false;window.contentView=root
            window.layoutIfNeeded();try await Task.sleep(for:.milliseconds(300));root.displayIfNeeded()
            let bitmap=try XCTUnwrap(root.bitmapImageRepForCachingDisplay(in:root.bounds))
            root.cacheDisplay(in:root.bounds,to:bitmap)
            let data=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            XCTAssertGreaterThan(data.count,3000);try data.write(to:directory.appendingPathComponent("reply-native-"+name+".png"))
            XCTAssertEqual(root.bounds.width,700);window.close()
        }
    }
}
