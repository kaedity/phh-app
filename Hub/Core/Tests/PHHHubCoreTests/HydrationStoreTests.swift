import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct HydrationStoreTests {
    let owner="synthetic@example.test",now=Date(timeIntervalSince1970:1_800_000_000)
    func page(_ water:HydrationRecord? = nil, cursor:Int=0, contract:Int?=1) -> Delta {
        let values:[String:Cell] = water.map { w in ["id":.string(w.id),"revision":.number(Double(w.revision)),"status":.string(w.removed ? "removed":"active"),"created_at":.string("2026-10-03T00:00:00Z"),"updated_at":.string("2026-10-03T00:00:00Z"),"source_kind":.string("app"),"last_operation_id":.string("00000000-0000-4000-a000-000000000100"),"local_date":.string(w.date),"time_zone":.string("Asia/Tokyo"),"amount_ml":.number(w.amountML),"confirmed_at":.string("2026-10-03T00:00:00Z")] } ?? [:]
        let count=water==nil ? 0:1
        return .init(schema_version:1,environment:hubEnvironment,generation:1,hydration_contract:contract,snapshot_revision:cursor+count,changes:water.map { w in [.init(change:.init(change_number:cursor+1,table_name:"WaterIntakes",entity_id:w.id,revision:w.revision,indexed_revision:w.revision,removed:w.removed,local_date:w.date),record:values)] } ?? [],next_cursor:cursor+count,has_more:false)
    }
    @Test func capabilityRequiredAndWireRoundtripSeparatesSynthetic() throws {
        let hub=try HubStore(owner:owner),water=try HydrationRecord(date:"2026-10-03",amountML:250),op=try water.operation()
        #expect(!op.synthetic);#expect(throws:HubError.configuration) {try hub.enqueue(op)}
        try hub.apply(page());try hub.enqueue(op);try hub.enqueue(op)
        #expect(try hub.pending().count==1)
        #expect(try JSONDecoder().decode(HubOperation.self,from:JSONEncoder().encode(op))==op)
        try hub.apply(page(contract:nil));#expect(try hub.hydrationContract==0)
    }
    @Test func malformedDeltaKeepsCursorAndConfirmedWater() throws {
        let hub=try HubStore(owner:owner),water=try HydrationRecord(date:"2026-10-03",amountML:250)
        try hub.apply(page(water));var bad=page(try water.edited(amountML:500),cursor:1)
        bad.changes[0].record["amount_ml"] = .number(-1)
        #expect(throws:HubError.invalidResponse){try hub.apply(bad)}
        #expect(try hub.cursor==1);#expect(try hub.hydrationSnapshot()==[water])
        #expect(throws:HubError.invalidResponse){try hub.apply(page(try water.edited(),cursor:1,contract:nil))}
    }
    @Test func unsentUndoCancelsOnlyWaterAndDeadlineRefuses() throws {
        let hub=try HubStore(owner:owner),w=try HydrationRecord(date:"2026-10-03",amountML:250)
        try hub.apply(page());let o=try w.operation(synthetic:true);try hub.enqueue(o)
        let change=HydrationUndoChange(operationID:o.id,before:nil,after:w,at:now)
        #expect(try hub.hydrationSnapshot()==[w]);try hub.undoHydrationChange(change,at:now,synthetic:true)
        #expect(try hub.pending().isEmpty);#expect(try hub.hydrationSnapshot().isEmpty)
        #expect(throws:HubError.invalidOperation){try hub.undoHydrationChange(change,at:now.addingTimeInterval(6),synthetic:true)}
    }
    @Test func inflightUndoSurvivesRestartAndCommitsExactlyOneCompensation() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),url=dir.appendingPathComponent("water.sqlite")
        defer {try? FileManager.default.removeItem(at:dir)}
        let w=try HydrationRecord(date:"2026-10-03",amountML:250),o=try w.operation(synthetic:true),change=HydrationUndoChange(operationID:o.id,before:nil,after:w,at:now)
        var hub:HubStore?=try HubStore(url:url,owner:owner);try hub!.apply(page());try hub!.enqueue(o);try hub!.markAttempted(o.id);try hub!.undoHydrationChange(change,at:now,synthetic:true);hub=nil
        let reopened=try HubStore(url:url,owner:owner)
        #expect(try reopened.hydrationSnapshot().first?.removed==true)
        let receipt=Receipt(environment:hubEnvironment,operation_id:o.id,status:"committed",entity_ids:[o.entity_id],revisions:[1],retryable:false)
        try reopened.finish(receipt,operation:o);try reopened.finish(receipt,operation:o)
        #expect(try reopened.pending().map(\.id)==[change.undoID]);#expect(try reopened.pending()[0].operation.hydration?.removed==true)
    }
    @Test func acknowledgedEditUndoRestoresPreviousDateAndAmountAtNewRevision() throws {
        let hub=try HubStore(owner:owner),before=try HydrationRecord(date:"2026-10-03",amountML:250),after=try before.edited(date:"2026-10-02",amountML:500),o=try after.operation(synthetic:true)
        try hub.apply(page(after));let change=HydrationUndoChange(operationID:o.id,before:before,after:after,at:now)
        try hub.undoHydrationChange(change,at:now,synthetic:true);try hub.undoHydrationChange(change,at:now,synthetic:true)
        let pending=try #require(hub.pending().first);#expect(pending.operation.hydration?.amountML==250);#expect(pending.operation.hydration?.date==before.date);#expect(pending.operation.expected_revision==2)
    }
}
