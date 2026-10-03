import Foundation

/// P4-5で接続する食事の操作契約。本番のHubOperationへ渡す前に対応APIの確認が必要です。
public struct FoodWireOperation: Codable, Equatable, Sendable {
  public let schema_version: Int, environment: String, operation_id: String, entity_id: String,
    expected_revision: Int, action: String, approval_state: String, synthetic: Bool,
    payload: FoodMeal
  public init(_ operation: FoodPendingOperation, environment: String, synthetic: Bool = true) throws {
    try operation.validate()
    guard ["PHH_TEST", "PHH_PRODUCTION"].contains(environment) else {
      throw FoodFailure.invalidValue
    }
    schema_version = 1
    self.environment = environment
    operation_id = operation.id
    entity_id = operation.meal.id
    expected_revision = operation.expectedRevision
    action =
      expected_revision == 0
      ? "confirm_food_meal" : operation.meal.removed ? "remove_food_meal" : "update_food_meal"
    approval_state = "confirmed"
    self.synthetic = synthetic
    payload = operation.meal
  }
  public func validate() throws {
    try payload.validate()
    try FoodRules.id(operation_id)
    guard schema_version == 1, ["PHH_TEST", "PHH_PRODUCTION"].contains(environment),
      approval_state == "confirmed", entity_id == payload.id, expected_revision >= 0,
      payload.revision == expected_revision + 1
    else { throw FoodFailure.invalidValue }
    let expected =
      expected_revision == 0
      ? "confirm_food_meal" : payload.removed ? "remove_food_meal" : "update_food_meal"
    guard action == expected, expected_revision > 0 || !payload.removed else {
      throw FoodFailure.invalidValue
    }
  }
}

public extension FoodWireOperation {
  /// 共通Outboxへの変換でも操作IDと記録時の写しを保持します。
  func hubOperation() throws -> HubOperation {
    try validate()
    guard environment == hubEnvironment else { throw HubError.invalidOperation }
    let operation = try JSONDecoder().decode(HubOperation.self, from: JSONEncoder().encode(self))
    try operation.validate()
    return operation
  }
}
