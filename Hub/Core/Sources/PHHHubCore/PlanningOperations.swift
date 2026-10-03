import Foundation

/// P5の型付き送信内容。目標・記録日・サプリを食事操作へ置換しません。
public struct PlanningMutation: Codable, Equatable, Sendable {
  public let goalRule: GoalRule?, dailyGoal: DailyGoal?, foodDay: FoodDay?,
    product: SupplementProductVersion?, plan: SupplementPlanVersion?, day: SupplementDay?
  public init(goalRule: GoalRule? = nil, dailyGoal: DailyGoal? = nil, foodDay: FoodDay? = nil,
    product: SupplementProductVersion? = nil, plan: SupplementPlanVersion? = nil, day: SupplementDay? = nil) {
    self.goalRule = goalRule; self.dailyGoal = dailyGoal; self.foodDay = foodDay
    self.product = product; self.plan = plan; self.day = day
  }
  public var action: String? {
    let names = [(goalRule != nil, "save_goal_rule"), (dailyGoal != nil, "save_daily_goal"),
      (foodDay != nil, "save_food_day"), (product != nil, "save_supplement_product"),
      (plan != nil, "save_supplement_plan"), (day != nil, "save_supplement_day")]
      .filter { $0.0 }.map { $0.1 }
    return names.count == 1 ? names[0] : nil
  }
  public static let actions: Set<String> = ["save_goal_rule", "save_daily_goal", "save_food_day",
    "save_supplement_product", "save_supplement_plan", "save_supplement_day"]
  public var logicalKey: String? {
    if let v = dailyGoal { return "dailyGoal|"+v.date }
    if let v = foodDay { return "foodDay|"+v.date }
    if let v = day { return "supplementDay|"+v.key }
    if let v = goalRule { return "goalRule|"+v.effectiveFrom }
    if let v = product { return "product|\(v.productID)|\(v.revision)" }
    if let v = plan { return "plan|\(v.planID)|\(v.revision)" }
    return nil
  }
  public func validate(entityID: String, expectedRevision: Int) throws {
    guard action != nil else { throw HubError.invalidOperation }
    if let v = goalRule { try v.validate(); guard v.id == entityID, v.revision == expectedRevision + 1 else { throw HubError.invalidOperation } }
    if let v = dailyGoal { try v.validate() }
    if let v = foodDay { try v.validate(); guard v.revision == expectedRevision + 1 else { throw HubError.invalidOperation } }
    if let v = product { try v.validate(); guard v.id == entityID, expectedRevision == 0 else { throw HubError.invalidOperation } }
    if let v = plan { try v.validate(); guard v.id == entityID, expectedRevision == 0 else { throw HubError.invalidOperation } }
    if let v = day { try v.validate(); guard v.id == entityID, v.revision == expectedRevision + 1 else { throw HubError.invalidOperation } }
  }
}
public extension HubOperation {
  init(planning: PlanningMutation, entityID: String, expectedRevision: Int = 0,
    operationID: String = UUID().uuidString) throws {
    self.init(action: planning.action ?? "", entityID: entityID, revision: expectedRevision)
    self.operation_id = operationID; self.planning = planning; try validate()
  }
  internal func validatePlanning() throws {
    guard let planning, planning.action == action, payload == nil, foodMeal == nil,
      foodVersion == nil, foodCategory == nil, foodPreset == nil,
      trainingCycle == nil, trainingSession == nil else { throw HubError.invalidOperation }
    do { try planning.validate(entityID: entity_id, expectedRevision: expected_revision) }
    catch { throw HubError.invalidOperation }
  }
}
/// 共通送信待ちへの入口。確定値は差分の読取後だけ更新します。
@MainActor public final class PlanningHubStore {
  private let hub: HubStore
  public init(hub: HubStore) { self.hub = hub }
  public func pending() throws -> [Pending] { try hub.pending().filter { $0.operation.requiresPlanningContract } }
  public func enqueue(_ operations: [HubOperation]) throws {
    let existing = try pending()
    for op in operations {
      guard op.requiresPlanningContract,
        existing.allSatisfy({
          ($0.operation.entity_id != op.entity_id && $0.operation.planning?.logicalKey != op.planning?.logicalKey) || $0.id == op.id
        })
      else { throw FoodFailure.pendingEdit }
    }
    guard Set(operations.map(\.entity_id)).count == operations.count,
      Set(operations.compactMap { $0.planning?.logicalKey }).count == operations.count
    else { throw FoodFailure.pendingEdit }
    try hub.enqueueBatch(operations)
  }
  /// 通信開始後の操作を「未送信」として消さない。保存後の修正は新しい操作で行います。
  public func cancelUnsent(_ id: String) throws {
    guard let item = try pending().first(where: { $0.id == id }), item.attempts == 0,
      item.state == .queued else { throw FoodFailure.pendingEdit }
    try hub.cancelUnsentPlanning(id)
  }
}
