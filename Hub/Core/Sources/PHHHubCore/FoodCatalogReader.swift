import Foundation

public enum FoodCatalogReader {
  public static func catalog(_ rows:[LocalRow]) throws -> FoodCatalog {
    let rows=rows.filter { ["FoodVersions","FoodNutrients","Categories","Presets","PresetItems"].contains($0.table) }
    for row in rows { try Schema.validate(row) }
    guard Set(rows.map(\.id)).count==rows.count else { throw HubError.invalidResponse }
    let roots=rows.filter {$0.table=="FoodVersions"},nutrients=rows.filter {$0.table=="FoodNutrients"},presets=rows.filter {$0.table=="Presets"},components=rows.filter {$0.table=="PresetItems"}
    let versionIDs = Set(roots.map(\.entityID)), presetIDs = Set(presets.map(\.entityID))
    guard nutrients.allSatisfy({ versionIDs.contains($0.values["food_version_id"]?.text ?? "") }),
      components.allSatisfy({ presetIDs.contains($0.values["preset_id"]?.text ?? "") }) else { throw HubError.invalidResponse }
    let nutrientsByVersion = Dictionary(grouping: nutrients, by: { $0.values["food_version_id"]?.text ?? "" })
    let componentsByPreset = Dictionary(grouping: components, by: { $0.values["preset_id"]?.text ?? "" })
    let versions=try roots.map { root -> FoodVersion in
      let ns = nutrientsByVersion[root.entityID] ?? []
      guard root.active,root.revision==1,ns.count==4,Set(ns.compactMap {$0.values["nutrient_id"]?.text})==Set(["kcal","protein_g","fat_g","carbohydrate_g"]),ns.allSatisfy({$0.active && $0.revision==root.revision}) else { throw HubError.invalidResponse }
      func value(_ key:String) throws -> Double? {
        let n=ns.first {$0.values["nutrient_id"]?.text==key}!
        guard n.values["unit"]?.text==(key=="kcal" ? "kcal":"g") else { throw HubError.invalidResponse }
        return n.values["value"]?.number
      }
      return try .init(id:root.entityID,foodID:root.foodText("food_id"),revision:root.foodInteger("food_revision"),name:root.foodText("name"),quantity:root.foodNumber("quantity"),unit:root.foodText("unit"),preparation:root.foodText("preparation"),source:root.foodText("source"),nutrients:.init(kcal:value("kcal"),protein:value("protein_g"),fat:value("fat_g"),carbohydrate:value("carbohydrate_g")))
    }
    let categories=try rows.filter {$0.table=="Categories"}.map {try FoodCategory(id:$0.entityID,name:$0.foodText("name"),archived:!$0.active)}
    let ps=try presets.map { root -> FoodPreset in
      let all = componentsByPreset[root.entityID] ?? [],cs=all.filter {($0.values["number"]?.number ?? 0)>0}.sorted {($0.values["number"]?.number ?? 0)<($1.values["number"]?.number ?? 0)}
      guard all.allSatisfy({($0.values["number"]?.number ?? -1)>=0}),!cs.isEmpty,cs.count<=50,Set(cs.compactMap {$0.values["food_version_id"]?.text}).count==cs.count,cs.enumerated().allSatisfy({i,r in r.values["number"]?.number==Double(i+1) && r.revision==root.revision && r.active==root.active}),all.filter({$0.values["number"]?.number==0}).allSatisfy({!$0.active && $0.revision<=root.revision}) else { throw HubError.invalidResponse }
      return try .init(id:root.entityID,revision:root.revision,name:root.foodText("name"),categoryID:root.values["category_id"]?.text,components:cs.map {try .init(versionID:$0.foodText("food_version_id"),factor:$0.foodNumber("factor"))},archived:!root.active)
    }
    do { return try .init(versions:versions,categories:categories,presets:ps) } catch { throw HubError.invalidResponse }
  }
}
private extension LocalRow {
  func foodText(_ key:String) throws -> String { guard let v=values[key]?.text else { throw HubError.invalidResponse };return v }
  func foodNumber(_ key:String) throws -> Double { guard let v=values[key]?.number else { throw HubError.invalidResponse };return v }
  func foodInteger(_ key:String) throws -> Int { let v=try foodNumber(key);guard v>0,v.rounded()==v,v<=9_007_199_254_740_991 else { throw HubError.invalidResponse };return Int(v) }
}
