#if DEBUG
import SwiftUI
import PHHHubCore

struct PlanningPreviewRoot: View {
  @State private var model: PlanningScreenModel
  init() {
    _model = State(initialValue: try! PlanningScreenModel(hub: Self.makeStore(empty: ProcessInfo.processInfo.arguments.contains("--empty")), onSaved: {}))
  }
  static func makeStore(empty: Bool) -> HubStore {
    let hub = try! HubStore(owner: "synthetic@example.test")
    var ops: [HubOperation] = []
    if !empty {
      let fractional = ProcessInfo.processInfo.arguments.contains("--fractional-goal")
      let rule = try! GoalRule(effectiveFrom: "2026-10-01", phase: .maintaining,
        base: .init(kcal: fractional ? 2000.25 : 2000, protein: fractional ? 100.55 : 100,
          fat: fractional ? 50.125 : 50, carbohydrate: fractional ? 250.005 : 250))
      let goal = try! DailyGoal.calculate(date: "2026-10-02", rule: rule, freeze: true)!
      let product = try! SupplementProductVersion(name: "架空のビタミン", unit: "粒", nutrients: [
        .init(nutrientID: "kcal", value: 10, unit: "kcal", source: "商品表示"),
        .init(nutrientID: "protein", value: 0, unit: "g", source: "商品表示"),
        .init(nutrientID: "fat", value: 0, unit: "g", source: "商品表示"),
        .init(nutrientID: "carbohydrate", value: 2, unit: "g", source: "商品表示")])
      let plan = try! SupplementPlanVersion(productVersionID: product.id, dailyAmount: 2,
        effectiveFrom: "2026-10-01")
      var ledger = try! SupplementLedger(products: [product], plans: [plan])
      let day = ProcessInfo.processInfo.arguments.contains("--excluded-supplement")
        ? try! ledger.change(planID: plan.planID, date: "2026-10-03", expectedRevision: 0, state: .excluded)
        : try! ledger.materialize(planID: plan.planID, date: "2026-10-03", today: "2026-10-03")!
      ops = [try! .init(planning: .init(goalRule: rule), entityID: rule.id),
        try! .init(planning: .init(dailyGoal: goal), entityID: UUID().uuidString),
        try! .init(planning: .init(product: product), entityID: product.id),
        try! .init(planning: .init(plan: plan), entityID: plan.id),
        try! .init(planning: .init(day: day), entityID: day.id)]
    }
    let rows = try! ops.flatMap { try PlanningRows.rows($0, timestamp: "2026-10-02T17:00:00Z") }
    var page = Delta(schema_version: 1, environment: hubEnvironment, generation: 1,
      snapshot_revision: rows.count, changes: rows.enumerated().map { i,r in
        .init(change: .init(change_number: i+1, table_name: r.table, entity_id: r.entityID,
          revision: r.revision, indexed_revision: r.revision, removed: false,
          local_date: r.values["local_date"]?.text), record: r.values)
      }, next_cursor: rows.count, has_more: false)
    page.planning_contract = 1; page.catalog_entry_contract = 1; try! hub.apply(page)
    return hub
  }
  var body: some View {
    if ProcessInfo.processInfo.arguments.contains("--goal") {
      NavigationStack { GoalDetailPage(model: model, date: "2026-10-02", consumed: try! .init(kcal: 1280, protein: 75, fat: 40, carbohydrate: 155)) }.tint(pine)
    } else { overview }
  }
  private var overview: some View {
    NavigationStack {
      Page(title: "食事と目標") {
        Text("架空データ · 通信なし · 食事2200 kcal").font(.caption).foregroundStyle(.secondary)
        PlanningDayCard(model: model, date: ProcessInfo.processInfo.arguments.contains("--frozen-overview") ? "2026-10-02" : "2026-10-03",
          consumed: try! .init(kcal: 2200, protein: 120, fat: 55, carbohydrate: 260))
        NavigationLink("カテゴリー内のサプリ・自動計上") { SupplementPage(model: model, date: "2026-10-03") }
        NavigationLink("過去日の目標（確定済み）") {
          GoalDetailPage(model: model, date: "2026-10-02", consumed: try! .init(kcal: 1500))
        }
        PlanningQueueCard(model: model)
      }
    }.tint(pine)
  }
}
#endif
