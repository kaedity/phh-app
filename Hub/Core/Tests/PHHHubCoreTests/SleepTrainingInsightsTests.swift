import Foundation
import Testing
@testable import PHHHubCore

@Suite struct SleepTrainingInsightsTests {
    private let base = TrainingTests()
    private func time(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func sample(_ n: Int, start: String, end: String, stage: HealthSleepStage,
                        sourceID: String = "fictional-sleep") throws -> HealthSample {
        try .init(id: base.id(n), metric: .sleepAnalysis, source: .init(id: sourceID, name: sourceID),
                  start: time(start), end: time(end), value: nil, unit: "interval", sleepStage: stage)
    }
    private func sleepSamples() throws -> [HealthSample] {
        try [
            sample(201, start: "2026-10-01T22:00:00+09:00", end: "2026-10-02T06:00:00+09:00", stage: .inBed),
            sample(202, start: "2026-10-01T22:00:00+09:00", end: "2026-10-02T04:00:00+09:00", stage: .asleep),
            sample(203, start: "2026-10-02T02:00:00+09:00", end: "2026-10-02T05:00:00+09:00", stage: .core),
            sample(204, start: "2026-10-02T05:00:00+09:00", end: "2026-10-02T06:00:00+09:00", stage: .awake),
            sample(205, start: "2026-10-01T23:00:00+09:00", end: "2026-10-02T06:00:00+09:00", stage: .asleep, sourceID: "other-source")
        ]
    }
    private func training(startedAt: String? = "2026-10-02T18:00:00+09:00") throws -> TrainingSnapshot {
        let session = try TrainingSession(id: base.id(1), date: "2026-10-02", name: "Push", lifecycle: .completed, startedAt: startedAt)
        return try .init(sessions: [session], sets: [base.set(101, session: 1, weight: 70, reps: 5)], notes: [])
    }
    private func evaluate(_ training: TrainingSnapshot, night: SleepTrainingNight?, successes: [String: Bool]? = nil,
                          from: String? = nil, asOf: String = "2026-10-03") throws -> SleepTrainingInsightsReport {
        let id = try #require(training.series(for: .bench).first).id
        return try SleepTrainingInsights.evaluate(snapshot: training,
                                                   successfulBySetID: successes ?? [base.id(101): true], asOf: asOf, from: from,
                                                   majorSeries: [.bench: id], sleepNights: night.map { [$0] } ?? [],
                                                   sleepSourceID: night?.sourceID)
    }

    @Test func overlappingSleepUsesUnionAndKeepsWakeDateSourceAndEvidence() throws {
        let samples = try sleepSamples()
        let night = try SleepTrainingNight.health(samples: samples, sourceID: "fictional-sleep", windowID: base.id(201), mainSleepConfirmed: false)
        #expect(night.wakeDate == "2026-10-02")
        let actualSleepSeconds = try #require(night.actualSleepSeconds)
        #expect(actualSleepSeconds == 25_200.0)
        #expect(night.sourceID == "fictional-sleep")
        #expect(night.evidenceIDs == [base.id(202), base.id(203)])
        #expect(!night.mainSleepConfirmed)
        let result = try evaluate(training(), night: night)
        #expect(result.comparableCount == 1)
        #expect(result.comparisons.first?.performance?.value == 81.7)
        #expect(result.comparisons.first?.issues == [.mainSleepUnconfirmed])
        #expect(result.remainingComparisons == nil)
        #expect(result.assessmentReason.contains("未設定"))
    }

    @Test func explicitMainSleepNeedsNoInventedNightBoundaryAndStagesAloneProduceNoWindow() throws {
        let samples = try sleepSamples()
        let windows = try SleepTrainingInsights.healthWindows(samples, asOf: "2026-10-03")
        #expect(windows.filter { $0.sourceID == "fictional-sleep" }.count == 1)
        #expect(windows.contains { $0.id == base.id(205) })
        #expect(try SleepTrainingInsights.healthWindows(samples.filter { [.core, .awake].contains($0.sleepStage!) }, asOf: "2026-10-03").isEmpty)
        let confirmed = try SleepTrainingNight.health(samples: samples, sourceID: "fictional-sleep", windowID: base.id(201), mainSleepConfirmed: true)
        let result = try evaluate(training(), night: confirmed)
        #expect(result.comparisons.first?.issues.isEmpty == true)
        #expect(result.comparisons.first?.sleep?.mainSleepConfirmed == true)
    }

    @Test func missingSleepAndUnknownSuccessDoNotBecomeZeroOrSuccessfulSets() throws {
        let missingSleep = try evaluate(training(), night: nil)
        #expect(missingSleep.comparableCount == 0)
        #expect(missingSleep.comparisons.first?.sleep == nil)
        #expect(missingSleep.comparisons.first?.issues == [.sleepMissing])
        let night = try SleepTrainingNight.health(samples: sleepSamples(), sourceID: "fictional-sleep", windowID: base.id(201), mainSleepConfirmed: true)
        let unknown = try evaluate(training(), night: night, successes: [:])
        #expect(unknown.comparableCount == 0)
        #expect(unknown.comparisons.first?.performance == nil)
        #expect(unknown.comparisons.first?.issues.contains(.successUnreported) == true)
        let failed = try evaluate(training(), night: night, successes: [base.id(101): false])
        #expect(failed.comparisons.first?.performance == nil)
        #expect(failed.comparisons.first?.issues.contains(.successUnreported) == false)
    }

    @Test func sleepingAfterTrainingCannotBeCalledPriorSleepAndMissingTimeIsExplicit() throws {
        let night = try SleepTrainingNight.health(samples: sleepSamples(), sourceID: "fictional-sleep", windowID: base.id(201), mainSleepConfirmed: true)
        let after = try evaluate(training(startedAt: "2026-10-02T03:00:00+09:00"), night: night)
        #expect(after.comparableCount == 0)
        #expect(after.comparisons.first?.issues.contains(.sleepAfterTraining) == true)
        let unknownTime = try evaluate(training(startedAt: nil), night: night)
        #expect(unknownTime.comparableCount == 1)
        #expect(unknownTime.comparisons.first?.issues.contains(.trainingTimeUnreported) == true)
    }

    @Test func futureAndPeriodExcludedDaysAreNotCompared() throws {
        let night = try SleepTrainingNight.health(samples: sleepSamples(), sourceID: "fictional-sleep", windowID: base.id(201), mainSleepConfirmed: true)
        #expect(try evaluate(training(), night: night, from: "2026-10-03").comparisons.isEmpty)
        #expect(try evaluate(training(), night: night, asOf: "2026-10-01").comparisons.isEmpty)
    }

    @Test func autoSleepSecondsAndIntervalRemainAnIndependentSource() throws {
        let record = try #require(AutoSleepNormalizer.normalize(id: base.id(400), dictionary: .timeAsleep,
            targetDate: "2026-10-02", timeZoneID: "Asia/Tokyo", receivedAt: time("2026-10-02T08:00:00+09:00"), entries: [
                .init(key: "Start", value: .text("2026-10-01T22:00:00+09:00"), unit: "ISO8601"),
                .init(key: "Until", value: .text("2026-10-02T06:00:00+09:00"), unit: "ISO8601"),
                .init(key: "Sleep", value: .number(7.5), unit: "h")
            ]).record)
        let night = try SleepTrainingNight.autoSleep(record, mainSleepConfirmed: false)
        #expect(night.actualSleepSeconds == 7.5 * 3600)
        #expect(night.sourceID == "autosleep.shortcuts.timeAsleep")
        let result = try evaluate(training(), night: night)
        #expect(result.comparableCount == 1)
        #expect(result.comparisons.first?.sleep?.evidenceIDs == [record.id])
    }

    @Test func selectedTrainingSeriesDoesNotInheritTechniqueOrEquipmentPerformance() throws {
        let original = try training(), id = try #require(original.series(for: .bench).first).id
        let other = try TrainingSet(id: base.id(105), sessionID: base.id(1), exercise: "ベンチプレス", number: 2,
                                     weight: 120, reps: 5, equipment: "different-machine", variant: "ポーズベンチ")
        let snapshot = try TrainingSnapshot(sessions: original.sessions, sets: original.sets + [other], notes: [])
        let result = try SleepTrainingInsights.evaluate(snapshot: snapshot, successfulBySetID: [base.id(101): true, other.id: true],
                                                        asOf: "2026-10-03", majorSeries: [.bench: id], sleepNights: [], sleepSourceID: nil)
        #expect(result.availableTrainingSeries.count == 2)
        #expect(result.comparisons.count == 1)
        #expect(result.comparisons.first?.performance?.set.id == base.id(101))
    }

    @Test func pullupDoesNotUseBigThreeEpleyEvenWhenWeightBasisIsStandard() throws {
        let original = try training()
        let set = try TrainingSet(id: base.id(105), sessionID: base.id(1), exercise: "懸垂", number: 1, weight: 20, reps: 5)
        let snapshot = try TrainingSnapshot(sessions: original.sessions, sets: [set], notes: [])
        let id = try #require(snapshot.series(for: .pullup).first).id
        let result = try SleepTrainingInsights.evaluate(snapshot: snapshot, successfulBySetID: [set.id: true], asOf: "2026-10-03",
                                                        majorSeries: [.pullup: id], sleepNights: [], sleepSourceID: nil)
        #expect(result.comparisons.first?.performance == nil)
        #expect(result.comparisons.first?.issues.contains(.performanceMissing) == true)
    }

    @Test func oneMissingStartAmongSameDaySessionsKeepsTheTimingUncertaintyVisible() throws {
        let original = try training()
        let extra = try TrainingSession(id: base.id(2), date: "2026-10-02", name: "Push2", lifecycle: .completed)
        let set = try base.set(102, session: 2, weight: 70, reps: 5)
        let snapshot = try TrainingSnapshot(sessions: original.sessions + [extra], sets: original.sets + [set], notes: [])
        let night = try SleepTrainingNight.health(samples: sleepSamples(), sourceID: "fictional-sleep", windowID: base.id(201), mainSleepConfirmed: true)
        let result = try evaluate(snapshot, night: night, successes: [base.id(101): true, set.id: true])
        #expect(result.comparisons.count == 1)
        #expect(result.comparisons.first?.issues.contains(.trainingTimeUnreported) == true)
    }

    @Test func duplicateWakeDatesAndInvalidInputsReject() throws {
        let samples = try sleepSamples(), source = try training(), id = try #require(source.series(for: .bench).first).id
        let night = try SleepTrainingNight.health(samples: samples, sourceID: "fictional-sleep", windowID: base.id(201), mainSleepConfirmed: true)
        #expect(throws: SleepTrainingFailure.duplicateNight) {
            try SleepTrainingInsights.evaluate(snapshot: source, successfulBySetID: [base.id(101): true], asOf: "2026-10-03",
                                                majorSeries: [.bench: id], sleepNights: [night, night], sleepSourceID: night.sourceID)
        }
        #expect(throws: SleepTrainingFailure.invalidValue) {
            try SleepTrainingNight.health(samples: samples, sourceID: "other-source", windowID: base.id(201), mainSleepConfirmed: false)
        }
        #expect(throws: SleepTrainingFailure.invalidValue) {
            try SleepTrainingInsights.evaluate(snapshot: source, successfulBySetID: [base.id(101): true], asOf: "2026-10-03", from: "2026-02-30",
                                                majorSeries: [.bench: id], sleepNights: [], sleepSourceID: nil)
        }
    }
}
