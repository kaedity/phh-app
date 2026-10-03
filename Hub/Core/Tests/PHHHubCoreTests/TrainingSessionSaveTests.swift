import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct TrainingSessionSaveTests {
    let base = TrainingTests()
    func row(_ revision: Int = 1) throws -> LocalRow {
        let original = try #require(base.futureRows().first { $0.table == "TrainingSessions" && $0.entityID == base.id(1) })
        var values = original.values; values["revision"] = .number(Double(revision))
        values["lifecycle_state"] = .string(revision == 1 ? "completed" : "in_progress")
        return .init(table: original.table, values: values)
    }
    func apply(_ hub: HubStore, row: LocalRow, cursor: Int = 1, generation: Int = 1) throws {
        try hub.apply(.init(schema_version:1,environment:hubEnvironment,generation:generation,training_contract:1,
            snapshot_revision:cursor,changes:[.init(change:.init(change_number:cursor,table_name:row.table,
                entity_id:row.entityID,revision:row.revision,indexed_revision:row.revision,removed:false,
                local_date:row.values["local_date"]?.text),record:row.values)],next_cursor:cursor,has_more:false))
    }
    func receipt(_ op: HubOperation) -> Receipt {
        .init(environment:hubEnvironment,operation_id:op.id,status:"committed",entity_ids:[op.entity_id],
              revisions:[op.expected_revision+1],retryable:false)
    }
    @Test func queuedSessionSurvivesRestartAndBlocksSameOrDifferentSecondSave() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("hub.sqlite"),hub=try HubStore(url:url,owner:"synthetic@example.test")
        try apply(hub,row:row())
        let op=try hub.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.inProgress,synthetic:false)
        let reopened=try HubStore(url:url,owner:"synthetic@example.test")
        #expect(try reopened.pending().first?.operation == op);#expect(!op.synthetic)
        #expect(throws:TrainingSessionSaveFailure.pending) {try reopened.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.inProgress)}
        #expect(throws:TrainingSessionSaveFailure.pending) {try reopened.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.planned)}
        #expect(try reopened.pending().count == 1)
        #expect(try reopened.rows(table:"TrainingSessions").first?.revision == 1)
    }
    @Test func receiptSurvivesRestartAndPreventsStaleRevisionUntilCanonicalReadback() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("hub.sqlite"),hub=try HubStore(url:url,owner:"synthetic@example.test")
        try apply(hub,row:row());let op=try hub.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.inProgress)
        try hub.finish(receipt(op),operation:op)
        let reopened=try HubStore(url:url,owner:"synthetic@example.test")
        #expect(try reopened.pending().isEmpty)
        #expect(throws:TrainingSessionSaveFailure.readbackPending) {try reopened.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.planned)}
        try apply(reopened,row:row(2),cursor:2)
        let next=try reopened.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.planned)
        #expect(next.expected_revision == 2);#expect(next.id != op.id)
    }
    @Test func unexpectedGenerationDoesNotBypassReceiptOrCanonicalReadbackGuards() throws {
        let hub=try HubStore(owner:"synthetic@example.test");try apply(hub,row:row())
        let op=try hub.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.inProgress)
        try hub.finish(receipt(op),operation:op)
        #expect(throws:HubError.invalidResponse) { try apply(hub,row:row(),generation:2) }
        #expect(throws:TrainingSessionSaveFailure.readbackPending) {try hub.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.planned)}
        #expect(try hub.rows(table:"TrainingSessions").first?.revision == 1)
    }
    @Test func unsupportedContractMissingSessionAndWrongSlotDoNotCreatePendingWork() throws {
        let empty=try HubStore(owner:"synthetic@example.test")
        #expect(throws:HubError.configuration) {try empty.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.planned)}
        let hub=try HubStore(owner:"synthetic@example.test");try apply(hub,row:row())
        #expect(throws:HubError.invalidOperation) {try hub.enqueueTrainingSessionUpdate(sessionID:base.id(100),state:.planned)}
        let cycle=try base.plan()
        #expect(throws:HubError.invalidOperation) {try hub.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.completed,cycle:cycle,slot:cycle.slots[0])}
        let op=try hub.enqueueTrainingSessionUpdate(sessionID:base.id(1),state:.completed,cycle:cycle,slot:cycle.slots[1])
        #expect(op.trainingSession?.plan_slot_id == cycle.slots[1].id)
        #expect(try hub.pending().count == 1)
    }
}
