import Foundation
import Testing
@testable import PHHHubCore

struct WeeklyAllocationTests {
  private func day(_ date: String, intake: Double?, goal: Double? = 2000,
    complete: Bool = true, pending: Bool = false) throws -> WeeklyAllocationDay {
    let status = complete ? try FoodDay.completed(date: date, operationID: UUID().uuidString, at: .now) : nil
    return try .init(date: date, completion: status, consumedKcal: intake, goalKcal: goal, hasPendingChanges: pending)
  }

  @Test func calendarWeekIsMondayThroughSundayAcrossYearAndLeapDay() throws {
    #expect(try WeeklyAllocation.weekDates(asOf: "2026-10-03") == ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"])
    #expect(try WeeklyAllocation.weekDates(asOf: "2027-01-01").first == "2026-12-28")
    #expect(try WeeklyAllocation.weekDates(asOf: "2028-02-29").contains("2028-02-29"))
  }

  @Test func onlyCompletedKnownPairsCountAndMissingDaysAreNotZero() throws {
    let report = try WeeklyAllocation.evaluate(asOf: "2026-10-01", days: [
      day("2026-09-28", intake: 2300), day("2026-09-29", intake: 1000, complete: false),
      day("2026-09-30", intake: nil), day("2026-10-01", intake: 2000, goal: nil),
      day("2026-10-02", intake: nil, complete: false),
    ])
    #expect(report.includedDayCount == 1)
    #expect(report.includedIntakeKcal == 2300); #expect(report.includedGoalKcal == 2000)
    #expect(report.differenceKcal == 300)
    #expect(report.days[1].differenceKcal == nil)
    #expect(report.days[2].exclusions.contains(.intakeUnknown))
    #expect(report.days[3].exclusions.contains(.goalUnknown))
    #expect(report.days[6].consumedKcal == nil)
    #expect(report.remainingDayCount == 3)
  }

  @Test func changedCompletionAndPendingChangesRemainExcluded() throws {
    var completed = try FoodDay.completed(date: "2026-09-28", operationID: UUID().uuidString, at: .now)
    try completed.foodChanged(to: 1)
    let report = try WeeklyAllocation.evaluate(asOf: "2026-09-29", days: [
      .init(date: completed.date, completion: completed, consumedKcal: 2500, goalKcal: 2000),
      day("2026-09-29", intake: 2500, pending: true),
    ])
    #expect(report.includedDayCount == 0)
    #expect(report.differenceKcal == nil)
    #expect(report.days[0].exclusions.contains(.changedAfterCompletion))
    #expect(report.days[1].exclusions.contains(.pendingChanges))
    #expect(throws: WeeklyAllocationFailure.noEligibleDays) {
      try WeeklyAllocation.preview(report: report, coefficient: 1, dailyCapKcal: 100)
    }
  }

  @Test func explicitKnownZeroCountsOnlyAfterCompletion() throws {
    let empty = try WeeklyAllocation.evaluate(asOf: "2026-09-28", days: [])
    #expect(empty.differenceKcal == nil); #expect(empty.includedIntakeKcal == nil)
    let report = try WeeklyAllocation.evaluate(asOf: "2026-09-28", days: [day("2026-09-28", intake: 0, goal: 0)])
    #expect(report.includedDayCount == 1); #expect(report.differenceKcal == 0)
  }

  @Test func cappedEqualSharesShowUnallocatedDifferenceAndDoNotMutateInput() throws {
    let inputs = try [day("2026-10-01", intake: 2600), day("2026-10-02", intake: nil, complete: false),
      day("2026-10-03", intake: nil, complete: false), day("2026-10-04", intake: nil, complete: false)]
    let report = try WeeklyAllocation.evaluate(asOf: "2026-10-01", days: inputs)
    let preview = try WeeklyAllocation.preview(report: report, coefficient: 1, dailyCapKcal: 100)
    #expect(preview.requestedAdjustmentKcal == -600)
    #expect(preview.allocatedAdjustmentKcal == -300)
    #expect(preview.unallocatedAdjustmentKcal == -300)
    #expect(preview.remainingDifferenceKcal == 300)
    #expect(preview.days.allSatisfy { $0.adjustmentKcal == -100 && $0.previewGoalKcal == 1900 })
    #expect(inputs[1].goalKcal == 2000); #expect(inputs[0].consumedKcal == 2600)
    #expect(report.differenceKcal == 600)
  }

  @Test func manualCoefficientAndZeroArePreservedAndFutureTargetsNeverGoNegative() throws {
    let report = try WeeklyAllocation.evaluate(asOf: "2026-10-03", days: [
      day("2026-10-03", intake: 3000), day("2026-10-04", intake: nil, goal: 100, complete: false)])
    let preview = try WeeklyAllocation.preview(report: report, coefficient: 0.5, dailyCapKcal: 500)
    #expect(preview.requestedAdjustmentKcal == -500)
    #expect(preview.days[0].adjustmentKcal == -100)
    #expect(preview.days[0].previewGoalKcal == 0)
    #expect(preview.unallocatedAdjustmentKcal == -400)
    #expect(try WeeklyAllocation.preview(report: report, coefficient: 0, dailyCapKcal: 0)
      .allocatedAdjustmentKcal == 0)
    #expect(throws: WeeklyAllocationFailure.settingsRequired) {
      try WeeklyAllocation.preview(report: report, coefficient: nil, dailyCapKcal: 100)
    }
    #expect(throws: WeeklyAllocationFailure.settingsRequired) {
      try WeeklyAllocation.preview(report: report, coefficient: 1, dailyCapKcal: nil)
    }
  }

  @Test func underTargetPreviewUsesExplicitFutureGoalAndDoesNotAddPFC() throws {
    let report = try WeeklyAllocation.evaluate(asOf: "2026-10-03", days: [
      day("2026-10-03", intake: 1800), day("2026-10-04", intake: nil, complete: false)])
    let preview = try WeeklyAllocation.preview(report: report, coefficient: 0.5, dailyCapKcal: 200)
    #expect(preview.days[0].adjustmentKcal == 100)
    #expect(preview.days[0].previewGoalKcal == 2100)
    let unknown = try WeeklyAllocation.evaluate(asOf: "2026-10-03", days: [day("2026-10-03", intake: 2300)])
    #expect(throws: WeeklyAllocationFailure.missingFutureGoal) {
      try WeeklyAllocation.preview(report: unknown, coefficient: 1, dailyCapKcal: 100)
    }
  }

  @Test func futurePendingChangesBlockTheTrial() throws {
    let report = try WeeklyAllocation.evaluate(asOf: "2026-10-03", days: [
      day("2026-10-03", intake: 2300), day("2026-10-04", intake: nil, complete: false, pending: true)])
    #expect(report.includedDayCount == 1)
    #expect(throws: WeeklyAllocationFailure.pendingFutureChanges) {
      try WeeklyAllocation.preview(report: report, coefficient: 1, dailyCapKcal: 100)
    }
  }

  @Test func sundaysDuplicatesAndInvalidInputsFailWithoutChoosingDefaults() throws {
    let last = try WeeklyAllocation.evaluate(asOf: "2026-10-04", days: [day("2026-10-04", intake: 2200)])
    #expect(throws: WeeklyAllocationFailure.noRemainingDays) {
      try WeeklyAllocation.preview(report: last, coefficient: 1, dailyCapKcal: 100)
    }
    let duplicate = try day("2026-10-03", intake: 2200)
    #expect(throws: WeeklyAllocationFailure.invalidValue) {
      try WeeklyAllocation.evaluate(asOf: duplicate.date, days: [duplicate, duplicate])
    }
    for coefficient in [-1.0, 1.1, Double.infinity, Double.nan] {
      #expect(throws: WeeklyAllocationFailure.invalidValue) {
        try WeeklyAllocationSettings(coefficient: coefficient, dailyCapKcal: 100)
      }
    }
    #expect(throws: WeeklyAllocationFailure.invalidValue) {
      try WeeklyAllocationSettings(coefficient: 0.5, dailyCapKcal: -1)
    }
  }
}
