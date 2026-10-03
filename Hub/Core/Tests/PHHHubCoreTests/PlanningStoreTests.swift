import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct PlanningStoreTests {
  func ruleOperation(from: String = "2026-10-03") throws -> HubOperation {
    let v = try GoalRule(effectiveFrom: from, phase: .maintaining, base: .init(kcal: 2000))
    return try .init(planning: .init(goalRule: v), entityID: v.id)
  }
  func ready(_ hub: HubStore) throws {
    var p = Delta(schema_version: 1, environment: hubEnvironment, generation: 1,
      snapshot_revision: 0, changes: [], next_cursor: 0, has_more: false)
    p.planning_contract = 1; try hub.apply(p)
  }
  @Test func allPayloadsRoundTripWithoutNutrientRecalculation() throws {
    let r = try ruleOperation(), rule = r.planning!.goalRule!
    let goal = try DailyGoal.calculate(date: "2026-10-03", rule: rule)!, foodDay = try FoodDay(date: goal.date)
    let product = try SupplementTests().product(), plan = try SupplementPlanVersion(
      productVersionID: product.id, dailyAmount: 2, effectiveFrom: goal.date)
    var ledger = try SupplementLedger(products: [product], plans: [plan])
    let day = try ledger.materialize(planID: plan.planID, date: goal.date, today: goal.date)!
    let operations = [r, try .init(planning: .init(dailyGoal: goal), entityID: UUID().uuidString),
      try .init(planning: .init(foodDay: foodDay), entityID: UUID().uuidString),
      try .init(planning: .init(product: product), entityID: product.id),
      try .init(planning: .init(plan: plan), entityID: plan.id),
      try .init(planning: .init(day: day), entityID: day.id)]
    for op in operations {
      try op.validate(); #expect(op.requiresPlanningContract && !op.requiresFoodContract)
      #expect(try JSONDecoder().decode(HubOperation.self, from: JSONEncoder().encode(op)) == op)
    }
  }
  @Test func restartKeepsSameIDsAndUnsentCancellationOnlyRemovesTarget() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("hub.sqlite"), a = try ruleOperation(), b = try ruleOperation(from: "2026-10-04")
    var store: HubStore? = try HubStore(url: url, owner: "synthetic@example.test")
    try PlanningHubStore(hub: store!).enqueue([a, b]); try PlanningHubStore(hub: store!).enqueue([a]); store = nil
    let reopened = try HubStore(url: url, owner: "synthetic@example.test"), facade = PlanningHubStore(hub: reopened)
    #expect(try facade.pending().map(\.operation) == [a, b])
    try facade.cancelUnsent(a.id); try reopened.markAttempted(b.id)
    #expect(throws: FoodFailure.pendingEdit) { try facade.cancelUnsent(b.id) }
    #expect(try facade.pending().map(\.id) == [b.id]); #expect(try reopened.rows().isEmpty)
  }
  @Test func unsupportedAPIAndOfflineNeverSendAndKeepQueue() async throws {
    let hub = try HubStore(owner: "synthetic@example.test"), op = try ruleOperation()
    try PlanningHubStore(hub: hub).enqueue([op])
    let transport = PlanningTestTransport(), engine = SyncEngine(store: hub, transport: transport)
    await engine.synchronize(date: "2026-10-03")
    #expect(transport.submissions == 0); #expect(try hub.pending()[0].operation == op)
    transport.contract = 1; await engine.synchronize(date: "2026-10-03")
    transport.connected = false; await engine.synchronize(date: "2026-10-03")
    #expect(transport.submissions == 0); #expect(try hub.pending()[0].operation == op)
  }
  @Test func lostResponseResolvesSameOperationOnceAndDoesNotFabricateConfirmedRows() async throws {
    let hub = try HubStore(owner: "synthetic@example.test"), op = try ruleOperation(); try ready(hub)
    try PlanningHubStore(hub: hub).enqueue([op])
    let transport = PlanningTestTransport(), engine = SyncEngine(store: hub, transport: transport)
    transport.contract = 1; transport.loseResponse = true
    await engine.synchronize(date: "2026-10-03")
    #expect(transport.submissions == 1); #expect(try hub.pending()[0].id == op.id)
    await engine.synchronize(date: "2026-10-03", forceQueued: true)
    #expect(transport.submissions == 1); #expect(try hub.pending().isEmpty)
    #expect(try hub.rows().isEmpty)
  }
  @Test func conflictKeepsTargetAndOtherDaysAndAtomicFailureKeepsEarlierQueue() async throws {
    let hub = try HubStore(owner: "synthetic@example.test"), facade = PlanningHubStore(hub: hub)
    let a = try ruleOperation(), b = try HubOperation(planning: .init(foodDay: FoodDay(date: "2026-10-04")), entityID: UUID().uuidString)
    try ready(hub); try facade.enqueue([a, b])
    var changed = a; changed.entity_id = UUID().uuidString
    let v = try GoalRule(id: changed.entity_id, effectiveFrom: "2026-10-03", phase: .cutting, base: .init(kcal: 1800))
    changed.planning = .init(goalRule: v)
    let c = try ruleOperation(from: "2026-10-05")
    #expect(throws: HubError.invalidOperation) { try facade.enqueue([c, changed]) }
    #expect(try facade.pending().map(\.id) == [a.id, b.id])
    let transport = PlanningTestTransport(); transport.rejectConflict = true
    await SyncEngine(store: hub, transport: transport).synchronize(date: "2026-10-03")
    #expect(try facade.pending()[0].state == .conflict); #expect(try facade.pending()[1].operation == b)
    #expect(try hub.rows().isEmpty)
  }
  @Test func mixedOrWrongRevisionPayloadsRejectBeforeStorage() throws {
    let hub = try HubStore(owner: "synthetic@example.test"), op = try ruleOperation()
    var bad = op; bad.payload = .init(date: "2026-10-03")
    #expect(throws: HubError.invalidOperation) { try hub.enqueue(bad) }
    bad = op; bad.expected_revision = 2
    #expect(throws: HubError.invalidOperation) { try hub.enqueue(bad) }
    bad = op; bad.action = "confirm_meal"
    #expect(throws: HubError.invalidOperation) { try hub.enqueue(bad) }
    #expect(try hub.pending().isEmpty)
  }
}
@MainActor private final class PlanningTestTransport: HubTransport {
  var connected = true, loseResponse = false, rejectConflict = false
  var contract: Int? = nil, submissions = 0, receipts: [String: Receipt] = [:]
  func result(_ operation: HubOperation) async throws -> Receipt {
    receipts[operation.id] ?? Receipt(operation_id: operation.id, status: "not_found", retryable: false)
  }
  func submit(_ operation: HubOperation) async throws -> Receipt {
    submissions += 1
    if rejectConflict { return Receipt(environment: hubEnvironment, operation_id: operation.id,
      status: "rejected", error_code: "REVISION_CONFLICT", retryable: false) }
    let receipt = Receipt(environment: hubEnvironment, operation_id: operation.id, status: "committed",
      entity_ids: [operation.entity_id], revisions: [operation.expected_revision + 1], retryable: false)
    receipts[operation.id] = receipt
    if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
    return receipt
  }
  func processIntake(date: String) async throws {}
  func delta(_ query: HubQuery) async throws -> Delta {
    var p = Delta(schema_version: 1, environment: hubEnvironment, generation: 1,
      snapshot_revision: 0, changes: [], next_cursor: 0, has_more: false)
    p.planning_contract = contract; return p
  }
}
