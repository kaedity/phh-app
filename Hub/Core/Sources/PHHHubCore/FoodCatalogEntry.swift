import Foundation

/// 食品版と食事の写しを残して、カタログの削除・復元だけを同期します。
public struct FoodCatalogEntry: Codable, Equatable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable { case food, preset }
  public let id: String, targetID: String, kind: Kind, revision: Int, deleted: Bool
  public init(id: String = UUID().uuidString, targetID: String, kind: Kind, revision: Int = 1, deleted: Bool) throws {
    self.id=id; self.targetID=targetID; self.kind=kind; self.revision=revision; self.deleted=deleted
    try validate()
  }
  public func validate() throws {
    try FoodRules.id(id); try FoodRules.id(targetID)
    guard revision>0 && revision<9_007_199_254_740_991 else { throw FoodFailure.invalidValue }
  }
  public func changed(deleted: Bool) throws -> Self {
    guard deleted != self.deleted else { throw FoodFailure.invalidValue }
    return try .init(id:id,targetID:targetID,kind:kind,revision:revision+1,deleted:deleted)
  }
}
public extension FoodCatalog {
  var deletedFoodIDs: Set<String> { Set(entries.filter { $0.deleted && $0.kind == .food }.map(\.targetID)) }
  func isDeleted(_ preset: FoodPreset) -> Bool {
    entries.contains { $0.deleted && $0.kind == .preset && $0.targetID == preset.id }
      || preset.components.contains { component in versions.contains { $0.id == component.versionID && deletedFoodIDs.contains($0.foodID) } }
  }
  var availableVersions: [FoodVersion] { versions.filter { !deletedFoodIDs.contains($0.foodID) } }
  mutating func setDeleted(_ kind: FoodCatalogEntry.Kind, targetID: String, deleted: Bool) throws {
    let previous = entries.first { $0.kind==kind && $0.targetID==targetID }
    let next = try previous.map { try $0.changed(deleted:deleted) } ?? FoodCatalogEntry(targetID:targetID,kind:kind,deleted:deleted)
    try save(next)
  }
}
public extension HubOperation {
  init(foodCatalogEntry: FoodCatalogEntry) {
    self.init(action:"save_food_catalog_entry",entityID:foodCatalogEntry.id,revision:foodCatalogEntry.revision-1)
    self.foodCatalogEntry=foodCatalogEntry
  }
}
public enum FoodCatalogEntryRows {
  public static func entries(_ rows: [LocalRow]) throws -> [FoodCatalogEntry] {
    try rows.filter { $0.table=="CatalogEntries" }.map { row in
      try Schema.validate(row)
      guard let target=row.values["target_id"]?.text,let kind=row.values["target_kind"]?.text.flatMap(FoodCatalogEntry.Kind.init(rawValue:)),
        let operation=row.values["last_operation_id"]?.text,UUID(uuidString:operation) != nil else { throw HubError.invalidResponse }
      do { return try .init(id:row.entityID,targetID:target,kind:kind,revision:row.revision,deleted:row.active) }
      catch { throw HubError.invalidResponse }
    }
  }
}
