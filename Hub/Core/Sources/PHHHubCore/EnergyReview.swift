import Foundation

public enum EnergyReviewFailure: Error, LocalizedError {
    case invalidValue, duplicateDate
    public var errorDescription: String? {
        switch self {
        case .invalidValue: "見直しの対象日・摂取量・体重を確認してください。"
        case .duplicateDate: "同じ日の記録が複数あります。採用する記録を確認してください。"
        }
    }
}

/// 食事・サプリを含む確定摂取量。未確定の変更があれば完了済みの日も採用しません。
public struct EnergyReviewIntakeDay: Equatable, Sendable {
    public let day: FoodDay
    public let kcal: Double?
    public let hasPendingChanges: Bool
    public var date: String { day.date }
    public init(day: FoodDay, kcal: Double?, hasPendingChanges: Bool = false) throws {
        try day.validate()
        guard kcal.map({ $0.isFinite && $0 >= 0 }) ?? true else { throw EnergyReviewFailure.invalidValue }
        self.day = day; self.kcal = kcal; self.hasPendingChanges = hasPendingChanges
    }
    /// 一部不明の栄養を既知分の合計で置き換えません。
    public init(day: FoodDay, total: FoodTotal, hasPendingChanges: Bool = false) throws {
        try self.init(day: day, kcal: (total.missing[.kcal] ?? 0) == 0 ? total.known[.kcal] : nil,
                      hasPendingChanges: hasPendingChanges)
    }
}

/// HealthKitには飲食前・トイレ後のフラグがないため、朝の測定は呼出側が明示確認します。
public struct EnergyReviewWeightDay: Equatable, Sendable {
    public let date: String, sampleID: String, sourceID: String
    public let kilograms: Double, morningMeasurementConfirmed: Bool
    public init(date: String, sampleID: String, sourceID: String, kilograms: Double,
                morningMeasurementConfirmed: Bool) throws {
        try FoodRules.date(date); try FoodRules.id(sampleID)
        guard !sourceID.isEmpty, sourceID.count <= 500, kilograms.isFinite, kilograms > 0
        else { throw EnergyReviewFailure.invalidValue }
        self.date = date; self.sampleID = sampleID; self.sourceID = sourceID
        self.kilograms = kilograms; self.morningMeasurementConfirmed = morningMeasurementConfirmed
    }
    public init(healthDay: HealthWeightDay, morningMeasurementConfirmed: Bool) throws {
        try self.init(date: healthDay.date, sampleID: healthDay.representativeID,
                      sourceID: healthDay.sourceID, kilograms: healthDay.value,
                      morningMeasurementConfirmed: morningMeasurementConfirmed)
    }
}

public struct EnergyReviewPeriod: Equatable, Sendable {
    public let start: String, end: String, dates: [String]
    public var dayCount: Int { dates.count }
    fileprivate init(_ dates: [String]) { self.dates = dates; start = dates.first!; end = dates.last! }
}
public enum EnergyReviewExclusion: String, Equatable, Sendable {
    case incomplete, changedAfterCompletion, intakeUnknown, pendingChanges, weightMissing, morningUnconfirmed
    public var title: String {
        switch self {
        case .incomplete: "記録が未完了"
        case .changedAfterCompletion: "完了後に記録を変更"
        case .intakeUnknown: "摂取カロリーが不明"
        case .pendingChanges: "変更の確定待ち"
        case .weightMissing: "体重が未記録"
        case .morningUnconfirmed: "朝の測定を未確認"
        }
    }
}
public struct EnergyReviewExcludedDay: Equatable, Sendable, Identifiable {
    public let date: String, reasons: [EnergyReviewExclusion]
    public var id: String { date }
}
public struct EnergyReviewWeightAverage: Equatable, Sendable {
    public let period: EnergyReviewPeriod, representativeDate: String
    public let kilograms: Double
    public let sampleIDs: [String]
}
public struct EnergyReviewTrend: Equatable, Sendable {
    public let before: EnergyReviewWeightAverage, after: EnergyReviewWeightAverage
    public let elapsedDays: Int, changeKilograms: Double, weeklyChangeKilograms: Double
    public let weeklyChangePercent: Double
}
public struct EnergyReviewMaintenance: Equatable, Sendable {
    public let period: EnergyReviewPeriod, trend: EnergyReviewTrend
    public let averageIntakeKcal: Double, estimatedMaintenanceKcal: Double
    public let kilogramsToKcal: Double
    public let intakeKcalByDate: [String: Double]
}
public struct EnergyReviewKcalRange: Equatable, Sendable {
    public let lower: Double, upper: Double
    fileprivate init(_ lower: Double, _ upper: Double) { self.lower = lower; self.upper = upper }
}
public enum EnergyReviewProposalKind: String, Equatable, Sendable {
    case measuredTarget, increase, decrease, keep
}
public struct EnergyReviewProposal: Equatable, Sendable {
    public let kind: EnergyReviewProposalKind, reason: String, proposedEffectiveFrom: String
    public let targetKcal: EnergyReviewKcalRange?
    public let adjustmentKcal: EnergyReviewKcalRange?
}
public struct EnergyReviewReport: Equatable, Sendable {
    public let reviewedOn: String, context: EnergyReviewPeriod
    public let eligibleDates: [String], excludedDays: [EnergyReviewExcludedDay]
    public let weeklyReviewDue: Bool, nextWeeklyReviewOn: String
    public let initialAdjustmentDue: Bool, nextInitialAdjustmentOn: String?
    public let initialTrend: EnergyReviewTrend?, maintenance: EnergyReviewMaintenance?
    public let proposal: EnergyReviewProposal?, reasons: [String]
    /// この結果は書込み操作や変更済みのGoalRuleを持ちません。
    public let calculationVersion = "energy-review-g02-v1"
}

/// DESIGN 6章の増量期だけを扱います。欠測許容・活動補正・PFCの再配分は採用しません。
public enum EnergyReview {
    public static let kilogramsToKcal = 7_700.0

    /// 当日は途中の記録なので対象から外し、直前21暦日だけを調べます。
    public static func contextDates(asOf: String) throws -> [String] {
        try FoodRules.date(asOf)
        return try (-21 ... -1).map { try shifted(asOf, by: $0) }
    }

    public static func evaluate(asOf: String, goal: GoalRule?, intakeDays: [EnergyReviewIntakeDay],
                                weights: [EnergyReviewWeightDay], lastReviewedOn: String? = nil,
                                lastInitialAdjustmentReviewedOn: String? = nil) throws -> EnergyReviewReport {
        let dates = try contextDates(asOf: asOf)
        guard Set(intakeDays.map(\.date)).count == intakeDays.count,
              Set(weights.map(\.date)).count == weights.count else { throw EnergyReviewFailure.duplicateDate }
        if let goal { try goal.validate() }
        for last in [lastReviewedOn, lastInitialAdjustmentReviewedOn].compactMap({ $0 }) {
            try FoodRules.date(last)
            guard last <= asOf else { throw EnergyReviewFailure.invalidValue }
        }
        let intakes = Dictionary(uniqueKeysWithValues: intakeDays.map { ($0.date, $0) })
        let weightDays = Dictionary(uniqueKeysWithValues: weights.map { ($0.date, $0) })
        var excluded: [EnergyReviewExcludedDay] = [], eligible: [String] = []
        for date in dates {
            var missing: [EnergyReviewExclusion] = []
            if let intake = intakes[date] {
                if !intake.day.eligibleForPeriodAdjustment {
                    missing.append(intake.day.status == .changed ? .changedAfterCompletion : .incomplete)
                }
                if intake.kcal == nil { missing.append(.intakeUnknown) }
                if intake.hasPendingChanges { missing.append(.pendingChanges) }
            } else { missing.append(.incomplete) }
            if let weight = weightDays[date] {
                if !weight.morningMeasurementConfirmed { missing.append(.morningUnconfirmed) }
            } else { missing.append(.weightMissing) }
            if missing.isEmpty { eligible.append(date) }
            else { excluded.append(.init(date: date, reasons: missing)) }
        }
        let eligibleSet = Set(eligible), last14 = Array(dates.suffix(14))
        var reasons: [String] = []
        func trend(for window: [String]) throws -> EnergyReviewTrend? {
            guard window.allSatisfy(eligibleSet.contains) else { return nil }
            let values = window.compactMap { weightDays[$0] }
            guard Set(values.map(\.sourceID)).count == 1 else {
                reasons.append("体重の取得元が途中で変わっています。同じ取得元の朝測定を選んでください。")
                return nil
            }
            func average(_ part: [String]) -> EnergyReviewWeightAverage {
                .init(period: .init(part), representativeDate: part[3],
                      kilograms: part.reduce(0) { $0 + weightDays[$1]!.kilograms } / 7,
                      sampleIDs: part.map { weightDays[$0]!.sampleID })
            }
            let before = average(Array(window.prefix(7))), after = average(Array(window.suffix(7)))
            let days = try distance(before.representativeDate, after.representativeDate)
            let change = after.kilograms - before.kilograms, weekly = change * 7 / Double(days)
            guard before.kilograms.isFinite, after.kilograms.isFinite, weekly.isFinite
            else { throw EnergyReviewFailure.invalidValue }
            return .init(before: before, after: after, elapsedDays: days, changeKilograms: change,
                         weeklyChangeKilograms: weekly, weeklyChangePercent: weekly / before.kilograms * 100)
        }
        let initialTrend = try trend(for: last14)
        let maintenanceTrend = try trend(for: dates)
        var maintenance: EnergyReviewMaintenance?
        if let trend = maintenanceTrend {
            // 21日分の前後7日平均の中央日は14日離れます。摂取も同じ14日へ揃えます。
            let referenceDates = try (0 ..< trend.elapsedDays).map { try shifted(trend.before.representativeDate, by: $0) }
            let kcal = referenceDates.reduce(0) { $0 + intakes[$1]!.kcal! } / Double(referenceDates.count)
            let estimate = kcal - trend.changeKilograms * kilogramsToKcal / Double(trend.elapsedDays)
            if estimate.isFinite, estimate > 0 {
                maintenance = .init(period: .init(referenceDates), trend: trend, averageIntakeKcal: kcal,
                                    estimatedMaintenanceKcal: estimate, kilogramsToKcal: kilogramsToKcal,
                                    intakeKcalByDate: Dictionary(uniqueKeysWithValues: referenceDates.map { ($0, intakes[$0]!.kcal!) }))
            } else { reasons.append("維持量の計算結果が0以下です。摂取量と体重の採用値を確認してください。") }
        } else { reasons.append("実測の維持量には、連続21日分の記録完了・確定摂取量・同じ取得元の朝体重が必要です。欠けた日は補完しません。") }
        if initialTrend == nil { reasons.append("初期目標の増減には、直近14日分の記録完了・確定摂取量・朝体重が必要です。") }

        let nextWeekly = try lastReviewedOn.map { try shifted($0, by: 7) } ?? asOf
        let weeklyDue = asOf >= nextWeekly
        var initialDue = false, nextInitial: String?
        var proposal: EnergyReviewProposal?
        if let goal, try goal.applies(asOf), goal.phase == .gaining, let base = goal.base.kcal {
            let anchor = max(goal.effectiveFrom, lastInitialAdjustmentReviewedOn ?? goal.effectiveFrom)
            nextInitial = try shifted(anchor, by: 14); initialDue = asOf >= nextInitial!
            if !initialDue { reasons.append("初期目標の増減は2週間ごとです。次回は\(nextInitial!)です。") }
            if weeklyDue, let maintenance {
                proposal = .init(kind: .measuredTarget,
                                 reason: "記録完了日の摂取と前後の7日平均体重から維持量を推定し、合意済みの増量幅250〜300kcalを加えた目標を提案します。",
                                 proposedEffectiveFrom: asOf,
                                 targetKcal: .init(maintenance.estimatedMaintenanceKcal + 250, maintenance.estimatedMaintenanceKcal + 300),
                                 adjustmentKcal: nil)
            } else if weeklyDue, initialDue, goal.effectiveFrom <= last14[0], let initialTrend {
                let weekly = initialTrend.weeklyChangeKilograms
                if weekly < 0.1 {
                    proposal = .init(kind: .increase, reason: "7日平均の比較で、体重の増加が週0.1kg未満でした。",
                                     proposedEffectiveFrom: asOf, targetKcal: .init(base + 100, base + 150), adjustmentKcal: .init(100, 150))
                } else if weekly >= 0.5 {
                    proposal = .init(kind: .decrease, reason: "7日平均の比較で、体重の増加が週0.5kg以上でした。",
                                     proposedEffectiveFrom: asOf, targetKcal: base >= 150 ? .init(base - 150, base - 100) : nil,
                                     adjustmentKcal: .init(-150, -100))
                } else {
                    proposal = .init(kind: .keep, reason: "体重の増加は週0.1kg以上・0.5kg未満で、合意済みの増減条件には当たりませんでした。",
                                     proposedEffectiveFrom: asOf, targetKcal: .init(base, base), adjustmentKcal: .init(0, 0))
                }
            }
        } else {
            reasons.append(goal == nil ? "適用中の目標が未設定です。" : "適用中の増量期の目標が必要です。他の期の提案条件は未設定です。")
        }
        if !weeklyDue { reasons.append("週1回の見直しは\(nextWeekly)からです。") }
        return .init(reviewedOn: asOf, context: .init(dates), eligibleDates: eligible, excludedDays: excluded,
                     weeklyReviewDue: weeklyDue, nextWeeklyReviewOn: nextWeekly,
                     initialAdjustmentDue: initialDue, nextInitialAdjustmentOn: nextInitial,
                     initialTrend: initialTrend, maintenance: maintenance, proposal: proposal,
                     reasons: Array(Set(reasons)).sorted())
    }

    private static func parsed(_ date: String) throws -> Date {
        try FoodRules.date(date)
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard let value = HealthDates.calendar.date(from: .init(year: parts[0], month: parts[1], day: parts[2]))
        else { throw EnergyReviewFailure.invalidValue }
        return value
    }
    private static func shifted(_ date: String, by days: Int) throws -> String {
        guard let next = HealthDates.calendar.date(byAdding: .day, value: days, to: try parsed(date))
        else { throw EnergyReviewFailure.invalidValue }
        let result = HealthDates.local(next); try FoodRules.date(result); return result
    }
    private static func distance(_ start: String, _ end: String) throws -> Int {
        guard let days = HealthDates.calendar.dateComponents([.day], from: try parsed(start), to: try parsed(end)).day, days > 0
        else { throw EnergyReviewFailure.invalidValue }
        return days
    }
}
