import PHHHubCore
import SwiftUI

/// G04は端末の確定値の読み取りと一時的な試算だけです。目標の保存や有効化を行いません。
struct WeeklyAllocationPage: View {
  let hub: HubStore
  let planning: PlanningScreenModel
  let preview: Bool
  @State private var selectedDate: Date
  @State private var report: WeeklyAllocationReport?
  @State private var trial: WeeklyAllocationPreview?
  @State private var coefficient = ""
  @State private var dailyCap = ""
  @State private var message = ""
  @State private var usingPreview = false

  init(hub: HubStore, planning: PlanningScreenModel, date: String, preview: Bool = false) {
    self.hub = hub; self.planning = planning; self.preview = preview
    _selectedDate = State(initialValue: FoodDates.date(date))
  }

  var body: some View {
    HubMockPage(title: "週内の配分を試算", showNavigation: true) {
      HubMockCard {
        Text("自動補正：オフ").font(.headline).accessibilityIdentifier("weekly-allocation-off")
        Text("係数と上限は合意待ちです。ここで入力する値は、この画面での試算だけに使います。")
          .font(.subheadline).foregroundStyle(.secondary)
        DatePicker("集計する日", selection: $selectedDate, in: ...Date(), displayedComponents: .date)
          .accessibilityIdentifier("weekly-allocation-date")
        Text("選択日の月曜〜日曜を表示します。選択日までの記録完了日で、摂取量と目標がそろう日だけを集計します。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let report {
        summary(report)
        trialSettings
        if let trial { trialResult(trial) }
        evidence(report)
      }
      if !message.isEmpty {
        HubMockCard {
          Text(message).font(.subheadline).foregroundStyle(.secondary)
            .accessibilityIdentifier("weekly-allocation-message")
        }
      }
      Button("端末の記録を読み直す") { usingPreview = false; reload() }
        .accessibilityIdentifier("weekly-allocation-refresh")
      #if DEBUG
        if preview {
          Button("架空の週間記録を表示") { showPreview() }
            .accessibilityIdentifier("weekly-allocation-preview-sample")
        }
      #endif
    }
    .task { reload() }
    .onChange(of: selectedDate) { _, _ in usingPreview = false; reload() }
    .onChange(of: coefficient) { _, _ in trial = nil; message = "" }
    .onChange(of: dailyCap) { _, _ in trial = nil; message = "" }
  }

  private func summary(_ report: WeeklyAllocationReport) -> some View {
    HubMockCard {
      Text(usingPreview ? "架空データの週間集計" : "完了日の週間集計").font(.headline)
      Text("\(report.weekStart) 〜 \(report.weekEnd)").font(.subheadline)
      Text("計算に使えた日：\(report.includedDayCount)日 · 翌日以降の残り：\(report.remainingDayCount)日")
        .font(.caption).foregroundStyle(.secondary)
      if let difference = report.differenceKcal {
        Text("摂取 − 目標：\(signed(difference)) kcal").font(.title2.bold())
          .accessibilityIdentifier("weekly-allocation-difference")
        Text("同じ完了日の摂取 \(foodNumber(report.includedIntakeKcal)) kcal / 目標 \(foodNumber(report.includedGoalKcal)) kcal")
          .font(.subheadline)
      } else {
        Text("計算に使える記録がありません。").font(.subheadline)
          .accessibilityIdentifier("weekly-allocation-unavailable")
      }
      Text("未完了・完了後の変更・不明な値・確定待ちがある日は、日別の確認事項に表示します。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var trialSettings: some View {
    HubMockCard {
      Text("この画面だけの試算条件").font(.headline)
      LabeledContent("係数（0〜1）") {
        TextField("未設定", text: $coefficient).keyboardType(.decimalPad)
          .accessibilityIdentifier("weekly-allocation-coefficient")
      }
      LabeledContent("1日の上限（kcal）") {
        TextField("未設定", text: $dailyCap).keyboardType(.decimalPad)
          .accessibilityIdentifier("weekly-allocation-cap")
      }
      Text("1日あたりの試算は、−（完了日の差分 × 係数）÷ 残り日数です。上限と目標0の下限で制限します。")
        .font(.caption).foregroundStyle(.secondary)
      Text("参照期間・最低完了日数・PFCへの配分ルールは合意待ちです。試算しても目標や記録は変更されません。")
        .font(.caption).foregroundStyle(.secondary)
      Button("入力条件で試算する") { calculateTrial() }
        .disabled(coefficient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          || dailyCap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("weekly-allocation-calculate")
    }
  }

  private func trialResult(_ trial: WeeklyAllocationPreview) -> some View {
    HubMockCard {
      Text("配分の試算").font(.headline)
      Text("係数 \(foodNumber(trial.settings.coefficient)) · 日上限 \(foodNumber(trial.settings.dailyCapKcal)) kcal")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(trial.days) { day in
        VStack(alignment: .leading, spacing: 4) {
          Text(day.date).font(.subheadline.bold())
          Text("現在 \(foodNumber(day.baseGoalKcal)) ＋ 試算 \(signed(day.adjustmentKcal)) ＝ \(foodNumber(day.previewGoalKcal)) kcal")
            .font(.subheadline)
        }.accessibilityElement(children: .combine)
          .accessibilityIdentifier("weekly-allocation-trial-\(day.date)")
      }
      Text("配分した量：\(signed(trial.allocatedAdjustmentKcal)) kcal")
        .font(.subheadline).accessibilityIdentifier("weekly-allocation-allocated")
      Text("上限等で配りきれない量：\(foodNumber(abs(trial.unallocatedAdjustmentKcal))) kcal")
        .font(.caption).foregroundStyle(.secondary)
      Text("試算後の差分：\(signed(trial.remainingDifferenceKcal)) kcal")
        .font(.subheadline).accessibilityIdentifier("weekly-allocation-remaining")
    }.accessibilityIdentifier("weekly-allocation-trial")
  }

  private func evidence(_ report: WeeklyAllocationReport) -> some View {
    HubMockCard {
      Text("日別の確認事項").font(.headline)
      ForEach(report.days) { day in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(day.date).font(.subheadline.bold())
            Spacer()
            Text(day.isIncluded ? "計算に使用" : day.exclusions.map(\.title).joined(separator: "・"))
              .font(.caption).foregroundStyle(.secondary)
          }
          Text("摂取 \(foodNumber(day.consumedKcal)) / 目標 \(foodNumber(day.goalKcal)) kcal")
            .font(.caption).foregroundStyle(.secondary)
          if let delta = day.differenceKcal { Text("差分 \(signed(delta)) kcal").font(.caption) }
        }.accessibilityElement(children: .combine)
          .accessibilityIdentifier("weekly-allocation-day-\(day.date)")
      }
    }
  }

  private func calculateTrial() {
    guard let report else { return }
    do {
      trial = try WeeklyAllocation.preview(
        report: report, coefficient: FoodLabelParser.inputNumber(coefficient),
        dailyCapKcal: FoodLabelParser.inputNumber(dailyCap))
      message = ""
    } catch { trial = nil; message = error.localizedDescription }
  }

  private func reload() {
    trial = nil
    do {
      try planning.refresh()
      let asOf = FoodDates.text(selectedDate)
      let dates = try WeeklyAllocation.weekDates(asOf: asOf)
      let pending = try hub.pending()
      var inputs: [WeeklyAllocationDay] = []
      for day in dates {
        let summaries = try hub.rows(table: "DailySummary", date: day).filter(\.active)
        guard summaries.count <= 1 else { throw HubError.invalidResponse }
        let consumed = try planning.consumedWithSupplements(planningConsumed(summary: summaries.first), date: day)
        let target = try planning.goal(day)
        let mealIDs = Set(try hub.rows(table: "Meals", date: day).map(\.entityID))
        let changing = pending.contains { entry in
          let operation = entry.operation, mutation = operation.planning
          return operation.foodMeal?.date == day || operation.payload?.local_date == day
            || mealIDs.contains(operation.entity_id) || mutation?.foodDay?.date == day
            || mutation?.day?.date == day || mutation?.dailyGoal?.date == day
            || mutation?.plan != nil || mutation?.product != nil || mutation?.goalRule != nil
        }
        inputs.append(try .init(
          date: day, completion: planning.foodDay(day), consumedKcal: consumed.kcal,
          goalKcal: target?.total.kcal, hasPendingChanges: changing))
      }
      report = try WeeklyAllocation.evaluate(asOf: asOf, days: inputs)
      message = ""
    } catch { report = nil; message = "対象の記録を確認できません。\(error.localizedDescription)" }
  }

  private func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + foodNumber(value) }

  #if DEBUG
    private func showPreview() {
      do {
        let asOf = FoodDates.text(selectedDate), dates = try WeeklyAllocation.weekDates(asOf: asOf)
        let inputs = try dates.map { day -> WeeklyAllocationDay in
          let completion = day == asOf ? try FoodDay.completed(date: day, operationID: UUID().uuidString, at: .now) : nil
          return try .init(date: day, completion: completion, consumedKcal: day == asOf ? 2600 : nil, goalKcal: 2000)
        }
        report = try WeeklyAllocation.evaluate(asOf: asOf, days: inputs)
        usingPreview = true; trial = nil; message = ""
      } catch { message = error.localizedDescription }
    }
  #endif
}
