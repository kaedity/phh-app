import Foundation
import Testing
@testable import PHHHubCore

@MainActor struct FoodCommitTests {
    private final class Store: FoodEditingStore {
        let local = try! FoodLocalStore(initial: .init(catalog: .init()))
        var failRead = true, failWrite = false
        var writes = 0
        func snapshot() throws -> FoodScreenSnapshot { if failRead { throw FoodFailure.invalidValue }; return try local.snapshot() }
        func enqueue(_ meal: FoodMeal, operationID: String) throws -> String { if failWrite { throw FoodFailure.invalidValue }; writes += 1; return try local.enqueue(meal, operationID: operationID) }
        func saveCatalog(_ catalog: FoodCatalog) throws { if failWrite { throw FoodFailure.invalidValue }; writes += 1; try local.saveCatalog(catalog) }
        func addPreset(_ id: String, date: String, slot: String) throws -> String { try local.addPreset(id,date:date,slot:slot) }
        func edit(_ id: String, factor: Double, date: String?, slot: String?, remove: Bool) throws { try local.edit(id,factor:factor,date:date,slot:slot,remove:remove) }
        func undoAddition(_ operationID: String) throws { try local.undoAddition(operationID) }
    }
    private func draft() throws -> FoodDraft {
        try FoodDraft.fromAnalysisJSON(Data(#"{"items":[{"name":"架空皿","quantity":1,"unit":"皿","kcal":100,"protein_g":10,"fat_g":0,"carbohydrate_g":15,"source":"推定","confidence":"中"}],"uncertain_points":[],"questions":[]}"#.utf8))
    }
    @Test func committedMealRemainsSuccessfulWhenReadbackFails() throws {
        let store = Store(), result = try FoodCommit.confirm(draft(),date:"2026-10-02",slot:"朝食",store:store)
        #expect(result.snapshot == nil); #expect(store.writes == 1)
        #expect(result.meal.id == result.mealID)
        store.failRead = false
        let restored = try store.snapshot()
        #expect(restored.pending.count == 1); #expect(restored.pending[0].id == result.operationID); #expect(restored.pending[0].meal.id == result.mealID)
        let change = try FoodUndoChange(operationID: result.operationID, before: nil, after: result.meal)
        try store.undoChange(change, at: .now)
        #expect(try store.snapshot().pending.isEmpty)
    }
    @Test func actualWriteFailureIsStillReportedAndCreatesNoMeal() throws {
        let store = Store(); store.failWrite = true
        #expect(throws: FoodFailure.invalidValue) { try FoodCommit.confirm(draft(),date:"2026-10-02",slot:"朝食",store:store) }
        #expect(store.writes == 0); store.failRead = false; #expect(try store.snapshot().pending.isEmpty)
    }
    @Test func savedEditSnapshotFailureKeepsBeforeAfterAndOneCompensatingOperation() throws {
        let store=Store(), saved=try FoodCommit.confirm(draft(),date:"2026-10-02",slot:"朝食",store:store)
        _ = try store.local.beginSending(saved.operationID); try store.local.acknowledge(saved.operationID, confirmed: saved.meal)
        let after=try saved.meal.edited(factor: 2, date:"2026-10-03", slot:"夕食")
        let edited=try FoodCommit.enqueueMeal(after, store:store)
        #expect(edited.snapshot == nil); #expect(edited.meal == after)
        let change=try FoodUndoChange(operationID:edited.operationID,before:saved.meal,after:edited.meal)
        try store.local.undoChange(change)
        #expect(store.local.state.pending.isEmpty); #expect(store.local.state.confirmed == [saved.meal])
        #expect(store.writes == 2)
    }
    @Test func catalogCommitDoesNotBecomeFailureAfterSave() throws {
        let store = Store(), category = try FoodCategory(name:"架空の分類")
        let catalog = try FoodCatalog(categories:[category])
        #expect(try FoodCommit.saveCatalog(catalog,store:store) == nil); #expect(store.writes == 1)
        store.failRead = false; #expect(try store.snapshot().catalog.categories == [category])
    }
}
