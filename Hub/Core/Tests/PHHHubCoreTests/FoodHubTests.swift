import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct FoodHubTests {
  struct Fixture:Decodable {var page:Delta;let meal:FoodMeal}
  func fixture() throws -> Fixture {
    var root=URL(fileURLWithPath:#filePath);for _ in 0..<4 {root.deleteLastPathComponent()}
    return try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root.appending(path:"Server/food-p4-api-fixture.json")))
  }
  func ready(_ hub:HubStore) throws {var p=Delta(schema_version:1,environment:hubEnvironment,generation:1,snapshot_revision:0,changes:[],next_cursor:0,has_more:false);p.food_contract=1;try hub.apply(p)}
  @Test func gasDeltaRestoresCatalogAndExactRecordedMealThroughCommonStore() throws {
    let f=try fixture(),hub=try HubStore(owner:"synthetic@example.test");try hub.apply(f.page)
    let screen=try FoodHubStore(hub:hub).snapshot()
    #expect(screen.confirmed == [f.meal]);#expect(screen.catalog.versions.count==1);#expect(screen.catalog.presets[0].revision==1)
    #expect(screen.catalog.versions[0].nutrients.carbohydrate==nil);#expect(screen.catalog.versions[0].nutrients.fat==0)
    #expect(screen.pending.isEmpty)
    let queued=try FoodHubStore(hub:hub).addPreset(screen.catalog.presets[0].id,date:"2026-10-03",slot:"朝食")
    #expect(try hub.pending()[0].id==queued);#expect(try hub.pending()[0].operation.foodMeal?.items[0].nutrients.kcal==150)
    #expect(try FoodHubStore(hub:hub).snapshot().confirmed==[f.meal])
  }
  @Test func missingCatalogReferenceOrDuplicateOrdinalRejectsReadback() throws {
    let f=try fixture(),hub=try HubStore(owner:"synthetic@example.test");try hub.apply(f.page);let rows=try hub.rows()
    #expect(throws:HubError.invalidResponse){try FoodCatalogReader.catalog(rows.filter {$0.table != "FoodNutrients"})}
    var bad=rows;let i=bad.firstIndex {$0.table=="PresetItems"}!;bad[i].values["number"] = .number(-1)
    #expect(throws:HubError.invalidResponse){try FoodCatalogReader.catalog(bad)}
  }
  @Test func queuedCatalogSurvivesRestartAndOrdersDependenciesBeforeMeal() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("hub.sqlite")
    var hub:HubStore?=try HubStore(url:url,owner:"synthetic@example.test");try ready(hub!)
    let f=try fixture(),canonical=try HubStore(owner:"synthetic@example.test");try canonical.apply(f.page);let catalog=try FoodCatalogReader.catalog(canonical.rows())
    let food=FoodHubStore(hub:hub!);try food.saveCatalog(catalog);let addition=try food.addPreset(catalog.presets[0].id,date:"2026-10-03",slot:"朝食")
    #expect(try hub!.pending().map(\.operation.action)==["save_food_version","save_food_category","save_food_preset","confirm_food_meal"])
    hub=nil;let reopened=try HubStore(url:url,owner:"synthetic@example.test"),projected=try FoodHubStore(hub:reopened).snapshot()
    #expect(projected.catalog==catalog);#expect(projected.confirmed.isEmpty);#expect(projected.pending.map(\.id)==[addition])
    for pending in try reopened.pending() {let bytes=try JSONEncoder().encode(pending.operation);#expect(try JSONDecoder().decode(HubOperation.self,from:bytes)==pending.operation)}
  }
  @Test func undoDispatchedAdditionSurvivesRestartAndCreatesOneCancellationOnlyAfterReceipt() throws {
    let f=try fixture(),op=try FoodWireOperation(.init(expectedRevision:0,meal:f.meal),environment:hubEnvironment).hubOperation()
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer {try? FileManager.default.removeItem(at:dir)};let url=dir.appendingPathComponent("hub.sqlite")
    var hub:HubStore?=try HubStore(url:url,owner:"synthetic@example.test");try ready(hub!);try hub!.enqueue(op);try hub!.markAttempted(op.id);try hub!.undoFoodAddition(op);hub=nil
    let reopened=try HubStore(url:url,owner:"synthetic@example.test");#expect(try reopened.pending().map(\.id)==[op.id]);#expect(try reopened.foodUndoRequested(op.id))
    let receipt=Receipt(environment:hubEnvironment,operation_id:op.id,status:"committed",entity_ids:[op.entity_id],revisions:[1],retryable:false)
    try reopened.finish(receipt,operation:op);let cancel=try reopened.pending()[0].operation
    #expect(cancel.action=="remove_food_meal");#expect(cancel.entity_id==op.entity_id);#expect(cancel.expected_revision==1);#expect(cancel.foodMeal?.items==f.meal.items)
    try reopened.finish(receipt,operation:op);#expect(try reopened.pending().map(\.id)==[cancel.id])
  }
  @Test func unsentUndoOnlyDeletesTargetAndInvalidBatchIsAtomic() throws {
    let f=try fixture(),hub=try HubStore(owner:"synthetic@example.test");try ready(hub)
    let first=try FoodWireOperation(.init(expectedRevision:0,meal:f.meal),environment:hubEnvironment).hubOperation();var second=first;second.operation_id=UUID().uuidString
    try hub.enqueue(first);try hub.enqueue(second);try hub.undoFoodAddition(first);#expect(try hub.pending().map(\.id)==[second.id])
    var invalid=first;invalid.approval_state="draft";#expect(throws:HubError.invalidOperation){try hub.enqueueBatch([first,invalid])};#expect(try hub.pending().map(\.id)==[second.id])
  }
}
