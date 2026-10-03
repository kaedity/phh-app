import Foundation
import Testing
@testable import PHHHubCore

@Suite struct SupplementTests {
  func product(id: String = UUID().uuidString, productID: String = UUID().uuidString,
    revision: Int = 1, kcal: Double = 10) throws -> SupplementProductVersion {
    try .init(id: id, productID: productID, revision: revision, name: "架空サプリ", unit: "粒", nutrients: [
      .init(nutrientID: "kcal", value: kcal, unit: "kcal", source: "商品表示"),
      .init(nutrientID: "protein", value: nil, unit: "g", source: "商品表示"),
      .init(nutrientID: "fat", value: 0, unit: "g", source: "商品表示"),
      .init(nutrientID: "carbohydrate", value: 2, unit: "g", source: "商品表示"),
      .init(nutrientID: "vitamin_b12", value: 3, unit: "µg", source: "商品表示")])
  }
  func fixture(auto: Bool = true, through: String? = nil) throws -> SupplementLedger {
    let p = try product(), plan = try SupplementPlanVersion(productVersionID: p.id,
      dailyAmount: 2, effectiveFrom: "2026-10-01", effectiveThrough: through, autoCount: auto)
    return try .init(products: [p], plans: [plan])
  }
  @Test func automaticIsPlannedAndManualReportUpdatesSameDayInsteadOfAdding() throws {
    var ledger = try fixture(); let id = ledger.plans[0].planID
    let a = try ledger.materialize(planID: id, date: "2026-10-03", today: "2026-10-03")!
    #expect(a.state == .planned && !a.isConfirmed && a.isCounted)
    #expect(a.nutrients[0].value == 20); #expect(a.nutrients[1].value == nil)
    #expect(a.nutrients[2].value == 0); #expect(a.nutrients[4].value == 6)
    #expect(try ledger.materialize(planID: id, date: a.date, today: a.date) == a)
    let b = try ledger.change(planID: id, date: a.date, expectedRevision: 1, amount: 3, state: .confirmed)
    #expect(ledger.days.count == 1 && b.id == a.id && b.revision == 2 && b.isConfirmed)
    #expect(try ledger.materialize(planID: id, date: b.date, today: b.date) == b)
  }
  @Test func explicitExclusionSurvivesRestartAndAutoGenerationAndCanBeExplicitlyRestored() throws {
    var ledger = try fixture(); let id = ledger.plans[0].planID
    let a = try ledger.change(planID: id, date: "2026-10-03", expectedRevision: 0, state: .excluded)
    #expect(!a.isCounted && a.dailyOverride)
    ledger = try JSONDecoder().decode(SupplementLedger.self, from: JSONEncoder().encode(ledger))
    #expect(try ledger.materialize(planID: id, date: a.date, today: a.date) == a)
    let b = try ledger.change(planID: id, date: a.date, expectedRevision: 1, state: .confirmed)
    #expect(b.isCounted && ledger.days.count == 1)
  }
  @Test func quantityOverrideOnlyAffectsOneDateAndStaleVersionDoesNotMutate() throws {
    var ledger = try fixture(); let id = ledger.plans[0].planID
    let a = try ledger.change(planID: id, date: "2026-10-03", expectedRevision: 0, amount: 4, state: .planned)
    let b = try ledger.materialize(planID: id, date: "2026-10-04", today: "2026-10-04")!
    #expect(a.amount == 4 && b.amount == 2)
    let before = ledger
    #expect(throws: SupplementFailure.revisionConflict) {
      try ledger.change(planID: id, date: a.date, expectedRevision: 0, amount: 9, state: .confirmed)
    }
    #expect(ledger == before)
  }
  @Test func productRevisionChangesCurrentUnmodifiedPlanAndFutureButNotPastSnapshots() throws {
    var ledger = try fixture(); let id = ledger.plans[0].planID, oldProduct = ledger.products[0]
    let past = try ledger.materialize(planID: id, date: "2026-10-02", today: "2026-10-02")!
    let current = try ledger.materialize(planID: id, date: "2026-10-03", today: "2026-10-03")!
    let newer = try product(productID: oldProduct.productID, revision: 2, kcal: 30)
    try ledger.addProduct(newer)
    try ledger.addPlan(.init(planID: id, revision: 2, productVersionID: newer.id,
      dailyAmount: 1, effectiveFrom: "2026-10-03"))
    #expect(try ledger.materialize(planID: id, date: past.date, today: current.date) == past)
    let changed = try ledger.materialize(planID: id, date: current.date, today: current.date)!
    #expect(changed.id == current.id && changed.revision == 2 && changed.nutrients[0].value == 30)
    #expect(try ledger.materialize(planID: id, date: "2026-10-04", today: "2026-10-04")!.productVersionID == newer.id)
    try ledger.validate()
  }
  @Test func disabledAndOutOfPeriodAreNotGeneratedAndOlderPlanNeverResurrects() throws {
    var ledger = try fixture(auto: false), ended = try fixture(through: "2026-10-02")
    #expect(try ledger.materialize(planID: ledger.plans[0].planID, date: "2026-10-03", today: "2026-10-03") == nil)
    #expect(try ended.materialize(planID: ended.plans[0].planID, date: "2026-10-03", today: "2026-10-03") == nil)
    #expect(throws: SupplementFailure.invalidValue) {
      try ledger.materialize(planID: ledger.plans[0].planID, date: "2026-10-04", today: "2026-10-03")
    }
    ledger = try fixture(); let id = ledger.plans[0].planID, p = ledger.products[0]
    let a = try ledger.materialize(planID: id, date: "2026-10-03", today: "2026-10-03")!
    try ledger.addPlan(.init(planID: id, revision: 2, productVersionID: p.id,
      dailyAmount: 2, effectiveFrom: "2026-10-03", effectiveThrough: "2026-10-03", autoCount: false))
    #expect(try ledger.materialize(planID: id, date: a.date, today: a.date)?.state == .excluded)
    #expect(try ledger.materialize(planID: id, date: "2026-10-04", today: "2026-10-04") == nil)
  }
  @Test func invalidSnapshotMissingReferencesAndInvalidNutrientsReject() throws {
    var ledger = try fixture(); let id = ledger.plans[0].planID
    let day = try ledger.materialize(planID: id, date: "2026-10-03", today: "2026-10-03")!
    #expect(throws: SupplementFailure.invalidValue) {
      try SupplementLedger(products: ledger.products, plans: ledger.plans, days: [day, day])
    }
    #expect(throws: SupplementFailure.missingReference) {
      try SupplementLedger(products: [], plans: ledger.plans, days: [day])
    }
    #expect(throws: SupplementFailure.invalidValue) {
      try SupplementNutrient(nutrientID: "fat", value: 1, unit: "mg", source: "商品表示")
    }
    #expect(throws: SupplementFailure.invalidValue) {
      try SupplementNutrient(nutrientID: "vitamin_b12", value: .infinity, unit: "µg", source: "商品表示")
    }
  }
}
