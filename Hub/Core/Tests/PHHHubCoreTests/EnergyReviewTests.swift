import Foundation
import Testing
@testable import PHHHubCore

@Suite struct EnergyReviewTests {
    private func date(_ day: Int) -> String { String(format: "2026-09-%02d", day) }
    private func goal(phase: GoalPhase = .gaining, from: String = "2026-09-01") throws -> GoalRule {
        try .init(effectiveFrom: from, phase: phase, base: .init(kcal: 2500, protein: 140, fat: 60, carbohydrate: 350))
    }
    private func intakes(_ count: Int = 21, kcal: Double? = 2500) throws -> [EnergyReviewIntakeDay] {
        try (1...count).map { day in
            try .init(day: .completed(date: date(day), operationID: UUID().uuidString,
                                      at: Date(timeIntervalSince1970: 100)), kcal: kcal)
        }
    }
    private func weights(_ count: Int = 21, step: Double = 0.01, morning: Bool = true,
                         source: String = "fictional-scale") throws -> [EnergyReviewWeightDay] {
        try (1...count).map { day in
            try .init(date: date(day), sampleID: UUID().uuidString, sourceID: source,
                      kilograms: 70 + Double(day - 1) * step, morningMeasurementConfirmed: morning)
        }
    }

    @Test func twentyOneDayMeansAndIntakeShareTheSameFourteenDayInterval() throws {
        var food = try intakes()
        // 平均体重の代表日間と無関係な端の摂取を計算へ混ぜません。
        for index in [0, 1, 2, 17, 18, 19, 20] {
            food[index] = try .init(day: food[index].day, kcal: 9000)
        }
        let original = try goal()
        let report = try EnergyReview.evaluate(asOf: date(22), goal: original, intakeDays: food, weights: weights())
        let estimate = try #require(report.maintenance)
        #expect(report.eligibleDates.count == 21)
        #expect(estimate.trend.before.period.start == date(1))
        #expect(estimate.trend.after.period.end == date(21))
        #expect(estimate.trend.before.representativeDate == date(4))
        #expect(estimate.trend.after.representativeDate == date(18))
        #expect(estimate.period.dates == (4...17).map(date))
        #expect(estimate.trend.elapsedDays == 14)
        #expect(estimate.averageIntakeKcal == 2500)
        #expect(estimate.kilogramsToKcal == 7700)
        #expect(abs(estimate.estimatedMaintenanceKcal - 2423) < 0.000001)
        #expect(report.proposal?.kind == .measuredTarget)
        #expect(abs((report.proposal?.targetKcal?.lower ?? 0) - 2673) < 0.000001)
        #expect(report.proposal?.proposedEffectiveFrom == date(22))
        #expect(original.base.kcal == 2500)
        #expect(original.base.protein == 140)
        #expect(original.base.fat == 60)
        #expect(original.base.carbohydrate == 350)
    }

    @Test func fourteenCompleteDaysAllowInitialIncreaseAndDoNotInventMaintenance() throws {
        let report = try EnergyReview.evaluate(asOf: date(15), goal: goal(), intakeDays: intakes(14), weights: weights(14))
        #expect(report.maintenance == nil)
        #expect(report.initialTrend?.elapsedDays == 7)
        #expect(report.initialAdjustmentDue)
        #expect(report.proposal?.kind == .increase)
        #expect(report.proposal?.adjustmentKcal?.lower == 100)
        #expect(report.proposal?.adjustmentKcal?.upper == 150)
        #expect(report.proposal?.targetKcal?.lower == 2600)
        #expect(report.proposal?.targetKcal?.upper == 2650)
    }

    @Test func halfKilogramThresholdIsInclusiveAndModerateGainKeepsTheBase() throws {
        let food = try intakes(14)
        for (change, expected) in [(0.5, EnergyReviewProposalKind.decrease), (0.25, .keep)] {
            let body = try (1...14).map { day in
                try EnergyReviewWeightDay(date: date(day), sampleID: UUID().uuidString, sourceID: "fictional",
                                          kilograms: day <= 7 ? 70 : 70 + change, morningMeasurementConfirmed: true)
            }
            let report = try EnergyReview.evaluate(asOf: date(15), goal: goal(), intakeDays: food, weights: body)
            #expect(report.proposal?.kind == expected)
            if expected == .decrease {
                #expect(report.proposal?.targetKcal?.lower == 2350)
                #expect(report.proposal?.targetKcal?.upper == 2400)
            } else { #expect(report.proposal?.targetKcal?.lower == 2500) }
        }
    }

    @Test func incompleteChangedUnknownAndPendingDaysPreventBothCalculations() throws {
        let complete = try intakes(14), body = try weights(14)
        var changed = complete[7].day
        try changed.foodChanged(to: 1)
        let variants: [(EnergyReviewIntakeDay, EnergyReviewExclusion)] = [
            (try .init(day: FoodDay(date: date(8)), kcal: 0), .incomplete),
            (try .init(day: changed, kcal: 2500), .changedAfterCompletion),
            (try .init(day: complete[7].day, kcal: nil), .intakeUnknown),
            (try .init(day: complete[7].day, kcal: 2500, hasPendingChanges: true), .pendingChanges)
        ]
        for (variant, reason) in variants {
            var food = complete; food[7] = variant
            let report = try EnergyReview.evaluate(asOf: date(15), goal: goal(), intakeDays: food, weights: body)
            #expect(report.proposal == nil)
            #expect(report.initialTrend == nil)
            #expect(report.maintenance == nil)
            #expect(report.excludedDays.first { $0.date == date(8) }?.reasons.contains(reason) == true)
            #expect(!report.eligibleDates.contains(date(8)))
        }
    }

    @Test func morningIsExplicitAndMixedSourcesAreNotCombined() throws {
        let unconfirmed = try EnergyReview.evaluate(asOf: date(22), goal: goal(), intakeDays: intakes(), weights: weights(morning: false))
        #expect(unconfirmed.proposal == nil)
        #expect(unconfirmed.eligibleDates.isEmpty)
        #expect(unconfirmed.excludedDays.allSatisfy { $0.reasons.contains(.morningUnconfirmed) })
        var mixed = try weights()
        mixed[10] = try .init(date: date(11), sampleID: UUID().uuidString, sourceID: "other-scale", kilograms: 70.1,
                              morningMeasurementConfirmed: true)
        let report = try EnergyReview.evaluate(asOf: date(22), goal: goal(), intakeDays: intakes(), weights: mixed)
        #expect(report.initialTrend == nil)
        #expect(report.maintenance == nil)
        #expect(report.proposal == nil)
        #expect(report.reasons.contains { $0.contains("取得元") })
    }

    @Test func weeklyReviewAndInitialAdjustmentHaveSeparateCadences() throws {
        let notWeekly = try EnergyReview.evaluate(asOf: date(22), goal: goal(), intakeDays: intakes(), weights: weights(), lastReviewedOn: date(16))
        #expect(!notWeekly.weeklyReviewDue)
        #expect(notWeekly.nextWeeklyReviewOn == date(23))
        #expect(notWeekly.maintenance != nil)
        #expect(notWeekly.proposal == nil)
        let due = try EnergyReview.evaluate(asOf: date(22), goal: goal(), intakeDays: intakes(), weights: weights(), lastReviewedOn: date(15))
        #expect(due.weeklyReviewDue)
        #expect(due.proposal?.kind == .measuredTarget)
        let initialNotDue = try EnergyReview.evaluate(asOf: date(15), goal: goal(), intakeDays: intakes(14), weights: weights(14), lastInitialAdjustmentReviewedOn: date(8))
        #expect(initialNotDue.weeklyReviewDue)
        #expect(!initialNotDue.initialAdjustmentDue)
        #expect(initialNotDue.nextInitialAdjustmentOn == date(22))
        #expect(initialNotDue.proposal == nil)
    }

    @Test func todayMissingDaysAndExplicitZeroAreNotConflated() throws {
        let food = try intakes(22, kcal: 0), body = try weights(22, step: 0)
        let report = try EnergyReview.evaluate(asOf: date(22), goal: goal(), intakeDays: food, weights: body)
        #expect(!report.eligibleDates.contains(date(22)))
        #expect(report.eligibleDates.count == 21)
        #expect(report.initialTrend != nil)
        #expect(report.maintenance == nil)
        #expect(report.reasons.contains { $0.contains("0以下") })
        var missing = try intakes(14); missing.remove(at: 5)
        let short = try EnergyReview.evaluate(asOf: date(15), goal: goal(), intakeDays: missing, weights: weights(14))
        #expect(short.proposal == nil)
        #expect(short.excludedDays.first { $0.date == date(6) }?.reasons.contains(.incomplete) == true)
    }

    @Test func unsetAndUnsupportedPhaseNeverCreateTargetSuggestions() throws {
        for rule in [nil, try goal(phase: .maintaining), try goal(phase: .cutting)] {
            let report = try EnergyReview.evaluate(asOf: date(22), goal: rule, intakeDays: intakes(), weights: weights())
            #expect(report.maintenance != nil)
            #expect(report.proposal == nil)
            #expect(!report.reasons.isEmpty)
        }
        let recent = try EnergyReview.evaluate(asOf: date(15), goal: goal(from: date(8)), intakeDays: intakes(14), weights: weights(14))
        #expect(recent.proposal == nil)
        #expect(recent.nextInitialAdjustmentOn == date(22))
    }

    @Test func malformedValuesDuplicateDatesAndFutureReviewDatesReject() throws {
        let food = try intakes(), body = try weights()
        #expect(throws: EnergyReviewFailure.duplicateDate) {
            try EnergyReview.evaluate(asOf: date(22), goal: goal(), intakeDays: food + [food[0]], weights: body)
        }
        #expect(throws: EnergyReviewFailure.duplicateDate) {
            try EnergyReview.evaluate(asOf: date(22), goal: goal(), intakeDays: food, weights: body + [body[0]])
        }
        #expect(throws: EnergyReviewFailure.invalidValue) {
            try EnergyReview.evaluate(asOf: date(22), goal: goal(), intakeDays: food, weights: body, lastReviewedOn: date(23))
        }
        #expect(throws: EnergyReviewFailure.invalidValue) { try EnergyReviewIntakeDay(day: food[0].day, kcal: .nan) }
        #expect(throws: EnergyReviewFailure.invalidValue) {
            try EnergyReviewWeightDay(date: date(1), sampleID: UUID().uuidString, sourceID: "fictional", kilograms: 0, morningMeasurementConfirmed: true)
        }
        #expect(throws: (any Error).self) { try EnergyReview.contextDates(asOf: "2026-02-30") }
    }
}
