import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct FoodUndoTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func baseline() throws -> (FoodLocalState, FoodMeal) {
        let fixture = try FoodHubTests().fixture(), hub = try HubStore(owner: "synthetic@example.test")
        try hub.apply(fixture.page)
        return (try FoodLocalState(catalog: FoodCatalogReader.catalog(hub.rows()), confirmed: [fixture.meal]), fixture.meal)
    }
    @Test func unsentQuantityDateSlotAndRemovalUndoRestoreExactPreviousValues() throws {
        let (initial, before) = try baseline()
        let afters = try [before.edited(factor: 2), before.edited(date: "2026-10-03"), before.edited(slot: "夕食"), before.edited(remove: true)]
        for after in afters {
            let store = try FoodLocalStore(initial: initial), operation = try store.enqueue(after)
            let change = try FoodUndoChange(operationID: operation, before: before, after: after, at: now)
            try store.undoChange(change, at: now.addingTimeInterval(4))
            #expect(store.state.pending.isEmpty); #expect(store.state.confirmed == [before])
        }
    }
    @Test func acknowledgedQuantityDateSlotAndRemovalUndoUseOneNewIDAndOriginalNutrients() throws {
        let (initial, before) = try baseline()
        let afters = try [before.edited(factor: 2), before.edited(date: "2026-10-03", slot: "夕食"), before.edited(remove: true)]
        for after in afters {
            let store = try FoodLocalStore(initial: initial), operation = try store.enqueue(after)
            let change = try FoodUndoChange(operationID: operation, before: before, after: after, at: now)
            _ = try store.beginSending(operation); try store.acknowledge(operation, confirmed: after)
            try store.undoChange(change, at: now); try store.undoChange(change, at: now)
            let restore = try #require(store.state.pending.first)
            #expect(store.state.pending.count == 1); #expect(restore.id == change.undoID && restore.id != operation)
            #expect(restore.expectedRevision == 2); #expect(restore.meal.revision == 3)
            #expect(restore.meal.items == before.items && restore.meal.date == before.date && restore.meal.slot == before.slot && !restore.meal.removed)
        }
    }
    @Test func inflightUndoSurvivesLocalRestartAndIsAppliedOnceAfterReceipt() throws {
        let (initial, before) = try baseline(), after = try before.edited(factor: 2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try FoodLocalStore(url: url, initial: initial), operation = try store.enqueue(after)
        let change = try FoodUndoChange(operationID: operation, before: before, after: after, at: now)
        _ = try store.beginSending(operation); try store.undoChange(change, at: now)
        let reopened = try FoodLocalStore(url: url, initial: initial)
        let projection = try FoodDayPresentation(date: before.date, snapshot: reopened.snapshot())
        #expect(projection.localTotal == projection.confirmedTotal)
        _ = try reopened.beginSending(operation); try reopened.acknowledge(operation, confirmed: after)
        try reopened.acknowledge(operation, confirmed: after)
        #expect(reopened.state.pending.map(\.id) == [change.undoID])
        #expect(reopened.state.pending[0].meal.items == before.items)
    }
    @Test func commonOutboxPersistsInflightRemovalUndoAndDoesNotDuplicateCompensation() throws {
        let fixture = try FoodHubTests().fixture(), before = fixture.meal, after = try before.edited(remove: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("hub.sqlite")
        var hub: HubStore? = try HubStore(url: url, owner: "synthetic@example.test"); try hub!.apply(fixture.page)
        let wire = try FoodWireOperation(.init(expectedRevision: before.revision, meal: after), environment: hubEnvironment).hubOperation()
        let change = try FoodUndoChange(operationID: wire.id, before: before, after: after, at: now)
        try hub!.enqueue(wire); try hub!.markAttempted(wire.id); try hub!.undoFoodChange(change, at: now)
        hub=nil
        let reopened = try HubStore(url: url, owner: "synthetic@example.test"), screen = try FoodHubStore(hub: reopened).snapshot()
        #expect(screen.pending[0].undoOperationID == change.undoID)
        #expect(try FoodDayPresentation(date: before.date, snapshot: screen).localTotal == FoodTotal(items: before.items))
        let receipt = Receipt(environment: hubEnvironment, operation_id: wire.id, status: "committed", entity_ids: [wire.entity_id], revisions: [2], retryable: false)
        try reopened.finish(receipt, operation: wire); try reopened.finish(receipt, operation: wire)
        let outbox = try reopened.pending()
        #expect(outbox.map(\.id) == [change.undoID]); #expect(outbox[0].operation.foodMeal?.removed == false)
        #expect(outbox[0].operation.foodMeal?.items == before.items); #expect(outbox[0].operation.expected_revision == 2)
        #expect(try !reopened.foodUndoRequested(wire.id))
    }
    @Test func deadlineAndLaterRevisionPreventStaleUndoWithoutLosingPendingChange() throws {
        let (initial, before) = try baseline(), after = try before.edited(factor: 2)
        let store = try FoodLocalStore(initial: initial), operation = try store.enqueue(after)
        let change = try FoodUndoChange(operationID: operation, before: before, after: after, at: now)
        #expect(change.available(at: now.addingTimeInterval(4.999)))
        #expect(!change.available(at: now.addingTimeInterval(5)))
        #expect(throws: FoodFailure.invalidValue) { try store.undoChange(change, at: now.addingTimeInterval(5)) }
        #expect(store.state.pending.map(\.id) == [operation])
        #expect(throws: FoodFailure.revisionConflict) { try change.restoration(current: after.edited(factor: 3)) }
    }
}
