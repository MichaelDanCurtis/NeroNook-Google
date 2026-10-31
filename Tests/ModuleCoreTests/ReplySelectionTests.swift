import XCTest
import NookPluginSDK
@testable import ModuleApp
final class ReplySelectionTests:XCTestCase {
    func reference(_ values:[String:PluginValue],_ index:Int=0) throws -> String {
        guard case .string(let raw)=values["items"],case .string(let ref)=try PluginStructuredValue.parse(raw).value(at:"[\(index)].reference") else {throw GoogleFailure.malformed};return ref
    }
    func testSelectionPinsAccountOrderAndCountBeforeAnyBodyRead() throws {
        let s=GoogleReplySelectionStore();try s.select(["a","b","c"],account:"owner")
        let headers=["a":"First","b":"Second","c":"Third"],listed=try s.list(values:[:],headers:headers,account:"owner")
        XCTAssertEqual(listed["count"],.number(3))
        for (i,id) in ["a","b","c"].enumerated() {XCTAssertEqual(try s.message(reference(listed,i),account:"owner"),id)}
        let pinned:[String:PluginValue]=["selection_id":listed["selection_id"]!,"count":.number(3)]
        XCTAssertNoThrow(try s.list(values:pinned,headers:headers,account:"owner"))
        XCTAssertThrowsError(try s.list(values:["selection_id":listed["selection_id"]!],headers:headers,account:"owner"))
        XCTAssertThrowsError(try s.list(values:pinned,headers:headers,account:"other"))
        XCTAssertThrowsError(try s.list(values:pinned,headers:["a":"First"],account:"owner"))
        let ref=try reference(listed);try s.select(["c","b","a"],account:"owner")
        XCTAssertThrowsError(try s.message(ref,account:"owner"));XCTAssertThrowsError(try s.list(values:pinned,headers:headers,account:"owner"))
    }
    func testExpiryResetNoDuplicateSelectionAndMetadataBounds() throws {
        let s=GoogleReplySelectionStore(),now=Date();try s.select(["a"],account:"owner")
        let listed=try s.list(values:[:],headers:["a":String(repeating:"🌿",count:1000)],account:"owner",now:now),ref=try reference(listed)
        try PluginMailReplyBatchContract.list.output.validate(listed)
        XCTAssertThrowsError(try s.message(ref,account:"other",now:now))
        XCTAssertThrowsError(try s.message(ref,account:"owner",now:now.addingTimeInterval(3601)))
        try s.select(["a"],account:"owner");XCTAssertEqual(try s.message(ref,account:"owner",now:now),"a") // Same selection survives a metadata refresh.
        s.reset();XCTAssertThrowsError(try s.message(ref,account:"owner"))
        XCTAssertThrowsError(try s.select(["a","a"],account:"owner"));XCTAssertThrowsError(try s.select((0..<6).map(String.init),account:"owner"))
    }
    func testSeparateReplySourcesEditsAndReopen() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let vault=try GoogleReplyDraftStore(directory:directory);var ids=[UUID]()
        for n in 1...3 {
            let m=try JSONDecoder().decode(GoogleReplyMessage.self,from:JSONSerialization.data(withJSONObject:["id":"message-\(n)","threadId":"thread-\(n)","payload":["mimeType":"text/plain","headers":[["name":"From","value":"person\(n)@example.test"],["name":"Subject","value":"Subject \(n)"]],"body":["data":GoogleOAuthProtocol.base64URL(Data("Request \(n)".utf8))]]]))
            let context=try vault.context(m,account:"owner");guard case .string(let ref)=context["reference"] else {throw GoogleFailure.malformed}
            let d=try vault.create(reference:ref,reply:"Answer \(n) — café 🌿\nSecond line",truncated:false,account:"owner");ids.append(d.id)
            try vault.update(d.id,body:"Edited \(n) — 文\nSeparate draft",account:"owner")
        }
        let reopened=try GoogleReplyDraftStore(directory:directory)
        XCTAssertEqual(reopened.drafts.map(\.id),ids)
        for (i,d) in reopened.drafts.enumerated() {let n=i+1;XCTAssertEqual(d.messageID,"message-\(n)");XCTAssertEqual(d.recipient,"person\(n)@example.test");XCTAssertEqual(d.subject,"Re: Subject \(n)");XCTAssertEqual(d.body,"Edited \(n) — 文\nSeparate draft")}
    }
}
