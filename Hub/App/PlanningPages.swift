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
  @discardableResult func saveGoal(from: String, phase: GoalPhase, values: GoalValues) -> Bool {
    perform {
      let old = records.first { $0.mutation.goalRule?.effectiveFrom == from }
      let rule = try GoalRule(id: old?.id ?? UUID().uuidString, revision: (old?.revision ?? 0)+1,
        effectiveFrom: from, phase: phase, base: values)
      try save(.init(goalRule: rule), id: rule.id, revision: old?.revision ?? 0)
    }
  }
  @discardableResult func manual(date: String, reason: String, delta: GoalDelta) -> Bool {
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
  @discardableResult func change(_ day: SupplementDay, amount: Double? = nil, state: SupplementDayState) -> Bool {
    perform {
      var ledger = try supplements()
      let changed = try ledger.change(planID: day.planID, date: day.date,
        expectedRevision: day.revision, amount: amount, state: state)
      try save(.init(day: changed), id: changed.id, revision: day.revision)
    }
  }
  func cancel(_ id: String) { perform(successMessage: "未送信の変更を取り消しました") { try PlanningHubStore(hub: hub).cancelUnsent(id) } }
  private func save(_ value: PlanningMutation, id: String, revision: Int) throws {
    try PlanningHubStore(hub: hub).enqueue([HubOperation(planning: value, entityID: id, expectedRevision: revision)])
  }
  @discardableResult private func perform(successMessage: String = "端末に保存しました・同期待ち", _ work: () throws -> Void) -> Bool {
    do { try work(); try refresh(); message = successMessage; onSaved(); return true }
    catch { message = error.localizedDescription; return false }
  }
}

struct PlanningDayCard: View {
  let model: PlanningScreenModel, date: String, consumed: GoalValues
  @Namespace private var cardZoom
  private var motion = MotionPolicy()
  /// 負の「残り」を出さず、ホームと同じく超過分を「目標より＋」で示す。
  private func leftText(_ value: Double?, _ unit: String) -> String {
    guard let value else { return "残り — \(unit)" }
    return value >= 0 ? "残り \(foodNumber(value)) \(unit)" : "目標より＋\(foodNumber(-value)) \(unit)"
  }
  var body: some View {
    Card {
      NavigationLink { GoalDetailPage(model: model, date: date, consumed: consumed).motionZoom(id: "goal", in: cardZoom, reduced: motion.reduced) } label: {
        HStack { Label("目標と残り", systemImage: "scope"); Spacer(); Image(systemName: "chevron.right") }
          .frame(minHeight: 44).contentShape(Rectangle())
      }.font(.headline).matchedTransitionSource(id: "goal", in: cardZoom)
      if let goal = try? model.goal(date), let combined=try? model.consumedWithSupplements(consumed,date:date), let left = try? goal.remaining(consumed: combined) {
        Text("目標 \(foodNumber(goal.total.kcal)) kcal · \(leftText(left.kcal, "kcal"))").font(.subheadline).contentTransition(.numericText()).animation(Motion.animation(reduceMotion: motion.reduced), value: left.kcal)
        Text("P \(leftText(left.protein, "g")) / F \(leftText(left.fat, "g")) / C \(leftText(left.carbohydrate, "g"))").font(.caption)
        if let days=try? model.supplements().days.filter({$0.date==date && $0.isCounted}),!days.isEmpty {
          Text("サプリ込み · 予定\(days.filter {$0.state == .planned}.count)件／服用確認\(days.filter {$0.state == .confirmed}.count)件").font(.caption).foregroundStyle(.secondary)
        }
        Text(goal.state == .frozen ? "確定済み · 過去日の目標" : "固定目標＋手動調整 · 自動補正オフ").font(.caption).foregroundStyle(.secondary)
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
  private func pfc(_ label: String, _ value: Double?, _ color: Color) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 3) { Text(label).font(.headline).foregroundStyle(color); Text(foodNumber(value)).font(.title2.weight(.semibold)).foregroundStyle(color); Text("g").font(.subheadline).foregroundStyle(color) }
      .fixedSize(horizontal: true, vertical: false)
  }
  var body: some View {
    Page(title: "目標の内訳") {
      Text(mockDay(date)).foregroundStyle(.secondary)
      if let goal = try? model.goal(date) {
        let manual = goal.manual.map(\.delta.kcal).reduce(0, +)
        VStack(spacing: 12) {
          Text("1日の目標摂取カロリー").font(.subheadline).foregroundStyle(.secondary)
          MockFigure(value: foodNumber(goal.total.kcal), unit: "kcal", size: 46).accessibilityElement(children: .combine).accessibilityLabel("目標合計 \(foodNumber(goal.total.kcal)) kcal")
          Divider()
          ViewThatFits(in: .horizontal) {
            HStack {
              pfc("P", goal.total.protein ?? goal.base.protein, pfcProtein); Spacer()
              pfc("F", goal.total.fat ?? goal.base.fat, pfcFat); Spacer()
              pfc("C", goal.total.carbohydrate ?? goal.base.carbohydrate, pfcCarb)
            }
            VStack(alignment: .leading, spacing: 12) {
              pfc("P", goal.total.protein ?? goal.base.protein, pfcProtein)
              pfc("F", goal.total.fat ?? goal.base.fat, pfcFat)
              pfc("C", goal.total.carbohydrate ?? goal.base.carbohydrate, pfcCarb)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.padding(.horizontal, 8)
        }.frame(maxWidth: .infinity).padding(20).background(HubPalette.card, in: RoundedRectangle(cornerRadius: 22))
        MockRows {
          MockRow(title: "基準", chevron: false) { Text("\(foodNumber(goal.base.kcal)) kcal") }
          MockRow(title: "活動補正", chevron: false) { Text("0 kcal").foregroundStyle(.secondary) }
          MockRow(title: "期間補正", chevron: false) { Text("0 kcal").foregroundStyle(.secondary) }
          MockRow(title: "手動調整", chevron: false, last: true) { Text("\(manual.formatted()) kcal") }
        }
        ForEach(goal.manual) { a in Text("手動調整：\(a.reason)（\(a.delta.kcal.formatted()) kcal）").font(.caption).foregroundStyle(.secondary) }
        if goal.state == .frozen { Text("この日の目標は確定済みです。後から目標を変えても、この日の値は変わりません。").font(.caption).foregroundStyle(.secondary) }
        Text("目標設定").font(.headline).padding(.top, 6)
        MockRows {
          NavigationLink { GoalRuleEditor(model: model, date: date) } label: { MockRow(title: "固定目標", subtitle: "カロリー・PFCを、適用日から固定で設定します") }.buttonStyle(.plain)
          if goal.state != .frozen { NavigationLink { ManualGoalEditor(model: model, date: date) } label: { MockRow(title: "この日の手動調整", subtitle: "この日だけ目標を増減します") }.buttonStyle(.plain) }
          MockRow(title: "自動補正", subtitle: "活動量・期間による自動補正はオフです（係数を決めるまで）", chevron: false, last: true) { Toggle("", isOn: .constant(false)).labelsHidden().disabled(true).accessibilityLabel("自動補正（オフ）") }
        }
      } else {
        Card { Text("目標が未設定です。記録はそのまま使えます。") }
        MockRows { NavigationLink { GoalRuleEditor(model: model, date: date) } label: { MockRow(title: "固定目標を設定", subtitle: "適用日から、カロリー・PFCを固定で設定します", last: true) }.buttonStyle(.plain) }
      }
      PlanningQueueCard(model: model)
    }
  }
}
struct GoalRuleEditor: View {
  let model: PlanningScreenModel
  @Environment(\.dismiss) private var dismiss
  private struct Draft: Equatable {
    let from: String, phase: GoalPhase, kcal: String, protein: String, fat: String, carbohydrate: String
  }
  @State private var date: Date
  @State private var phase: GoalPhase = .maintaining
  @State private var kcal = ""
  @State private var protein = ""
  @State private var fat = ""
  @State private var carbohydrate = ""
  @State private var error = ""
  @State private var saved = false
  @State private var acceptedDraft: Draft
  @State private var confirmBack = false
  @FocusState private var focusedField: String?
  init(model: PlanningScreenModel, date: String) {
    self.model = model
    let goal = try? model.goal(date)
    let waiting = model.pending.first { $0.operation.planning?.goalRule?.effectiveFrom == date }?.operation.planning?.goalRule
    let base = waiting?.base ?? goal?.base
    // 送信待ちを再表示し、確定済みの目標は差分取得まで保持します。
    let initial = Draft(from: date, phase: waiting?.phase ?? goal?.phase ?? .maintaining,
      kcal: planningValueText(base?.kcal), protein: planningValueText(base?.protein),
      fat: planningValueText(base?.fat), carbohydrate: planningValueText(base?.carbohydrate))
    _date = State(initialValue: FoodDates.date(date)); _phase = State(initialValue: initial.phase)
    _kcal = State(initialValue: initial.kcal); _protein = State(initialValue: initial.protein)
    _fat = State(initialValue: initial.fat); _carbohydrate = State(initialValue: initial.carbohydrate)
    _acceptedDraft = State(initialValue: initial)
  }
  private var draft: Draft { .init(from: FoodDates.text(date), phase: phase, kcal: kcal, protein: protein, fat: fat, carbohydrate: carbohydrate) }
  private var hasUnsavedInput: Bool { draft != acceptedDraft }
  private var pendingGoal: Pending? { model.pending.first { $0.operation.planning?.goalRule?.effectiveFrom == FoodDates.text(date) } }
  private var pendingMessage: String {
    switch pendingGoal?.state {
    case .queued: "この開始日の設定は送信待ちです。完了後に再保存できます。"
    case .authentication: "この開始日の設定は再接続待ちです。Googleへ再接続してください。"
    case .invalid, .conflict: "この開始日の設定は要確認です。送信待ちから内容を確認してください。"
    case nil: ""
    }
  }
  var body: some View {
    Form {
      DatePicker("適用開始日", selection: $date, displayedComponents: .date).environment(\.timeZone, FoodDates.calendar.timeZone)
      Section("期") { MotionRadioChoice(title: "維持期", value: GoalPhase.maintaining, selection: $phase); MotionRadioChoice(title: "増量期", value: GoalPhase.gaining, selection: $phase); MotionRadioChoice(title: "減量期", value: GoalPhase.cutting, selection: $phase) }
      nutrientFields(kcal: $kcal, protein: $protein, fat: $fat, carbohydrate: $carbohydrate, focus: $focusedField).motionFieldError(error)
      Text("PFCは任意です。空欄を0やkcal換算で埋めません。自動補正はオフです。").font(.caption)
      Button {
        do {
          let values = try GoalValues(kcal: planningNumber(kcal), protein: planningNumber(protein), fat: planningNumber(fat), carbohydrate: planningNumber(carbohydrate))
          saved = model.saveGoal(from: FoodDates.text(date), phase: phase, values: values)
          error = saved ? "" : model.message
          if saved { acceptedDraft = draft; focusedField = nil; Haptics.emit(.success) }
        } catch { self.error = error.localizedDescription }
      } label: { MotionSaveLabel(title: "目標を端末へ保存", saved: saved) }.buttonStyle(.borderedProminent).foregroundStyle(Color(uiColor: pendingGoal == nil ? .systemBackground : .label)).disabled(pendingGoal != nil).accessibilityLabel(saved ? "目標を保存しました" : "目標を端末へ保存")
      if !pendingMessage.isEmpty { Text(pendingMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("goal-editor-pending") }
      if !error.isEmpty { Text(error).foregroundStyle(.red).accessibilityIdentifier("goal-editor-error") }
    }.navigationTitle("固定目標の設定")
    .navigationBarBackButtonHidden(true)
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("戻る") { if hasUnsavedInput { confirmBack = true } else { dismiss() } }
          .accessibilityIdentifier("goal-editor-back")
      }
      ToolbarItemGroup(placement: .keyboard) {
        Spacer(); Button("入力を終える") { focusedField = nil }
      }
    }
    .alert("変更を破棄して戻りますか？", isPresented: $confirmBack) {
      Button("破棄して戻る", role: .destructive) { dismiss() }
      Button("続ける", role: .cancel) {}
    } message: { Text(pendingGoal == nil ? "まだ保存していない目標の入力が消えます。" : "最後に保存した後の入力が消えます。送信待ちの設定は残ります。") }
    .onChange(of: draft) { _, _ in saved = false; error = "" }
  }
}
private struct ManualGoalEditor: View {
  let model: PlanningScreenModel, date: String
  @Environment(\.dismiss) private var dismiss
  private struct Draft: Equatable {
    var reason = "", kcal = "", protein = "", fat = "", carbohydrate = ""
  }
  @State private var reason = ""
  @State private var kcal = ""
  @State private var protein = ""
  @State private var fat = ""
  @State private var carbohydrate = ""
  @State private var error = ""
  @State private var saved = false
  @State private var acceptedDraft: Draft
  @State private var confirmBack = false
  @FocusState private var focusedField: String?
  init(model: PlanningScreenModel, date: String) {
    self.model = model; self.date = date
    let waiting = model.pending.first { $0.operation.planning?.dailyGoal?.date == date }?.operation.planning?.dailyGoal?.manual.last
    let initial = waiting.map { Draft(reason: $0.reason, kcal: planningValueText($0.delta.kcal),
      protein: planningValueText($0.delta.protein), fat: planningValueText($0.delta.fat),
      carbohydrate: planningValueText($0.delta.carbohydrate)) } ?? Draft()
    _reason = State(initialValue: initial.reason); _kcal = State(initialValue: initial.kcal)
    _protein = State(initialValue: initial.protein); _fat = State(initialValue: initial.fat)
    _carbohydrate = State(initialValue: initial.carbohydrate); _acceptedDraft = State(initialValue: initial)
  }
  private var draft: Draft { .init(reason: reason, kcal: kcal, protein: protein, fat: fat, carbohydrate: carbohydrate) }
  private var hasUnsavedInput: Bool { draft != acceptedDraft }
  private var pendingAdjustment: Pending? { model.pending.first { $0.operation.planning?.dailyGoal?.date == date } }
  private var pendingMessage: String {
    switch pendingAdjustment?.state {
    case .queued: "この日の調整は送信待ちです。完了後に再保存できます。"
    case .authentication: "この日の調整は再接続待ちです。Googleへ再接続してください。"
    case .invalid, .conflict: "この日の調整は要確認です。送信待ちから内容を確認してください。"
    case nil: ""
    }
  }
  var body: some View {
    Form {
      Text("\(mockDay(date))だけの手動調整")
      TextField("調整の理由", text: $reason).focused($focusedField, equals: "reason")
        .accessibilityIdentifier("manual-goal-reason")
      nutrientFields(kcal: $kcal, protein: $protein, fat: $fat, carbohydrate: $carbohydrate, focus: $focusedField).motionFieldError(error)
      Text("増減値を入力してください。空欄は調整なしです。").font(.caption)
      Button {
        do {
          saved = model.manual(date: date, reason: reason, delta: try .init(kcal: planningNumber(kcal) ?? 0,
            protein: planningNumber(protein) ?? 0, fat: planningNumber(fat) ?? 0, carbohydrate: planningNumber(carbohydrate) ?? 0))
          error = saved ? "" : model.message
          if saved { acceptedDraft = draft; focusedField = nil; Haptics.emit(.success) }
        } catch { self.error = error.localizedDescription }
      } label: { MotionSaveLabel(title: "調整を端末へ保存", saved: saved) }
      .buttonStyle(.borderedProminent).foregroundStyle(Color(uiColor: pendingAdjustment == nil ? .systemBackground : .label))
      .disabled(pendingAdjustment != nil).accessibilityIdentifier("manual-goal-save")
      .accessibilityLabel(saved ? "調整を保存しました" : "調整を端末へ保存")
      if !pendingMessage.isEmpty { Text(pendingMessage).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("manual-goal-pending") }
      if !error.isEmpty { Text(error).foregroundStyle(.red).accessibilityIdentifier("manual-goal-error") }
    }.navigationTitle("手動調整").navigationBarBackButtonHidden(true)
    .scrollDismissesKeyboard(.interactively)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("戻る") { if hasUnsavedInput { confirmBack = true } else { dismiss() } }
          .accessibilityIdentifier("manual-goal-back")
      }
      ToolbarItemGroup(placement: .keyboard) {
        Spacer(); Button("入力を終える") { focusedField = nil }
      }
    }
    .alert("変更を破棄して戻りますか？", isPresented: $confirmBack) {
      Button("破棄して戻る", role: .destructive) { dismiss() }
      Button("続ける", role: .cancel) {}
    } message: { Text(pendingAdjustment == nil ? "まだ保存していない調整の入力が消えます。" : "最後に保存した後の入力が消えます。送信待ちの調整は残ります。") }
    .onChange(of: draft) { _, _ in saved = false; error = "" }
  }
}
struct SupplementPage: View {
  let model: PlanningScreenModel, date: String
  @State private var editing: SupplementDay?
  var body: some View {
    Page(title: "サプリの自動計上") {
      Text(mockDay(date)).foregroundStyle(.secondary)
      Text("予定の設定・変更は会話で行います。毎日の服用確認は不要です。").font(.subheadline)
      if let ledger = try? model.supplements() {
        if ledger.plans.isEmpty { Card { Text("予定はまだありません"); Text("商品名・日量・成分・開始日を会話から登録します。").font(.caption).foregroundStyle(.secondary) } }
        ForEach(ledger.days.filter { $0.date == date }) { day in
          Card {
            Text(day.productName).font(.headline)
            Text("\(foodNumber(day.amount)) \(day.unit)")
            Text(day.state == .planned ? "予定から自動計上・服用確認なし" : day.state == .confirmed ? "服用確認済み" : "この日は除外")
              .font(.caption).foregroundStyle(.secondary)
            if let pending = waitingChange(day), let changed = pending.operation.planning?.day {
              Text("\(pendingTitle(pending.state))：\(foodNumber(changed.amount)) \(changed.unit)")
                .font(.subheadline).accessibilityIdentifier("supplement-pending-amount")
              Text("この日の変更が終わるまで、再変更はできません。")
                .font(.caption).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
              HStack { dayActions(day) }.fixedSize(horizontal: true, vertical: false)
              VStack(alignment: .leading) { dayActions(day) }
            }.buttonStyle(.bordered).disabled(waitingChange(day) != nil)
          }
        }
        ForEach(ledger.plans.sorted { $0.revision > $1.revision }.filter { p in
          p.effectiveFrom <= date && (p.effectiveThrough.map { date <= $0 } ?? true) &&
            !ledger.plans.contains { $0.planID == p.planID && $0.revision > p.revision && $0.effectiveFrom <= date }
        }) { p in
          Card {
            Text(ledger.products.first { $0.id == p.productVersionID }?.name ?? "商品情報を確認")
            Text("日量 \(foodNumber(p.dailyAmount)) · 適用 \(p.effectiveFrom)〜\(p.effectiveThrough ?? "継続")").font(.caption)
            Text(p.autoCount ? "自動計上オン" : "自動計上オフ").font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      PlanningQueueCard(model: model)
    }.sheet(item: $editing) { SupplementAmountEditor(model: model, day: $0, close: { editing = nil }) }
  }
  private func waitingChange(_ day: SupplementDay) -> Pending? {
    model.pending.first { $0.operation.planning?.day?.id == day.id }
  }
  private func pendingTitle(_ state: PendingState) -> String {
    switch state {
    case .queued: "送信待ち"
    case .authentication: "再接続が必要"
    case .invalid, .conflict: "要確認"
    }
  }
  @ViewBuilder private func dayActions(_ day: SupplementDay) -> some View {
    Button("この日だけ量を変更") { editing = day }
    Button(day.state == .excluded ? "服用を報告" : "飲まなかった") {
      model.change(day, state: day.state == .excluded ? .confirmed : .excluded)
    }
  }
}
private struct SupplementAmountEditor: View {
  let model: PlanningScreenModel, day: SupplementDay
  let close: () -> Void
  @State private var amount: String
  @State private var error = ""
  @State private var confirmClose = false
  init(model: PlanningScreenModel, day: SupplementDay, close: @escaping () -> Void) { self.model = model; self.day = day; self.close = close; _amount = State(initialValue: foodNumber(day.amount)) }
  private var hasInput: Bool { amount != foodNumber(day.amount) }
  var body: some View {
    NavigationStack {
      Form {
        Text("\(mockDay(day.date)) · \(day.productName)")
        TextField(day.unit, text: $amount).keyboardType(.decimalPad)
        Button("この日だけ変更を保存") {
          do { guard let value = try planningNumber(amount) else { throw SupplementFailure.invalidValue }
            if model.change(day, amount: value, state: day.state) { Haptics.emit(.success); close() }
            else { error = model.message }
          } catch { self.error = error.localizedDescription }
        }.buttonStyle(.borderedProminent).foregroundStyle(Color(uiColor: .systemBackground))
        if !error.isEmpty { Text(error).foregroundStyle(.red).accessibilityIdentifier("supplement-amount-error") }
      }.navigationTitle("量の例外").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { if hasInput { confirmClose = true } else { close() } } } }
    }
    .interactiveDismissDisabled(hasInput)
    .alert("変更を破棄して閉じますか？", isPresented: $confirmClose) {
      Button("破棄して閉じる", role: .destructive) { close() }
      Button("続ける", role: .cancel) {}
    } message: { Text("まだ保存していない量の変更が消えます。") }
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
          if let rule = p.operation.planning?.goalRule {
            Text("\(mockDay(rule.effectiveFrom))から · \(foodNumber(rule.base.kcal)) kcal")
              .font(.caption).accessibilityIdentifier("planning-pending-goal-values")
          }
          if let goal = p.operation.planning?.dailyGoal, let adjustment = goal.manual.last {
            Text("\(mockDay(goal.date)) · 調整後 \(foodNumber(goal.total.kcal)) kcal · \(adjustment.reason)")
              .font(.caption).accessibilityIdentifier("planning-pending-manual-values")
          }
          Text(p.message).font(.caption).foregroundStyle(.secondary)
          if p.state == .queued && p.attempts == 0 { Button("未送信の変更を取消") { model.cancel(p.id) }.buttonStyle(.bordered) }
        }
      }
    }
    if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
  }
}
private func planningValueText(_ value: Double?) -> String {
  value.map { $0.rounded() == $0 ? String(Int($0)) : String($0) } ?? ""
}
private func planningNumber(_ text: String) throws -> Double? {
  let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if value.isEmpty { return nil }
  guard let number = Double(value), number.isFinite else { throw GoalFailure.invalidValue }; return number
}
@ViewBuilder private func nutrientFields(kcal: Binding<String>, protein: Binding<String>, fat: Binding<String>, carbohydrate: Binding<String>, focus: FocusState<String?>.Binding? = nil) -> some View {
  LabeledContent("カロリー（kcal）") { nutrientField("kcal", text: kcal, key: "kcal", focus: focus) }
  LabeledContent("P（g）") { nutrientField("P g（任意）", text: protein, key: "protein", focus: focus) }
  LabeledContent("F（g）") { nutrientField("F g（任意）", text: fat, key: "fat", focus: focus) }
  LabeledContent("C（g）") { nutrientField("C g（任意）", text: carbohydrate, key: "carbohydrate", focus: focus) }
}
@ViewBuilder private func nutrientField(_ title: String, text: Binding<String>, key: String, focus: FocusState<String?>.Binding?) -> some View {
  let field = TextField(title, text: text).keyboardType(.numbersAndPunctuation)
    .multilineTextAlignment(.trailing).accessibilityIdentifier(title)
  if let focus { field.focused(focus, equals: key) } else { field }
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
