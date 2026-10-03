import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct FoodCatalogEntryStoreTests {
  func ready(_ hub:HubStore, contract:Int?=1) throws {
    let fixture=try FoodHubTests().fixture();var page=fixture.page
    page.catalog_entry_contract=contract;try hub.apply(page)
  }
  func page(_ entry:FoodCatalogEntry,cursor:Int) -> Delta {
    let values:[String:Cell]=["id":.string(entry.id),"revision":.number(Double(entry.revision)),"status":.string(entry.deleted ? "active":"removed"),"created_at":.string("2026-10-04T00:00:00Z"),"updated_at":.string("2026-10-04T00:00:00Z"),"source_kind":.string("app"),"last_operation_id":.string("00000000-0000-4000-a000-000000000100"),"target_kind":.string(entry.kind.rawValue),"target_id":.string(entry.targetID)]
    return .init(schema_version:1,environment:hubEnvironment,generation:1,catalog_entry_contract:1,food_contract:1,snapshot_revision:cursor+1,changes:[.init(change:.init(change_number:cursor+1,table_name:"CatalogEntries",entity_id:entry.id,revision:entry.revision,indexed_revision:entry.revision,removed:!entry.deleted,local_date:nil),record:values)],next_cursor:cursor+1,has_more:false)
  }
  @Test func deletionAndRestoreSurviveRestartOutboxAndReadbackWithoutChangingMeal() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),url=dir.appendingPathComponent("hub.sqlite")
    defer{try? FileManager.default.removeItem(at:dir)}
    var hub:HubStore?=try HubStore(url:url,owner:"synthetic@example.test");try ready(hub!)
    let food=FoodHubStore(hub:hub!),before=try food.snapshot(),target=try #require(before.catalog.versions.first)
    var catalog=before.catalog;try catalog.setDeleted(.food,targetID:target.foodID,deleted:true);try food.saveCatalog(catalog);try food.saveCatalog(catalog)
    #expect(try hub!.pending().count==1);#expect(try food.snapshot().catalog.availableVersions.isEmpty)
    let op=try #require(hub!.pending().first?.operation),cursor=try hub!.cursor;hub=nil
    let reopened=try HubStore(url:url,owner:"synthetic@example.test"),store=FoodHubStore(hub:reopened)
    #expect(try store.snapshot().catalog.visiblePresets().isEmpty)
    let entry=try #require(op.foodCatalogEntry);try reopened.apply(page(entry,cursor:cursor))
    let receipt=Receipt(environment:hubEnvironment,operation_id:op.id,status:"committed",entity_ids:[op.entity_id],revisions:[1],retryable:false)
    try reopened.finish(receipt,operation:op);#expect(try reopened.pending().isEmpty)
    catalog=try store.snapshot().catalog;try catalog.setDeleted(.food,targetID:target.foodID,deleted:false);try store.saveCatalog(catalog)
    #expect(try reopened.pending().first?.operation.expected_revision==1)
    #expect(try store.snapshot().catalog.availableVersions==before.catalog.versions)
    #expect(try store.snapshot().confirmed==before.confirmed)
  }
  @Test func unsupportedServerAndMalformedReadbackLeaveRecordsAndCursorUnchanged() throws {
    let hub=try HubStore(owner:"synthetic@example.test");try ready(hub,contract:nil)
    let store=FoodHubStore(hub:hub),before=try store.snapshot(),target=try #require(before.catalog.versions.first)
    var catalog=before.catalog;try catalog.setDeleted(.food,targetID:target.foodID,deleted:true)
    #expect(throws:HubError.configuration){try store.saveCatalog(catalog)}
    #expect(try hub.pending().isEmpty);let cursor=try hub.cursor,entry=try #require(catalog.entries.first)
    var malformed=page(entry,cursor:cursor);malformed.changes[0].record["target_kind"] = .string("unknown")
    #expect(throws:HubError.invalidResponse){try hub.apply(malformed)}
    #expect(try hub.cursor==cursor);#expect(try store.snapshot().catalog==before.catalog)
  }
}
