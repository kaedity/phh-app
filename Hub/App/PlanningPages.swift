import Foundation
import Observation
import PHHHubCore
import SwiftUI

@MainActor @Observable final class PlanningScreenModel {
  private let hub: HubStore
  private let onSaved: () -> Void
  private(set) var records: [PlanningRecord] = []
  private(set) var pending: [Pending] = []
  var message = ""
  init(hub: HubStore, onSaved: @escaping () -> Void) throws {
    self.hub = hub; self.onSaved = onSaved; try refresh()
  }
  func refresh() throws {
    let rows = try PlanningRows.tables.sorted().flatMap { try hub.rows(table: $0) }
    let records = try PlanningRows.read(rows), pending = try PlanningHubStore(hub: hub).pending()
    self.records = records; self.pending = pending
  }
  func goal(_ date: String) throws -> DailyGoal? {
    let saved = records.compactMap { $0.mutation.dailyGoal }.first { $0.date == date }
    let rules = records.compactMap { $0.mutation.goalRule }.filter { $0.effectiveFrom <= date }
      .sorted { $0.effectiveFrom > $1.effectiveFrom }
    if rules.count > 1, rules[0].effectiveFrom == rules[1].effectiveFrom { throw GoalFailure.revisionConflict }
    return try DailyGoal.calculate(date: date, rule: rules.first, manual: saved?.manual ?? [], existing: saved)
  }
  func foodDay(_ date: String) -> FoodDay? { records.compactMap { $0.mutation.foodDay }.first { $0.date == date } }
  func totalWithSupplements(_ food: FoodTotal, date: String) throws -> FoodTotal {
    try food.includingSupplements(supplements().days, date: date)
  }
  func consumedWithSupplements(_ food:GoalValues,date:String) throws -> GoalValues {
    let days=try supplements().days.filter {$0.date==date && $0.isCounted}
    func value(_ base:Double?,_ nutrient:String) -> Double? {
      guard let base else {return nil}
      let values=days.map {$0.nutrients.first {$0.nutrientID==nutrient}?.value}
      guard values.allSatisfy({$0 != nil}) else {return nil}
      return base+values.compactMap {$0}.reduce(0,+)
    }
    return try .init(kcal:value(food.kcal,"kcal"),protein:value(food.protein,"protein"),fat:value(food.fat,"fat"),carbohydrate:value(food.carbohydrate,"carbohydrate"))
  }
  func supplements() throws -> SupplementLedger {
    try .init(products: records.compactMap { $0.mutation.product },
      plans: records.compactMap { $0.mutation.plan }, days: records.compactMap { $0.mutation.day })
  }
  func saveGoal(from: String, phase: GoalPhase, values: GoalValues) {
    perform {
      let old = records.first { $0.mutation.goalRule?.effectiveFrom == from }
      let rule = try GoalRule(id: old?.id ?? UUID().uuidString, revision: (old?.revision ?? 0)+1,
        effectiveFrom: from, phase: phase, base: values)
      try save(.init(goalRule: rule), id: rule.id, revision: old?.revision ?? 0)
    }
  }
  func manual(date: String, reason: String, delta: GoalDelta) {
    perform {
      guard let goal = try goal(date), goal.state != .frozen else { throw GoalFailure.missingBase }
      let rules = records.compactMap { $0.mutation.goalRule }
      guard let rule = rules.first(where: { $0.id == goal.ruleID }) else { throw GoalFailure.missingBase }
      let adjustment = try ManualGoalAdjustment(date: date, reason: reason, delta: delta)
      let updated = try DailyGoal.calculate(date: date, rule: rule, manual: goal.manual+[adjustment])!
      let old = records.first { $0.mutation.dailyGoal?.date == date }
      try save(.init(dailyGoal: updated), id: old?.id ?? UUID().uuidString, revision: old?.revision ?? 0)
    }
  }
  func complete(date: String) {
    perform {
      // 食事保存が未確定の間に、その前の食事版で完了を宣言しません。
      let mealIDs=Set(try hub.rows(table:"Meals",date:date).map(\.entityID))
      guard try hub.pending().allSatisfy({
        $0.operation.foodMeal?.date != date && $0.operation.payload?.local_date != date &&
        !mealIDs.contains($0.operation.entity_id) && $0.operation.planning?.day?.date != date
      })
      else { throw FoodFailure.pendingEdit }
      let id = UUID().uuidString, old = records.first { $0.mutation.foodDay?.date == date }
      var day: FoodDay
      if let existing = old?.mutation.foodDay {
        day = existing; try day.complete(expectedFoodRevision: day.foodRevision, operationID: id, at: .now)
      } else { day = try .completed(date: date, operationID: id, at: .now) }
      let op = try HubOperation(planning: .init(foodDay: day), entityID: old?.id ?? UUID().uuidString,
        expectedRevision: old?.revision ?? 0, operationID: id)
      try PlanningHubStore(hub: hub).enqueue([op])
    }
  }
  func change(_ day: SupplementDay, amount: Double? = nil, state: SupplementDayState) {
    perform {
      var ledger = try supplements()
      let changed = try ledger.change(planID: day.planID, date: day.date,
        expectedRevision: day.revision, amount: amount, state: state)
      try save(.init(day: changed), id: changed.id, revision: day.revision)
    }
  }
  func cancel(_ id: String) { perform { try PlanningHubStore(hub: hub).cancelUnsent(id) } }
  private func save(_ value: PlanningMutation, id: String, revision: Int) throws {
    try PlanningHubStore(hub: hub).enqueue([HubOperation(planning: value, entityID: id, expectedRevision: revision)])
  }
  private func perform(_ work: () throws -> Void) {
    do { try work(); try refresh(); message = "端末に保存しました・同期待ち"; onSaved() }
    catch { message = error.localizedDescription }
  }
}

struct PlanningDayCard: View {
  let model: PlanningScreenModel, date: String, consumed: GoalValues
  @Namespace private var cardZoom
  private var motion = MotionPolicy()
  var body: some View {
    Card {
      NavigationLink { GoalDetailPage(model: model, date: date, consumed: consumed).motionZoom(id: "goal", in: cardZoom, reduced: motion.reduced) } label: {
        HStack { Label("目標と残り", systemImage: "scope"); Spacer(); Image(systemName: "chevron.right") }
      }.font(.headline).matchedTransitionSource(id: "goal", in: cardZoom)
      if let goal = try? model.goal(date), let combined=try? model.consumedWithSupplements(consumed,date:date), let left = try? goal.remaining(consumed: combined) {
        Text("目標 \(foodNumber(goal.total.kcal)) kcal · 残り \(foodNumber(left.kcal)) kcal").font(.subheadline).contentTransition(.numericText()).animation(Motion.animation(reduceMotion: motion.reduced), value: left.kcal)
        Text("P \(foodNumber(left.protein)) / F \(foodNumber(left.fat)) / C \(foodNumber(left.carbohydrate)) g 残り").font(.caption)
        if let days=try? model.supplements().days.filter({$0.date==date && $0.isCounted}),!days.isEmpty {
          Text("サプリ込み · 予定\(days.filter {$0.state == .planned}.count)件／服用確認\(days.filter {$0.state == .confirmed}.count)件").font(.caption).foregroundStyle(.secondary)
        }
        Text(goal.state == .frozen ? "凍結済み · 過去日の目標" : "固定目標＋手動調整 · 自動補正オフ").font(.caption).foregroundStyle(.secondary)
      } else { Text("目標は未設定").foregroundStyle(.secondary) }
      let status = model.foodDay(date)?.status ?? .incomplete
      HStack {
        if status == .completed { MotionSuccessSeal() }
        Text(status == .completed ? "記録完了" : status == .changed ? "完了後に変更あり" : "記録は未完了")
          .font(.subheadline).foregroundStyle(status == .changed ? .orange : .secondary)
        Spacer()
        Button(status == .changed ? "再び記録完了" : "この日の記録完了") { model.complete(date: date); if model.message.hasPrefix("端末に保存") { Haptics.emit(.success) } }
          .disabled(status == .completed)
      }
      if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
      if !model.pending.isEmpty { Text("目標・サプリの送信待ち \(model.pending.count)件").font(.caption).foregroundStyle(.secondary) }
    }
  }
}
struct GoalDetailPage: View {
  let model: PlanningScreenModel, date: String, consumed: GoalValues
  var body: some View {
    Page(title: "目標の内訳") {
      Text(date).foregroundStyle(.secondary)
      if let goal = try? model.goal(date) {
        Card {
          Text("基準 \(foodNumber(goal.base.kcal)) kcal").font(.title3.bold())
          Text("P \(foodNumber(goal.base.protein)) / F \(foodNumber(goal.base.fat)) / C \(foodNumber(goal.base.carbohydrate)) g")
          ForEach(goal.manual) { a in Text("\(a.reason) · \(a.delta.kcal.formatted()) kcal") }
          Text("目標合計 \(foodNumber(goal.total.kcal)) kcal")
          Text("\(goal.calculationVersion) · 設定版\(goal.ruleRevision)").font(.caption).foregroundStyle(.secondary)
          HStack { Text(goal.state == .frozen ? "過去日の凍結値を保持しています" : "活動・期間の自動補正はオフです").font(.caption); MotionInfo(text: "固定目標と手動調整から計算しています。自動補正は本人が設定するまでオフです。") }
        }
        if goal.state != .frozen { NavigationLink("この日の手動調整") { ManualGoalEditor(model: model, date: date) } }
      } else { Card { Text("目標が未設定です。記録はそのまま使えます。") } }
      NavigationLink("適用日から固定目標を設定") { GoalRuleEditor(model: model, date: date) }
      PlanningQueueCard(model: model)
    }
  }
}
struct GoalRuleEditor: View {
  let model: PlanningScreenModel
  @State private var date: Date
  @State private var phase: GoalPhase = .maintaining
  @State private var kcal = ""
  @State private var protein = ""
  @State private var fat = ""
  @State private var carbohydrate = ""
  @State private var error = ""
  @State private var saved = false
  init(model: PlanningScreenModel, date: String) { self.model = model; _date = State(initialValue: FoodDates.date(date)) }
  var body: some View {
    Form {
      DatePicker("適用開始日", selection: $date, displayedComponents: .date).environment(\.timeZone, FoodDates.calendar.timeZone)
      Section("期") { MotionRadioChoice(title: "維持期", value: GoalPhase.maintaining, selection: $phase); MotionRadioChoice(title: "増量期", value: GoalPhase.gaining, selection: $phase); MotionRadioChoice(title: "減量期", value: GoalPhase.cutting, selection: $phase) }
      nutrientFields(kcal: $kcal, protein: $protein, fat: $fat, carbohydrate: $carbohydrate).motionFieldError(error)
      Text("PFCは任意です。空欄を0やkcal換算で埋めません。自動補正はオフです。").font(.caption)
      Button {
        do {
          let values = try GoalValues(kcal: planningNumber(kcal), protein: planningNumber(protein), fat: planningNumber(fat), carbohydrate: planningNumber(carbohydrate))
          model.saveGoal(from: FoodDates.text(date), phase: phase, values: values); saved=model.message.hasPrefix("端末に保存"); error=saved ? "" : model.message; if saved { Haptics.emit(.success) }
        } catch { self.error = error.localizedDescription }
      } label: { MotionSaveLabel(title: "目標を端末へ保存", saved: saved) }.buttonStyle(.borderedProminent).accessibilityLabel(saved ? "目標を保存しました" : "目標を端末へ保存")
      if !error.isEmpty { Text(error) }
    }.navigationTitle("固定目標の設定")
  }
}
private struct ManualGoalEditor: View {
  let model: PlanningScreenModel, date: String
  @State private var reason = ""
  @State private var kcal = ""
  @State private var protein = ""
  @State private var fat = ""
  @State private var carbohydrate = ""
  @State private var message = ""
  var body: some View {
    Form {
      Text("\(date)だけの手動調整"); TextField("調整の理由", text: $reason)
      nutrientFields(kcal: $kcal, protein: $protein, fat: $fat, carbohydrate: $carbohydrate)
      Text("増減値を入力してください。空欄は調整なしです。").font(.caption)
      Button("調整を端末へ保存") {
        do {
          model.manual(date: date, reason: reason, delta: try .init(kcal: planningNumber(kcal) ?? 0,
            protein: planningNumber(protein) ?? 0, fat: planningNumber(fat) ?? 0, carbohydrate: planningNumber(carbohydrate) ?? 0))
          message = model.message
        } catch { message = error.localizedDescription }
      }.buttonStyle(.borderedProminent)
      if !message.isEmpty { Text(message) }
    }.navigationTitle("手動調整")
  }
}
struct SupplementPage: View {
  let model: PlanningScreenModel, date: String
  @State private var editing: SupplementDay?
  var body: some View {
    Page(title: "サプリの自動計上") {
      Text(date).foregroundStyle(.secondary)
      Text("予定の設定・変更は会話で行います。毎日の服用確認は不要です。").font(.subheadline)
      if let ledger = try? model.supplements() {
        if ledger.plans.isEmpty { Card { Text("予定はまだありません"); Text("商品名・日量・成分・開始日を会話から登録します。").font(.caption).foregroundStyle(.secondary) } }
        ForEach(ledger.days.filter { $0.date == date }) { day in
          Card {
            Text(day.productName).font(.headline)
            Text("\(foodNumber(day.amount)) \(day.unit)")
            Text(day.state == .planned ? "予定から自動計上・服用確認なし" : day.state == .confirmed ? "服用確認済み" : "この日は除外")
              .font(.caption).foregroundStyle(.secondary)
            HStack {
              Button("この日だけ量を変更") { editing = day }
              Button(day.state == .excluded ? "服用を報告" : "飲まなかった") {
                model.change(day, state: day.state == .excluded ? .confirmed : .excluded)
              }
            }.buttonStyle(.bordered)
          }
        }
        ForEach(ledger.plans.sorted { $0.revision > $1.revision }.filter { p in
          p.effectiveFrom <= date && (p.effectiveThrough.map { date <= $0 } ?? true) &&
            !ledger.plans.contains { $0.planID == p.planID && $0.revision > p.revision && $0.effectiveFrom <= date }
        }) { p in
          Card {
            Text(ledger.products.first { $0.id == p.productVersionID }?.name ?? "商品版を確認")
            Text("日量 \(foodNumber(p.dailyAmount)) · 適用 \(p.effectiveFrom)〜\(p.effectiveThrough ?? "継続") · 予定版\(p.revision)").font(.caption)
            Text(p.autoCount ? "自動計上オン" : "自動計上オフ").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      PlanningQueueCard(model: model)
    }.sheet(item: $editing) { SupplementAmountEditor(model: model, day: $0) }
  }
}
private struct SupplementAmountEditor: View {
  let model: PlanningScreenModel, day: SupplementDay
  @State private var amount: String
  @State private var error = ""
  init(model: PlanningScreenModel, day: SupplementDay) { self.model = model; self.day = day; _amount = State(initialValue: foodNumber(day.amount)) }
  var body: some View {
    NavigationStack {
      Form {
        Text("\(day.date) · \(day.productName)")
        TextField(day.unit, text: $amount).keyboardType(.decimalPad)
        Button("この日だけ変更を保存") {
          do { guard let value = try planningNumber(amount) else { throw SupplementFailure.invalidValue }
            model.change(day, amount: value, state: day.state); error = model.message
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent)
        Text(error)
      }.navigationTitle("量の例外")
    }
  }
}
struct PlanningQueueCard: View {
  let model: PlanningScreenModel
  var body: some View {
    if !model.pending.isEmpty {
      Card {
        Text("目標・サプリの送信待ち").font(.headline)
        ForEach(model.pending) { p in
          Text(p.operation.planning?.goalRule != nil ? "目標設定" : p.operation.planning?.foodDay != nil ? "記録日の完了" : "目標・サプリの変更").font(.subheadline)
          Text(p.message).font(.caption).foregroundStyle(.secondary)
          if p.state == .queued && p.attempts == 0 { Button("未送信の変更を取消") { model.cancel(p.id) }.buttonStyle(.bordered) }
        }
      }
    }
    if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
  }
}
private func planningNumber(_ text: String) throws -> Double? {
  let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.isEmpty { return nil }
  guard let number = Double(value), number.isFinite else { throw GoalFailure.invalidValue }; return number
}
@ViewBuilder private func nutrientFields(kcal: Binding<String>, protein: Binding<String>, fat: Binding<String>, carbohydrate: Binding<String>) -> some View {
  TextField("kcal", text: kcal).keyboardType(.numbersAndPunctuation)
  TextField("P g（任意）", text: protein).keyboardType(.numbersAndPunctuation)
  TextField("F g（任意）", text: fat).keyboardType(.numbersAndPunctuation)
  TextField("C g（任意）", text: carbohydrate).keyboardType(.numbersAndPunctuation)
}

func planningConsumed(total: FoodTotal) -> GoalValues {
  func value(_ n:FoodNutrient) -> Double? {(total.missing[n] ?? 0)>0 ? nil : total.known[n] ?? 0}
  return (try? .init(kcal:value(.kcal),protein:value(.protein),fat:value(.fat),carbohydrate:value(.carbohydrate))) ?? (try! .init())
}
func planningConsumed(summary:LocalRow?) -> GoalValues {
  func value(_ field:String,_ unknown:String) -> Double? {
    guard let summary else {return nil}
    return (summary.values[unknown]?.number ?? 0)>0 ? nil : summary.values[field]?.number
  }
  return (try? .init(kcal:value("kcal","kcal_unknown"),protein:value("protein_g","protein_unknown"),fat:value("fat_g","fat_unknown"),carbohydrate:value("carbohydrate_g","carbohydrate_unknown"))) ?? (try! .init())
}
