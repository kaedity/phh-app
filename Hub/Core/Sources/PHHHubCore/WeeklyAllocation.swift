import Foundation

public enum WeeklyAllocationFailure: String, Error, LocalizedError {
  case invalidValue, settingsRequired, noEligibleDays, noRemainingDays, missingFutureGoal, pendingFutureChanges
  public var errorDescription: String? {
    switch self {
    case .invalidValue: "試算の日付・係数・上限を確認してください。係数は0〜1、上限は0以上で入力してください。"
    case .settingsRequired: "試算に使う係数と1日の上限を、両方入力してください。"
    case .noEligibleDays: "記録完了と摂取量・目標がそろう日がありません。"
    case .noRemainingDays: "この週には翌日以降の残り日がありません。"
    case .missingFutureGoal: "残り日の目標が未設定です。配分後の目標を試算できません。"
    case .pendingFutureChanges: "残り日の目標・関連する記録に確定待ちの変更があります。確定後に再計算してください。"
    }
  }
}

public struct WeeklyAllocationDay: Equatable, Sendable {
  public let date: String
  public let completion: FoodDay?
  public let consumedKcal: Double?
  public let goalKcal: Double?
  public let hasPendingChanges: Bool

  public init(
    date: String, completion: FoodDay? = nil, consumedKcal: Double?, goalKcal: Double?,
    hasPendingChanges: Bool = false
  ) throws {
    self.date = date; self.completion = completion; self.consumedKcal = consumedKcal
    self.goalKcal = goalKcal; self.hasPendingChanges = hasPendingChanges
    try validate()
  }

  public func validate() throws {
    try FoodRules.date(date)
    if let completion { try completion.validate(); guard completion.date == date else { throw WeeklyAllocationFailure.invalidValue } }
    guard [consumedKcal, goalKcal].allSatisfy({
      $0.map { $0.isFinite && $0 >= 0 && $0 <= 100_000 } ?? true
    }) else { throw WeeklyAllocationFailure.invalidValue }
  }
}

public enum WeeklyAllocationExclusion: String, Equatable, Sendable {
  case notCompleted, changedAfterCompletion, intakeUnknown, goalUnknown, pendingChanges, future
  public var title: String {
    switch self {
    case .notCompleted: "記録未完了"
    case .changedAfterCompletion: "完了後に変更あり"
    case .intakeUnknown: "摂取kcalが不明"
    case .goalUnknown: "目標kcalが未設定"
    case .pendingChanges: "確定待ちの変更あり"
    case .future: "翌日以降"
    }
  }
}

public struct WeeklyAllocationDayResult: Equatable, Identifiable, Sendable {
  public var id: String { date }
  public let date: String, consumedKcal: Double?, goalKcal: Double?, differenceKcal: Double?
  public let exclusions: [WeeklyAllocationExclusion]
  public var isIncluded: Bool { exclusions.isEmpty }
}

public struct WeeklyAllocationReport: Equatable, Sendable {
  public let weekStart: String, weekEnd: String, asOf: String
  public let days: [WeeklyAllocationDayResult]
  /// 0件はnilです。完了済みの既知0だけは集計に使えます。
  public let includedIntakeKcal: Double?, includedGoalKcal: Double?, differenceKcal: Double?
  public var includedDayCount: Int { days.filter(\.isIncluded).count }
  public var remainingDayCount: Int { days.filter { $0.date > asOf }.count }
}

/// 本人がこの試算のために入力した値だけを持ちます。採用済みの設定ではありません。
public struct WeeklyAllocationSettings: Equatable, Sendable {
  public let coefficient: Double, dailyCapKcal: Double
  public init(coefficient: Double?, dailyCapKcal: Double?) throws {
    guard let coefficient, let dailyCapKcal else { throw WeeklyAllocationFailure.settingsRequired }
    guard coefficient.isFinite, (0...1).contains(coefficient), dailyCapKcal.isFinite,
      (0...100_000).contains(dailyCapKcal)
    else { throw WeeklyAllocationFailure.invalidValue }
    self.coefficient = coefficient; self.dailyCapKcal = dailyCapKcal
  }
}

public struct WeeklyAllocationPreviewDay: Equatable, Identifiable, Sendable {
  public var id: String { date }
  public let date: String
  public let baseGoalKcal: Double, adjustmentKcal: Double, previewGoalKcal: Double
}

public struct WeeklyAllocationPreview: Equatable, Sendable {
  public let settings: WeeklyAllocationSettings
  public let days: [WeeklyAllocationPreviewDay]
  public let requestedAdjustmentKcal: Double, allocatedAdjustmentKcal: Double
  public let unallocatedAdjustmentKcal: Double, remainingDifferenceKcal: Double
}

/// 読み取った記録を集計し、入力条件で試算するだけです。目標・食事の更新APIを持ちません。
public enum WeeklyAllocation {
  private static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return value
  }
  private static var formatter: DateFormatter {
    let value = DateFormatter()
    value.locale = Locale(identifier: "en_US_POSIX")
    value.timeZone = calendar.timeZone
    value.dateFormat = "yyyy-MM-dd"
    value.isLenient = false
    return value
  }

  /// 選択日の暦週（月曜〜日曜）。自動補正の参照期間を設定する操作ではありません。
  public static func weekDates(asOf: String) throws -> [String] {
    try FoodRules.date(asOf)
    let selected = formatter.date(from: asOf)!
    let offset = (calendar.component(.weekday, from: selected) + 5) % 7
    return (0..<7).map { day in
      formatter.string(from: calendar.date(byAdding: .day, value: day - offset, to: selected)!)
    }
  }

  public static func evaluate(asOf: String, days: [WeeklyAllocationDay]) throws -> WeeklyAllocationReport {
    let dates = try weekDates(asOf: asOf)
    guard Set(days.map(\.date)).count == days.count else { throw WeeklyAllocationFailure.invalidValue }
    for day in days { try day.validate() }
    let byDate = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
    var results: [WeeklyAllocationDayResult] = []
    for date in dates {
      let input = byDate[date]
      var reasons: [WeeklyAllocationExclusion] = []
      if date > asOf {
        reasons = [.future]
        if input?.hasPendingChanges == true { reasons.append(.pendingChanges) }
        if input?.goalKcal == nil { reasons.append(.goalUnknown) }
      }
      else {
        if input?.completion?.eligibleForPeriodAdjustment != true {
          reasons.append(input?.completion?.status == .changed ? .changedAfterCompletion : .notCompleted)
        }
        if input?.hasPendingChanges == true { reasons.append(.pendingChanges) }
        if input?.consumedKcal == nil { reasons.append(.intakeUnknown) }
        if input?.goalKcal == nil { reasons.append(.goalUnknown) }
      }
      let delta = reasons.isEmpty ? input!.consumedKcal! - input!.goalKcal! : nil
      results.append(.init(
        date: date, consumedKcal: input?.consumedKcal, goalKcal: input?.goalKcal,
        differenceKcal: delta, exclusions: reasons))
    }
    let included = results.filter(\.isIncluded)
    return .init(
      weekStart: dates[0], weekEnd: dates[6], asOf: asOf, days: results,
      includedIntakeKcal: included.isEmpty ? nil : included.reduce(0) { $0 + $1.consumedKcal! },
      includedGoalKcal: included.isEmpty ? nil : included.reduce(0) { $0 + $1.goalKcal! },
      differenceKcal: included.isEmpty ? nil : included.reduce(0) { $0 + $1.differenceKcal! })
  }

  public static func preview(
    report: WeeklyAllocationReport, coefficient: Double?, dailyCapKcal: Double?
  ) throws -> WeeklyAllocationPreview {
    let settings = try WeeklyAllocationSettings(coefficient: coefficient, dailyCapKcal: dailyCapKcal)
    guard let difference = report.differenceKcal, report.includedDayCount > 0 else {
      throw WeeklyAllocationFailure.noEligibleDays
    }
    let remaining = report.days.filter { $0.date > report.asOf }
    guard !remaining.isEmpty else { throw WeeklyAllocationFailure.noRemainingDays }
    guard !remaining.contains(where: { $0.exclusions.contains(.pendingChanges) }) else {
      throw WeeklyAllocationFailure.pendingFutureChanges
    }
    guard remaining.allSatisfy({ $0.goalKcal != nil }) else { throw WeeklyAllocationFailure.missingFutureGoal }
    let requested = -difference * settings.coefficient
    let equalShare = requested / Double(remaining.count)
    let capped = max(-settings.dailyCapKcal, min(settings.dailyCapKcal, equalShare))
    let days: [WeeklyAllocationPreviewDay] = remaining.map { day in
      let base = day.goalKcal!
      // 日上限と目標0の下限を守り、上限に当たった量を別日に隠れて再配分しません。
      let adjustment = max(-base, min(100_000 - base, capped))
      return .init(date: day.date, baseGoalKcal: base, adjustmentKcal: adjustment, previewGoalKcal: base + adjustment)
    }
    let allocated = days.reduce(0) { $0 + $1.adjustmentKcal }
    return .init(
      settings: settings, days: days, requestedAdjustmentKcal: requested,
      allocatedAdjustmentKcal: allocated, unallocatedAdjustmentKcal: requested - allocated,
      remainingDifferenceKcal: difference + allocated)
  }
}
