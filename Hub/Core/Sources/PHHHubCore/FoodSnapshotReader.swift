import Foundation

/// 正本の行から記録時の明細を読む。現在の食品・プリセットで栄養を再計算しません。
public enum FoodSnapshotReader {
  public static func meals(_ rows: [LocalRow]) throws -> [FoodMeal] {
    for row in rows { try Schema.validate(row) }
    let roots = rows.filter { $0.table == "Meals" }
    guard Set(rows.map(\.id)).count == rows.count else { throw HubError.invalidResponse }
    let rootIDs=Set(roots.map(\.entityID)),children=rows.filter { $0.table=="MealItems" },childIDs=Set(children.map(\.entityID)),nutrients=rows.filter { $0.table=="IntakeNutrients" }
    guard children.allSatisfy({ rootIDs.contains($0.values["meal_id"]?.text ?? "") }),
      nutrients.allSatisfy({childIDs.contains($0.values["item_id"]?.text ?? "")}) else { throw HubError.invalidResponse }
    let childrenByMeal=Dictionary(grouping:children,by:{$0.values["meal_id"]?.text ?? ""})
    let nutrientsByItem=Dictionary(grouping:nutrients,by:{$0.values["item_id"]?.text ?? ""})
    return try roots.map { root in
      func text(_ key: String) throws -> String {
        guard let value = root.values[key]?.text else { throw HubError.invalidResponse }
        return value
      }
      let allChildren = childrenByMeal[root.entityID] ?? []
      let ordered = root.values["food_name"]?.text != nil
      guard !ordered || allChildren.filter({ $0.values["number"]?.number == nil }).allSatisfy({ !$0.active && $0.revision <= root.revision }) else { throw HubError.invalidResponse }
      let children = allChildren.filter { !ordered || $0.values["number"]?.number != nil }.sorted {
        let a=$0.values["number"]?.number,b=$1.values["number"]?.number
        if let a,let b { return a < b }
        return $0.entityID < $1.entityID
      }
      guard !children.isEmpty, children.count <= 50 else { throw HubError.invalidResponse }
      let positions=children.compactMap { $0.values["number"]?.number }
      guard (!ordered && positions.isEmpty) || positions == (1...children.count).map(Double.init) else { throw HubError.invalidResponse }
      let items = try children.map { child -> FoodItemSnapshot in
        guard child.active == root.active, child.revision == root.revision,
          let name=child.values["name"]?.text,let quantity=child.values["quantity"]?.number,
          let unit=child.values["unit"]?.text,let source=child.values["source"]?.text else { throw HubError.invalidResponse }
        let ns=nutrientsByItem[child.entityID] ?? []
        guard ns.count==4,Set(ns.compactMap { $0.values["nutrient_id"]?.text })==Set(["kcal","protein_g","fat_g","carbohydrate_g"]),
          ns.allSatisfy({$0.revision==root.revision && $0.active==root.active}) else { throw HubError.invalidResponse }
        func nutrient(_ key:String) throws -> Double? {
          let row=ns.first {$0.values["nutrient_id"]?.text==key}!
          guard row.values["unit"]?.text == (key=="kcal" ? "kcal":"g") else { throw HubError.invalidResponse }
          let value=row.values["value"]
          if value == .null { guard row.values["value_status"]?.text == "unknown" else { throw HubError.invalidResponse };return nil }
          guard let n=value?.number,["estimated","label","reference"].contains(row.values["value_status"]?.text ?? "") else { throw HubError.invalidResponse };return n
        }
        return try .init(id:child.entityID,name:name,quantity:quantity,unit:unit,
          preparation:child.values["preparation"]?.text ?? "未指定",source:source,
          versionID:child.values["reference_version"]?.text,confidence:child.values["confidence"]?.text,
          nutrients:.init(kcal:nutrient("kcal"),protein:nutrient("protein_g"),fat:nutrient("fat_g"),carbohydrate:nutrient("carbohydrate_g")))
      }
      let presetRevision=root.values["preset_revision"]?.number
      guard presetRevision == nil || presetRevision! <= Double(Int.max) else { throw HubError.invalidResponse }
      return try .init(id:root.entityID,revision:root.revision,date:text("local_date"),slot:text("slot"),items:items,removed:!root.active,
        presetID:root.values["preset_id"]?.text,presetRevision:presetRevision.map(Int.init))
    }
  }
}
