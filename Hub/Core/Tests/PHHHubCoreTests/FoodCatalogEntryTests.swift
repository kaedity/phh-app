import Foundation
import Testing
@testable import PHHHubCore

@Suite struct FoodCatalogEntryTests {
  func fixture() throws -> (FoodCatalog,FoodVersion,FoodPreset) {
    let v=try FoodVersion(name:"架空の食品",unit:"個",source:"商品表示",nutrients:.init(kcal:100,protein:10,fat:0,carbohydrate:15))
    let p=try FoodPreset(name:"架空のプリセット",components:[.init(versionID:v.id,factor:1)])
    return (try FoodCatalog(versions:[v],presets:[p]),v,p)
  }
  @Test func deleteFoodHidesDependentPresetWithoutChangingRecordedMeal() throws {
    var (catalog,v,p)=try fixture()
    let items=try catalog.snapshot(p.id),meal=try FoodMeal(date:"2026-10-04",slot:"朝食",items:items)
    try catalog.setDeleted(.food,targetID:v.foodID,deleted:true)
    #expect(catalog.availableVersions.isEmpty && catalog.visiblePresets().isEmpty)
    #expect(catalog.versions == [v] && catalog.presets == [p])
    #expect(FoodTotal(items:meal.items).known[.kcal] == 100)
    #expect(throws:FoodFailure.self) {try catalog.snapshot(p.id)}
    try catalog.setDeleted(.food,targetID:v.foodID,deleted:false)
    #expect(catalog.availableVersions == [v] && catalog.visiblePresets() == [p])
    #expect(catalog.entries.first?.revision == 2)
  }
  @Test func deletePresetIsDifferentFromArchiveAndRestorationKeepsArchive() throws {
    var (catalog,_,p)=try fixture();p=try FoodPreset(id:p.id,revision:2,name:p.name,components:p.components,archived:true);try catalog.save(p)
    try catalog.setDeleted(.preset,targetID:p.id,deleted:true)
    #expect(catalog.isDeleted(p));try catalog.setDeleted(.preset,targetID:p.id,deleted:false)
    #expect(!catalog.isDeleted(p));#expect(catalog.visiblePresets().isEmpty)
  }
  @Test func oldJSONWithoutEntriesLoadsAndNewJSONRetainsDeletion() throws {
    var (catalog,v,_)=try fixture();var value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(catalog)) as! [String:Any]
    value.removeValue(forKey:"entries")
    let old=try JSONDecoder().decode(FoodCatalog.self,from:JSONSerialization.data(withJSONObject:value))
    #expect(old.entries.isEmpty)
    try catalog.setDeleted(.food,targetID:v.foodID,deleted:true)
    #expect(try JSONDecoder().decode(FoodCatalog.self,from:JSONEncoder().encode(catalog)) == catalog)
  }
  @Test func missingTargetsDuplicateTargetsAndRetargetingReject() throws {
    var (catalog,v,p)=try fixture();let e=try FoodCatalogEntry(targetID:v.foodID,kind:.food,deleted:true)
    try catalog.save(e)
    #expect(throws:FoodFailure.self) {try catalog.save(FoodCatalogEntry(targetID:v.foodID,kind:.food,deleted:true))}
    #expect(throws:FoodFailure.self) {try catalog.save(FoodCatalogEntry(targetID:UUID().uuidString,kind:.food,deleted:true))}
    #expect(throws:FoodFailure.self) {try catalog.save(FoodCatalogEntry(id:e.id,targetID:p.id,kind:.preset,revision:2,deleted:true))}
  }
  @Test func wireRoundtripAndCrossPayloadReject() throws {
    let (_,v,_)=try fixture();let entry=try FoodCatalogEntry(targetID:v.foodID,kind:.food,deleted:true)
    let op=HubOperation(foodCatalogEntry:entry);try op.validate()
    #expect(try JSONDecoder().decode(HubOperation.self,from:JSONEncoder().encode(op)) == op)
    var bad=op;bad.payload=SyntheticMeal(date:"2026-10-04")
    #expect(throws:HubError.self) {try bad.validate()}
  }
}
