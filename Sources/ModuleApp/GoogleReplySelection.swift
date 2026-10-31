import Foundation
import NookPluginSDK

/// Session-only selection and opaque, account-bound item references. A workflow
/// pins the explicit selection; refreshing the inbox cannot silently retarget it.
final class GoogleReplySelectionStore {
    private(set) var id = UUID()
    private var ids: [String] = []
    private var account = ""
    private struct Item { let message: String; let account: String; let selection: UUID; let expires: Date }
    private var items: [UUID: Item] = [:]
    func select(_ ids: [String], account: String) throws {
        guard ids.count <= 5, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }) else { throw GoogleReplyProblem.selection }
        guard self.ids != ids || self.account != account else { return }
        self.ids = ids; self.account = account; id = UUID(); items = [:]
    }
    func reset() { ids=[]; account=""; id=UUID(); items=[:] }
    func list(values: [String: PluginValue], headers: [String: String], account: String, now: Date = Date()) throws -> [String: PluginValue] {
        try PluginMailReplyBatchContract.list.input.validate(values)
        guard !account.isEmpty, self.account == account, (1...5).contains(ids.count), ids.allSatisfy({headers[$0] != nil}) else { throw GoogleReplyProblem.selection }
        if !values.isEmpty {
            guard values["selection_id"] == .string(id.uuidString), values["count"] == .number(Double(ids.count)) else { throw GoogleReplyProblem.stale }
        }
        items = items.filter { $0.value.expires > now }
        guard items.count + ids.count <= 80 else { throw GoogleReplyProblem.stale }
        var pending: [UUID:Item] = [:]
        let rows = ids.map { message -> PluginStructuredValue in
            let reference=UUID(); pending[reference] = Item(message:message,account:account,selection:id,expires:now.addingTimeInterval(3600))
            // Subject is display-only; the original header remains provider-owned.
            let subject=String((headers[message] ?? "").prefix(60))
            return .object(["reference":.string(reference.uuidString),"subject":.string(subject.isEmpty ? "(No subject)" : subject)])
        }
        let result:[String:PluginValue] = ["selection_id":.string(id.uuidString),"count":.number(Double(rows.count)),"items":.string(try PluginStructuredValue.array(rows).json())]
        try PluginMailReplyBatchContract.list.output.validate(result)
        items.merge(pending) { _,new in new }; return result
    }
    func message(_ reference: String, account: String, now: Date = Date()) throws -> String {
        guard let key=UUID(uuidString:reference), let item=items[key], item.account==account, self.account==account, item.selection==id, item.expires>now, ids.contains(item.message) else { throw GoogleReplyProblem.stale }
        return item.message
    }
}
