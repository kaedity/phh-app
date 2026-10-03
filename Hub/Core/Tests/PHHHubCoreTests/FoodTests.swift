import Foundation
import Testing
@testable import PHHHubCore

struct FoodTests {
    func nutrients(_ kcal:Double=100, protein:Double?=10) throws -> FoodNutrients {try .init(kcal:kcal,protein:protein,fat:0,carbohydrate:15)}
    func food(_ kcal:Double=100,foodID:String=UUID().uuidString,revision:Int=1) throws -> FoodVersion {try .init(foodID:foodID,revision:revision,name:"架空パン",unit:"個",source:"商品表示",nutrients:nutrients(kcal))}
    @Test func recipeSnapshotsKeepTheExactFoodVersionsAfterPresetChanges() throws {
        let v=try food(),category=try FoodCategory(name:"朝の定番"),p=try FoodPreset(name:"架空セット",categoryID:category.id,components:[.init(versionID:v.id,factor:2)]);var catalog=try FoodCatalog(versions:[v],categories:[category],presets:[p])
        let meal=try FoodMeal(date:"2026-10-02",slot:"朝食",items:catalog.snapshot(p.id),presetID:p.id,presetRevision:p.revision)
        let next=try food(120,foodID:v.foodID,revision:2);try catalog.add(next);try catalog.save(.init(id:p.id,revision:2,name:p.name,categoryID:category.id,components:[.init(versionID:next.id)]))
        #expect(meal.items[0].nutrients.kcal==200);#expect(meal.items[0].versionID==v.id);#expect(meal.presetRevision==1);#expect(try catalog.snapshot(p.id)[0].nutrients.kcal==120)
        var hidden=category;hidden.archived=true;try catalog.save(hidden);#expect(catalog.visiblePresets().isEmpty);#expect(FoodTotal.day("2026-10-02",meals:[meal]).known[.kcal]==200)
    }
    @Test func quantityDateSlotAndRemovalUseRecordedSnapshotOnly() throws {
        let v=try food(),item=try FoodItemSnapshot(name:v.name,quantity:1,unit:"個",source:v.source,versionID:v.id,nutrients:v.nutrients),first=try FoodMeal(date:"2026-10-02",slot:"朝食",items:[item])
        let twice=try first.edited(factor:2),half=try twice.edited(factor:0.5,date:"2026-10-03",slot:"間食")
        #expect(twice.items[0].quantity==2);#expect(twice.items[0].nutrients.kcal==200);#expect(half.items[0].quantity==1);#expect(half.items[0].nutrients.kcal==100);#expect(half.slot=="間食")
        #expect(FoodTotal.day("2026-10-02",meals:[half]).known[.kcal]==0);#expect(FoodTotal.day("2026-10-03",meals:[half]).known[.kcal]==100)
        let removed=try half.edited(remove:true);#expect(FoodTotal.day("2026-10-03",meals:[removed]).known[.kcal]==0);#expect(removed.id==first.id);#expect(removed.revision==4)
    }
    @Test func partialNutrientsAreNotReportedAsCompleteZeros() throws {
        let a=try FoodItemSnapshot(name:"架空A",quantity:1,unit:"個",source:"推定",nutrients:nutrients()),b=try FoodItemSnapshot(name:"架空B",quantity:1,unit:"個",source:"推定",nutrients:.init(kcal:nil,protein:nil,fat:0,carbohydrate:nil)),total=FoodTotal(items:[a,b])
        #expect(total.known[.kcal]==100);#expect(total.missing[.kcal]==1);#expect(total.known[.fat]==0);#expect(total.missing[.fat]==0);#expect(total.missing[.protein]==1)
    }
    @Test func draftDoesNotEnterTotalsAndRequiresQuestionResolution() throws {
        let i=try FoodItemSnapshot(name:"架空推定",quantity:1,unit:"皿",source:"推定",confidence:"低",nutrients:nutrients());var draft=FoodDraft(items:[i],uncertainty:["量が不明"],questions:["実際の量は？"])
        #expect(FoodTotal.day("2026-10-02",meals:[]).known[.kcal]==0);#expect(throws:FoodFailure.unresolvedQuestions){try draft.confirm(date:"2026-10-02",slot:"昼食")}
        draft.answers["実際の量は？"]="1皿";let meal=try draft.confirm(date:"2026-10-02",slot:"昼食");#expect(FoodTotal.day("2026-10-02",meals:[meal]).known[.kcal]==100)
    }
    @Test func invalidAndTamperedDecodedValuesFailValidation() throws {
        #expect(throws:FoodFailure.invalidValue){try FoodNutrients(kcal:.infinity,protein:0,fat:0,carbohydrate:0)}
        #expect(throws:FoodFailure.invalidValue){try FoodRules.date("2026-02-30")};#expect(throws:FoodFailure.invalidValue){try nutrients().scaled(0)}
        let v=try food();var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(v)) as! [String:Any];json["quantity"] = -1
        let decoded=try JSONDecoder().decode(FoodVersion.self,from:JSONSerialization.data(withJSONObject:json));#expect(throws:FoodFailure.invalidValue){try decoded.validate()}
        var catalog=try FoodCatalog(versions:[v]);#expect(throws:FoodFailure.missingReference){try catalog.save(.init(name:"壊れた参照",components:[.init(versionID:UUID().uuidString)]))};#expect(catalog.presets.isEmpty)
    }
    @Test func immutableVersionAndPresetRevisionCannotBeRewritten() throws {
        let v=try food(),p=try FoodPreset(name:"元",components:[.init(versionID:v.id)]);var catalog=try FoodCatalog(versions:[v],presets:[p]);try catalog.add(v);try catalog.save(p)
        let changed=try FoodVersion(id:v.id,foodID:v.foodID,name:"書き換え",unit:"個",source:"推定",nutrients:nutrients(999))
        #expect(throws:FoodFailure.duplicateID){try catalog.add(changed)};#expect(throws:FoodFailure.revisionConflict){try catalog.save(.init(id:p.id,name:"同版編集",components:p.components))};#expect(catalog.presets[0].name=="元")
    }
}
