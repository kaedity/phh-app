import Foundation

public struct FoodScreenSnapshot: Equatable, Sendable {
  public var catalog:FoodCatalog,confirmed:[FoodMeal],pending:[FoodPendingOperation]
  public var catalogPendingCount:Int
  public init(catalog:FoodCatalog,confirmed:[FoodMeal],pending:[FoodPendingOperation],catalogPendingCount:Int=0) {self.catalog=catalog;self.confirmed=confirmed;self.pending=pending;self.catalogPendingCount=catalogPendingCount}
}
@MainActor public protocol FoodEditingStore: AnyObject {
  func snapshot() throws -> FoodScreenSnapshot
  @discardableResult func addPreset(_ id:String,date:String,slot:String) throws -> String
  @discardableResult func enqueue(_ meal:FoodMeal,operationID:String) throws -> String
  func edit(_ id:String,factor:Double,date:String?,slot:String?,remove:Bool) throws
  func saveCatalog(_ catalog:FoodCatalog) throws
  func undoAddition(_ operationID:String) throws
}
extension FoodLocalStore: FoodEditingStore {
  public func snapshot() throws -> FoodScreenSnapshot {.init(catalog:state.catalog,confirmed:state.confirmed,pending:state.pending)}
}
/// 共通CoreData/Outboxを唯一の端末正本として使う製品接続。プレビューJSONとは分離。
@MainActor public final class FoodHubStore: FoodEditingStore {
  private let hub:HubStore
  private var additions:[String:HubOperation]=[:]
  public init(hub:HubStore) {self.hub=hub}
  public func snapshot() throws -> FoodScreenSnapshot {
    let rows=try ["FoodVersions","FoodNutrients","Categories","Presets","PresetItems","Meals","MealItems","IntakeNutrients"].flatMap {try hub.rows(table:$0)},outbox=try hub.pending()
    var catalog=try FoodCatalogReader.catalog(rows)
    // 未送信カタログも同じOutbox順で投影し、関連操作を同じID/版で後続へ渡します。
    for queued in outbox {
      let op=queued.operation
      if let v=op.foodVersion {try catalog.add(v)}
      if let c=op.foodCategory {try catalog.save(c)}
      if let p=op.foodPreset {
        if catalog.presets.first(where:{$0.id==p.id}) != p {try catalog.save(p)}
      }
    }
    let meals=try FoodSnapshotReader.meals(rows)
    let pending=try outbox.compactMap { entry -> FoodPendingOperation? in
      guard let meal=entry.operation.foodMeal else {return nil}
      var op=try FoodPendingOperation(id:entry.id,expectedRevision:entry.operation.expected_revision,meal:meal)
      op.undoRequested=try hub.foodUndoRequested(entry.id);op.attempted=entry.attempts>0;op.error=entry.state == .queued ? nil:entry.message
      if entry.state == .conflict || entry.state == .invalid {op.state = .needsReview}
      return op
    }
    return .init(catalog:catalog,confirmed:meals,pending:pending,catalogPendingCount:outbox.filter {$0.operation.requiresFoodContract && $0.operation.foodMeal == nil}.count)
  }
  @discardableResult public func enqueue(_ meal:FoodMeal,operationID:String) throws -> String {
    guard try hub.pending().allSatisfy({$0.operation.entity_id != meal.id || $0.id==operationID}) else {throw FoodFailure.pendingEdit}
    let wire=try FoodWireOperation(.init(id:operationID,expectedRevision:meal.revision-1,meal:meal),environment:hubEnvironment),op=try wire.hubOperation()
    try hub.enqueue(op);if meal.revision==1 {additions[op.id]=op};return op.id
  }
  @discardableResult public func addPreset(_ id:String,date:String,slot:String) throws -> String {
    let catalog=try snapshot().catalog
    guard let p=catalog.presets.first(where:{$0.id==id && !$0.archived}) else {throw FoodFailure.missingReference}
    let meal=try FoodMeal(date:date,slot:slot,items:catalog.snapshot(id),presetID:id,presetRevision:p.revision)
    return try enqueue(meal,operationID:UUID().uuidString)
  }
  public func edit(_ id:String,factor:Double=1,date:String?=nil,slot:String?=nil,remove:Bool=false) throws {
    guard let current=try snapshot().confirmed.first(where:{$0.id==id && !$0.removed}) else {throw FoodFailure.missingReference}
    try enqueue(current.edited(factor:factor,date:date,slot:slot,remove:remove),operationID:UUID().uuidString)
  }
  public func undoAddition(_ operationID:String) throws {
    let op=try hub.pending().first(where:{$0.id==operationID})?.operation ?? additions[operationID]
    guard let op else {throw FoodFailure.invalidValue};try hub.undoFoodAddition(op)
  }
  public func saveCatalog(_ catalog:FoodCatalog) throws {
    try catalog.validate();let old=try snapshot().catalog,rows=try hub.rows(table:"Categories"),pending=try hub.pending();var ops:[HubOperation]=[]
    guard old.versions.allSatisfy({catalog.versions.contains($0)}),old.categories.allSatisfy({c in catalog.categories.contains {$0.id==c.id}}),old.presets.allSatisfy({p in catalog.presets.contains {$0.id==p.id}}) else {throw FoodFailure.invalidValue}
    for version in catalog.versions.filter({!old.versions.contains($0)}) {ops.append(.init(foodVersion:version))}
    for c in catalog.categories where old.categories.first(where:{$0.id==c.id}) != c {
      let revision=pending.last(where:{$0.operation.foodCategory?.id==c.id}).map {$0.operation.expected_revision+1} ?? rows.first(where:{$0.table=="Categories" && $0.entityID==c.id})?.revision ?? 0
      ops.append(.init(foodCategory:c,expectedRevision:revision))
    }
    for p in catalog.presets where old.presets.first(where:{$0.id==p.id}) != p {
      guard p.revision==(old.presets.first(where:{$0.id==p.id})?.revision ?? 0)+1 else {throw FoodFailure.revisionConflict}
      ops.append(.init(foodPreset:p))
    }
    try hub.enqueueBatch(ops)
  }
}
