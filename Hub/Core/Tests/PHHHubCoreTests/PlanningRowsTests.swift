import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct PlanningRowsTests {
  @Test func gasFixtureRestoresAllSixModelTypesThroughTheCommonStore() throws {
    struct Fixture:Decodable {let page:Delta,operations:[HubOperation]}
    var root=URL(fileURLWithPath:#filePath);for _ in 0..<4 {root.deleteLastPathComponent()}
    let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:root.appending(path:"Server/planning-p5-fixture.json")))
    let hub=try HubStore(owner:"synthetic@example.test");try hub.apply(fixture.page)
    let records=try PlanningRows.read(hub.rows())
    for operation in fixture.operations {try operation.validate();#expect(records.first {$0.id==operation.entity_id}?.mutation==operation.planning)}
  }
  func operations() throws -> [HubOperation] {
    let r = try PlanningStoreTests().ruleOperation(), rule = r.planning!.goalRule!
    let a = try ManualGoalAdjustment(date: "2026-10-03", reason: "架空調整", delta: .init(kcal: 100))
    let goal = try DailyGoal.calculate(date: a.date, rule: rule, manual: [a], freeze: true)!
    let id = UUID().uuidString, day = try FoodDay.completed(date: a.date, operationID: id, at: Date(timeIntervalSince1970: 123))
    let product = try SupplementTests().product(), plan = try SupplementPlanVersion(productVersionID: product.id, dailyAmount: 2, effectiveFrom: a.date)
    var ledger = try SupplementLedger(products: [product], plans: [plan])
    let supp = try ledger.materialize(planID: plan.planID, date: a.date, today: a.date)!
    return [r, try .init(planning: .init(dailyGoal: goal), entityID: UUID().uuidString),
      try .init(planning: .init(foodDay: day), entityID: UUID().uuidString, operationID: id),
      try .init(planning: .init(product: product), entityID: product.id),
      try .init(planning: .init(plan: plan), entityID: plan.id),
      try .init(planning: .init(day: supp), entityID: supp.id)]
  }
  func page(_ rows: [LocalRow], contract: Int? = 1) -> Delta {
    var p = Delta(schema_version: 1, environment: hubEnvironment, generation: 1,
      snapshot_revision: rows.count, changes: rows.enumerated().map { i,r in .init(
        change: .init(change_number: i+1, table_name: r.table, entity_id: r.entityID,
          revision: r.revision, indexed_revision: r.revision, removed: !r.active, local_date: r.values["local_date"]?.text), record: r.values) },
      next_cursor: rows.count, has_more: false)
    p.planning_contract = contract; return p
  }
  @Test func normalColumnsRestoreExactModelsAndKeepDatesAndUnknownMicronutrients() throws {
    let ops = try operations(), rows = try ops.flatMap { try PlanningRows.rows($0, timestamp: "2026-10-02T16:50:00Z") }
    let hub = try HubStore(owner: "synthetic@example.test"); try hub.apply(page(rows))
    let read = try PlanningRows.read(hub.rows())
    #expect(Set(read.map(\.id)) == Set(ops.map(\.entity_id)))
    for op in ops { #expect(read.first { $0.id == op.entity_id }?.mutation == op.planning) }
    #expect(read.compactMap { $0.mutation.dailyGoal }.first?.state == .frozen)
    #expect(read.compactMap { $0.mutation.foodDay }.first?.eligibleForPeriodAdjustment == true)
    #expect(try PlanningRows.rows(ops[3], timestamp: "2026-10-02T16:50:00Z") == rows.filter { ["SupplementProducts", "SupplementProductNutrients"].contains($0.table) })
  }
  @Test func unsupportedContractMissingChildAndDuplicateDayRejectInsteadOfChangingSnapshot() throws {
    let ops = try operations(), rows = try ops.flatMap { try PlanningRows.rows($0, timestamp: "2026-10-02T16:50:00Z") }
    let hub = try HubStore(owner: "synthetic@example.test")
    #expect(throws: HubError.invalidResponse) { try hub.apply(page(rows, contract: nil)) }
    #expect(try hub.cursor == 0 && hub.rows().isEmpty)
    #expect(throws: HubError.invalidResponse) { try PlanningRows.read(rows.filter { $0.table != "SupplementDayNutrients" }) }
    var duplicate = try PlanningRows.rows(ops[2], timestamp: "2026-10-02T16:50:00Z")[0]
    duplicate.values["id"] = .string(UUID().uuidString)
    #expect(throws: HubError.invalidResponse) { try PlanningRows.read(rows+[duplicate]) }
  }
  @Test func corruptedSnapshotTotalsOrdinalsAndFoodCompletionAreRejected() throws {
    let ops = try operations(), rows = try ops.flatMap { try PlanningRows.rows($0, timestamp: "2026-10-02T16:50:00Z") }
    var bad = rows; let goal = bad.firstIndex { $0.table == "DailyGoals" }!
    bad[goal].values["total_kcal"] = .number(999)
    #expect(throws: HubError.invalidResponse) { try PlanningRows.read(bad) }
    bad = rows; let n = bad.firstIndex { $0.table == "SupplementDayNutrients" }!
    bad[n].values["number"] = .number(9)
    #expect(throws: HubError.invalidResponse) { try PlanningRows.read(bad) }
    bad = rows; let d = bad.firstIndex { $0.table == "FoodDays" }!
    bad[d].values["completed_food_revision"] = .number(1)
    #expect(throws: HubError.invalidResponse) { try PlanningRows.read(bad) }
  }
  @Test func sameDatePendingCompletionWithDifferentRootIDIsStillOneTarget() throws {
    let ops = try operations(), hub = try HubStore(owner: "synthetic@example.test"), facade = PlanningHubStore(hub: hub)
    let a = ops[2]; try facade.enqueue([a]); var b = a; b.operation_id = UUID().uuidString; b.entity_id = UUID().uuidString
    #expect(throws: FoodFailure.pendingEdit) { try facade.enqueue([b]) }
    #expect(try facade.pending().map(\.id) == [a.id])
  }
}
