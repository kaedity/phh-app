import Foundation
import Testing
@testable import PHHHubCore

struct FoodWireTests {
    func fixture() throws -> FoodWireOperation {
        var root=URL(fileURLWithPath:#filePath);for _ in 0..<4{root.deleteLastPathComponent()}
        return try JSONDecoder().decode(FoodWireOperation.self,from:Data(contentsOf:root.appending(path:"Server/food-p4-fixture.json")))
    }
    @Test func serverFixtureAndPersistedPendingHaveExactSameWirePayload() throws {
        let wire=try fixture();try wire.validate();let op=try FoodPendingOperation(id:wire.operation_id,expectedRevision:0,meal:wire.payload),encoded=try FoodWireOperation(op,environment:wire.environment)
        #expect(encoded==wire);#expect(try JSONDecoder().decode(FoodWireOperation.self,from:JSONEncoder().encode(encoded))==wire)
        #expect(FoodTotal(items:wire.payload.items).known[.kcal]==100);#expect(FoodTotal(items:wire.payload.items).missing[.kcal]==1)
    }
    @Test func updateAndRemovalKeepSameEntityAndRequireNextVersion() throws {
        let wire=try fixture(),meal=try wire.payload.edited(factor:2,date:"2026-10-03",slot:"間食"),changed=try FoodWireOperation(.init(expectedRevision:1,meal:meal),environment:wire.environment)
        try changed.validate();#expect(changed.action=="update_food_meal");#expect(changed.entity_id==wire.entity_id);#expect(changed.expected_revision==1)
        let removal=try FoodWireOperation(.init(expectedRevision:2,meal:meal.edited(remove:true)),environment:wire.environment);try removal.validate();#expect(removal.action=="remove_food_meal")
    }
    @Test func decodedDraftAndInvalidVersionAreRejectedAtWireBoundary() throws {
        let wire=try fixture();var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(wire)) as! [String:Any]
        for (key,value) in [("approval_state","draft" as Any),("expected_revision",4 as Any),("action","confirm_meal" as Any)] {var bad=json;bad[key]=value;let decoded=try JSONDecoder().decode(FoodWireOperation.self,from:JSONSerialization.data(withJSONObject:bad));#expect(throws:FoodFailure.invalidValue){try decoded.validate()}}
        json["environment"]="other";let bad=try JSONDecoder().decode(FoodWireOperation.self,from:JSONSerialization.data(withJSONObject:json));#expect(throws:FoodFailure.invalidValue){try bad.validate()}
    }
    @Test @MainActor func commonOutboxKeepsSnapshotAndOperationIDAcrossDatabaseRestart() throws {
        let base=try fixture(), wire=try FoodWireOperation(.init(id:base.operation_id,expectedRevision:0,meal:base.payload),environment:hubEnvironment)
        let op=try wire.hubOperation();#expect(op.id==wire.operation_id);#expect(op.foodMeal==wire.payload)
        #expect(try JSONDecoder().decode(HubOperation.self,from:JSONEncoder().encode(op))==op)
        let url=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString).appending(path:"hub.sqlite")
        defer { try? FileManager.default.removeItem(at:url.deletingLastPathComponent()) }
        var store:HubStore?=try HubStore(url:url,owner:"synthetic@example.test")
        #expect(throws:HubError.configuration){try store!.enqueue(wire)}
        var page=Delta(schema_version:1,environment:hubEnvironment,generation:1,snapshot_revision:0,changes:[],next_cursor:0,has_more:false);page.food_contract=1
        try store!.apply(page);try store!.enqueue(wire);try store!.enqueue(wire);store=nil
        let reopened=try HubStore(url:url,owner:"synthetic@example.test")
        #expect(try reopened.pending().count==1);#expect(try reopened.pending()[0].operation==op);#expect(try reopened.foodContract==1)
        let receipt=Receipt(environment:hubEnvironment,operation_id:op.id,status:"committed",entity_ids:[op.entity_id],revisions:[1],retryable:false)
        try reopened.finish(receipt,operation:op);#expect(try reopened.pending().isEmpty)
    }
    @Test @MainActor func unsupportedAPIRetainsExistingFoodQueueWithoutSending() async throws {
        let base=try fixture(),wire=try FoodWireOperation(.init(id:base.operation_id,expectedRevision:0,meal:base.payload),environment:hubEnvironment),store=try HubStore(owner:"synthetic@example.test")
        var page=Delta(schema_version:1,environment:hubEnvironment,generation:1,snapshot_revision:0,changes:[],next_cursor:0,has_more:false);page.food_contract=1
        try store.apply(page);try store.enqueue(wire);page.food_contract=nil;try store.apply(page)
        let transport=FoodContractTransport();await SyncEngine(store:store,transport:transport).synchronize(date:"2026-10-02")
        #expect(transport.submissions==0);#expect(try store.pending().count==1);#expect(try store.pending()[0].state == .queued)
    }

}

@MainActor private final class FoodContractTransport: HubTransport {
    var connected=true;var submissions=0
    func result(_ operation:HubOperation) async throws -> Receipt { submissions += 1;throw HubError.configuration }
    func submit(_ operation:HubOperation) async throws -> Receipt { submissions += 1;throw HubError.configuration }
    func processIntake(date:String) async throws {}
    func delta(_ query:HubQuery) async throws -> Delta { Delta(schema_version:1,environment:hubEnvironment,generation:1,snapshot_revision:0,changes:[],next_cursor:0,has_more:false) }
}
    @Test @MainActor func nullableSchemaUpgradePersistsNewColumnsWithoutChangingRevisionOrQueue() throws {
        let f=try HubCoreTests().fixture(),store=try HubStore(owner:"synthetic@example.test")
        try store.apply(f.initial);try store.enqueue(f.operation)
        let prior=try store.rows(table:"Meals")[0]
        var upgraded=prior.values;for key in ["food_name","food_quantity","food_unit","preset_id","preset_revision"] { upgraded[key] = .null }
        let next=try store.cursor+1
        let change=Change(change_number:next,table_name:"Meals",entity_id:prior.entityID,revision:prior.revision,indexed_revision:prior.revision,removed:false,local_date:prior.values["local_date"]?.text)
        var page=Delta(schema_version:1,environment:hubEnvironment,generation:1,snapshot_revision:next,changes:[.init(change:change,record:upgraded)],next_cursor:next,has_more:false)
        #expect(throws:HubError.invalidResponse){try store.apply(page)}
        #expect(try store.cursor==next-1)
        page.food_contract=1;try store.apply(page)
        let after=try store.rows(table:"Meals")[0]
        #expect(after.values==upgraded);#expect(after.revision==prior.revision);#expect(try store.pending().map(\.id)==[f.operation.id])
        var forged=upgraded;forged["preset_id"] = .string(UUID().uuidString)
        #expect(!Schema.sameRecordDuringP3Upgrade(table:"Meals",old:prior.values,new:forged))
    }


@Suite @MainActor struct FoodSnapshotReaderTests {
  @Test func legacyCommittedRowsReadWithoutLookingUpCurrentPreset() throws {
    let f=try HubCoreTests().fixture(),store=try HubStore(owner:"synthetic@example.test")
    try store.apply(f.latest)
    let meals=try FoodSnapshotReader.meals(store.rows())
    #expect(meals.count==1);#expect(meals[0].revision==2)
    #expect(FoodTotal(items:meals[0].items).known[.kcal]==200)
    #expect(meals[0].items[0].nutrients.fat==0)
    #expect(meals[0].items[0].versionID==nil)
  }
  @Test func missingDuplicateOrMismatchedNutrientCannotBecomeConfirmedFood() throws {
    let f=try HubCoreTests().fixture(),store=try HubStore(owner:"synthetic@example.test");try store.apply(f.initial)
    let rows=try store.rows(),idx=rows.firstIndex {$0.table=="IntakeNutrients"}!
    var missing=rows;missing.remove(at:idx);#expect(throws:HubError.invalidResponse){try FoodSnapshotReader.meals(missing)}
    var duplicate=rows;duplicate.append(rows[idx]);#expect(throws:HubError.invalidResponse){try FoodSnapshotReader.meals(duplicate)}
    var bad=rows;bad[idx].values["revision"] = .number(2);#expect(throws:HubError.invalidResponse){try FoodSnapshotReader.meals(bad)}
    bad=rows;bad[idx].values["unit"] = .string("kg");#expect(throws:HubError.invalidResponse){try FoodSnapshotReader.meals(bad)}
  }
  @Test func multipleRecordedItemsKeepKnownSubtotalMissingAndZeroSeparate() throws {
    let f=try HubCoreTests().fixture(),store=try HubStore(owner:"synthetic@example.test");try store.apply(f.initial)
    var rows=try store.rows();let old=rows.first {$0.table=="MealItems"}!,id=UUID().uuidString
    var second=old;second.values["id"] = .string(id);second.values["name"] = .string("架空の未設定食品");rows.append(second)
    for n in rows.filter({$0.table=="IntakeNutrients" && $0.values["item_id"]?.text==old.entityID}) {
      var copy=n;copy.values["id"] = .string(UUID().uuidString);copy.values["item_id"] = .string(id);copy.values["value"] = .null;copy.values["value_status"] = .string("unknown");rows.append(copy)
    }
    let meals=try FoodSnapshotReader.meals(rows),total=FoodTotal(items:meals[0].items)
    #expect(meals[0].items.count==2);#expect(total.known[.kcal]==100);#expect(total.missing[.kcal]==1)
    #expect(total.known[.fat]==0);#expect(total.missing[.fat]==1)
    var orphan=second;orphan.values["meal_id"] = .string(UUID().uuidString);rows[rows.firstIndex{$0.entityID==id}!] = orphan
    #expect(throws:HubError.invalidResponse){try FoodSnapshotReader.meals(rows)}
  }

  @Test func gasRowPlanRestoresExactConfirmedSnapshotIncludingItemOrder() throws {
    struct Row:Decodable { let table:String,record:[String:Cell] }
    var root=URL(fileURLWithPath:#filePath);for _ in 0..<4 {root.deleteLastPathComponent()}
    let bytes=try Data(contentsOf:root.appending(path:"Server/food-p4-rows-fixture.json"))
    let rows=try JSONDecoder().decode([Row].self,from:bytes).map {LocalRow(table:$0.table,values:$0.record)}
    let snapshot=try FoodSnapshotReader.meals(rows),wire=try FoodWireTests().fixture()
    #expect(snapshot == [wire.payload])
    var bad=rows;let idx=bad.firstIndex {$0.table=="MealItems"}!
    bad[idx].values["number"] = .number(2)
    #expect(throws:HubError.invalidResponse){try FoodSnapshotReader.meals(bad)}
  }

  @Test func retiredOrderedItemIsExcludedAndCorruptMembershipRejected() throws {
    struct Row:Decodable { let table:String,record:[String:Cell] }
    var root=URL(fileURLWithPath:#filePath);for _ in 0..<4 {root.deleteLastPathComponent()}
    var rows=try JSONDecoder().decode([Row].self,from:Data(contentsOf:root.appending(path:"Server/food-p4-rows-fixture.json"))).map {LocalRow(table:$0.table,values:$0.record)}
    let retired=rows.first {$0.table=="MealItems" && $0.values["number"]?.number==2}!.entityID
    for i in rows.indices {
      let tombstone=rows[i].entityID==retired || rows[i].values["item_id"]?.text==retired
      rows[i].values["revision"] = .number(2)
      if tombstone { rows[i].values["status"] = .string("removed") }
      if rows[i].entityID==retired { rows[i].values["number"] = .null }
    }
    let meal=try FoodSnapshotReader.meals(rows)[0]
    #expect(meal.revision==2);#expect(meal.items.count==1);#expect(!meal.removed)
    let idx=rows.firstIndex {$0.entityID==retired}!
    rows[idx].values["status"] = .string("active")
    #expect(throws:HubError.invalidResponse){try FoodSnapshotReader.meals(rows)}
  }

}
