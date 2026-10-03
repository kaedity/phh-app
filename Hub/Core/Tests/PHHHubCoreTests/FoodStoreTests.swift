import Foundation
import Testing
@testable import PHHHubCore

@MainActor struct FoodStoreTests {
    func initial() throws -> FoodLocalState {let food=try FoodVersion(name:"架空",unit:"個",source:"商品表示",nutrients:.init(kcal:100,protein:10,fat:0,carbohydrate:15)),preset=try FoodPreset(name:"架空",components:[.init(versionID:food.id)]);return try .init(catalog:.init(versions:[food],presets:[preset]))}
    @Test func intentionalSecondTapIsSeparateButRetryIDIsNot() throws {
        let store=try FoodLocalStore(initial:initial()),id=store.state.catalog.presets[0].id
        let first=try store.addPreset(id,date:"2026-10-02",slot:"朝食"),candidate=store.state.pending[0].meal;try store.enqueue(candidate,operationID:first)
        try store.addPreset(id,date:"2026-10-02",slot:"朝食");#expect(store.state.pending.count==2);#expect(store.state.confirmed.isEmpty);#expect(Set(store.state.pending.map{$0.meal.id}).count==2)
    }
    @Test func restartPreservesSnapshotAttemptAndOperationID() throws {
        let url=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString+".json");defer{try? FileManager.default.removeItem(at:url)}
        let initial=try initial(),store=try FoodLocalStore(url:url,initial:initial),id=try store.addPreset(initial.catalog.presets[0].id,date:"2026-10-02",slot:"朝食"),sending=try store.beginSending(id)
        let reopened=try FoodLocalStore(url:url,initial:initial);#expect(reopened.state.pending[0].id==id);#expect(reopened.state.pending[0].state == .queued);#expect(reopened.state.pending[0].attempted);#expect(reopened.state.pending[0].meal==sending.meal)
        try reopened.undoAddition(id);#expect(reopened.state.pending[0].undoRequested);try reopened.beginSending(id);try reopened.acknowledge(id,confirmed:sending.meal)
        #expect(reopened.state.confirmed[0].revision==1);#expect(reopened.state.pending.count==1);#expect(reopened.state.pending[0].expectedRevision==1);#expect(reopened.state.pending[0].meal.removed)
    }
    @Test func undoUnsentAdditionDoesNotCancelAnotherMeal() throws {
        let store=try FoodLocalStore(initial:initial()),p=store.state.catalog.presets[0].id,a=try store.addPreset(p,date:"2026-10-02",slot:"朝食"),b=try store.addPreset(p,date:"2026-10-02",slot:"朝食")
        try store.undoAddition(a);#expect(store.state.pending.map(\.id)==[b]);#expect(store.state.confirmed.isEmpty)
    }
    @Test func exactReceiptAndRevisionRequiredAndConflictDoesNotOverwrite() throws {
        let store=try FoodLocalStore(initial:initial()),id=try store.addPreset(store.state.catalog.presets[0].id,date:"2026-10-02",slot:"朝食"),op=try store.beginSending(id)
        #expect(throws:FoodFailure.invalidReceipt){try store.acknowledge(id,confirmed:op.meal.edited(factor:2))};#expect(store.state.confirmed.isEmpty);#expect(store.state.pending.count==1)
        try store.acknowledge(id,confirmed:op.meal);try store.acknowledge(id,confirmed:op.meal);#expect(store.state.confirmed.count==1);try store.edit(op.meal.id,factor:2)
        #expect(throws:FoodFailure.pendingEdit){try store.edit(op.meal.id,factor:3)};let pending=store.state.pending[0];try store.reject(pending.id,reason:"REVISION_CONFLICT")
        #expect(store.state.confirmed[0].items[0].nutrients.kcal==100);#expect(store.state.pending[0].state == .needsReview);#expect(throws:FoodFailure.invalidValue){try store.retry(pending.id)}
        try store.discardRejected(pending.id);#expect(store.state.pending.isEmpty);#expect(store.state.confirmed[0].revision==1)
    }
    @Test func invalidPersistedStateIsNotOverwrittenWithEmptyFallback() throws {
        let url=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString+".json");defer{try? FileManager.default.removeItem(at:url)};let bytes=Data("broken".utf8);try bytes.write(to:url)
        #expect(throws:(any Error).self){try FoodLocalStore(url:url,initial:initial())};#expect(try Data(contentsOf:url)==bytes)
    }
}
