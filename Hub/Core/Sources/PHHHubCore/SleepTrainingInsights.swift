import Foundation

public enum SleepTrainingFailure: Error, LocalizedError {
    case invalidValue, duplicateNight
    public var errorDescription: String? {
        switch self {
        case .invalidValue: "睡眠の取得元・区間・トレーニングの根拠を確認してください。"
        case .duplicateNight: "同じ起床日の睡眠が複数選択されています。前夜の区間を1つ選んでください。"
        }
    }
}
public struct SleepTrainingNight: Sendable {
    public let id: String, wakeDate: String, sourceID: String, sourceName: String
    public let start: Date, end: Date, actualSleepSeconds: Double?
    public let mainSleepConfirmed: Bool, evidenceIDs: [String]

    public static func health(samples: [HealthSample], sourceID: String, windowID: String,
                              mainSleepConfirmed: Bool) throws -> Self {
        for sample in samples { try sample.validate() }
        guard let window = samples.first(where: { $0.id == windowID }), window.metric == .sleepAnalysis,
              window.source.id == sourceID, window.sleepStage == .inBed || window.sleepStage == .asleep,
              window.end > window.start
        else { throw SleepTrainingFailure.invalidValue }
        let session = try HealthPresentation.sleep(samples, sourceID: sourceID, start: window.start, end: window.end,
                                                   classification: mainSleepConfirmed ? .main : .unclassified)
        let evidence = samples.filter {
            $0.source.id == sourceID && $0.metric == .sleepAnalysis && $0.sleepStage?.isAsleep == true &&
            $0.start < window.end && $0.end > window.start
        }.map(\.id).sorted()
        return .init(id: window.id, wakeDate: HealthDates.local(window.end), sourceID: sourceID,
                     sourceName: window.source.name, start: window.start, end: window.end,
                     actualSleepSeconds: session.seconds, mainSleepConfirmed: mainSleepConfirmed,
                     evidenceIDs: evidence)
    }
    public static func autoSleep(_ record: AutoSleepRecord, mainSleepConfirmed: Bool) throws -> Self {
        try record.validate()
        guard record.dictionary == .timeAsleep, let interval = record.interval,
              HealthDates.local(interval.end) == record.targetDate, interval.end > interval.start
        else { throw SleepTrainingFailure.invalidValue }
        return .init(id: record.id, wakeDate: record.targetDate, sourceID: "autosleep.shortcuts.timeAsleep",
                     sourceName: "AutoSleep・ショートカット", start: interval.start, end: interval.end,
                     actualSleepSeconds: record.actualSleepSeconds, mainSleepConfirmed: mainSleepConfirmed,
                     evidenceIDs: [record.id])
    }
}

public struct SleepTrainingHealthWindow: Identifiable, Sendable {
    public let id: String, wakeDate: String, sourceID: String, sourceName: String
    public let start: Date, end: Date
}
public enum SleepTrainingIssue: String, Equatable, Sendable {
    case sleepMissing, sleepDurationMissing, mainSleepUnconfirmed, successUnreported, performanceMissing
    case sleepAfterTraining, trainingTimeUnreported
    public var title: String {
        switch self {
        case .sleepMissing: "前夜の区間が未選択"
        case .sleepDurationMissing: "実睡眠時間が不明"
        case .mainSleepUnconfirmed: "主睡眠・昼寝の分類は未確認"
        case .successUnreported: "セットの成功が未報告"
        case .performanceMissing: "対象の推定1RMがない"
        case .sleepAfterTraining: "睡眠がトレーニング開始後に終了"
        case .trainingTimeUnreported: "開始時刻が未報告・前後関係は未確認"
        }
    }
}
public struct SleepTrainingComparison: Identifiable, Sendable {
    public let date: String, exercise: TrainingExercise, seriesID: String
    public let sleep: SleepTrainingNight?, performance: TrainingPoint?, issues: [SleepTrainingIssue]
    public var id: String { seriesID + "@" + date }
    public var hasComparableValues: Bool {
        sleep?.actualSleepSeconds != nil && performance != nil &&
        !issues.contains(.sleepAfterTraining)
    }
}
public struct SleepTrainingInsightsReport: Sendable {
    public let asOf: String, from: String?, selectedSleepSourceID: String?
    public let availableTrainingSeries: [TrainingMajorSeriesOption], comparisons: [SleepTrainingComparison]
    public let comparableCount: Int, observedTrainingDays: Int
    /// 月数・回数・統計手法は未決定。残り回数や相関・因果を計算しません。
    public let remainingComparisons: Int? = nil
    public let assessmentReason = "判定に必要な月数・回数・手法が未設定です。現在は睡眠と成績の対比だけを表示します。"
}

public enum SleepTrainingInsights {
    /// 元データのinBed/asleep区間だけを候補にします。睡眠段階の間の隙間や長さから主睡眠を作りません。
    public static func healthWindows(_ samples: [HealthSample], asOf: String) throws -> [SleepTrainingHealthWindow] {
        guard Schema.validDate(asOf) else { throw SleepTrainingFailure.invalidValue }
        for sample in samples { try sample.validate() }
        let sleep = samples.filter { $0.metric == .sleepAnalysis && HealthDates.local($0.end) <= asOf }
        let beds = sleep.filter { $0.sleepStage == .inBed }
        let windows = beds + sleep.filter { sample in
            sample.sleepStage == .asleep && !beds.contains {
                $0.source.id == sample.source.id && $0.start <= sample.start && $0.end >= sample.end
            }
        }
        return windows.map {
            .init(id: $0.id, wakeDate: HealthDates.local($0.end), sourceID: $0.source.id,
                  sourceName: $0.source.name, start: $0.start, end: $0.end)
        }.sorted { ($0.wakeDate, $0.start, $0.id) > ($1.wakeDate, $1.start, $1.id) }
    }

    public static func evaluate(snapshot: TrainingSnapshot, successfulBySetID: [String: Bool],
                                asOf: String, from: String? = nil, majorSeries: [TrainingExercise: String],
                                sleepNights: [SleepTrainingNight], sleepSourceID: String?) throws -> SleepTrainingInsightsReport {
        guard Schema.validDate(asOf), from.map({ Schema.validDate($0) && $0 <= asOf }) ?? true,
              Set(successfulBySetID.keys).isSubset(of: Set(snapshot.sets.map(\.id)))
        else { throw SleepTrainingFailure.invalidValue }
        let selectedNights = sleepNights.filter { $0.sourceID == sleepSourceID }
        guard Set(selectedNights.map(\.wakeDate)).count == selectedNights.count else { throw SleepTrainingFailure.duplicateNight }
        let nights = Dictionary(uniqueKeysWithValues: selectedNights.map { ($0.wakeDate, $0) })
        let available = try TrainingInsights.evaluate(snapshot: snapshot, asOf: asOf,
                                                       majorSeries: majorSeries, successfulBySetID: successfulBySetID).availableSeries
        let completedSessions = snapshot.sessions.filter { session in
            session.lifecycle == .completed && session.date <= asOf && (from.map { session.date >= $0 } ?? true)
        }
        let completedIDs = Set(completedSessions.map(\.id))
        let completed = try TrainingSnapshot(sessions: completedSessions,
                                             sets: snapshot.sets.filter { completedIDs.contains($0.sessionID) }, notes: [])
        let successful = try TrainingSnapshot(sessions: completedSessions,
                                              sets: completed.sets.filter { successfulBySetID[$0.id] == true }, notes: [])
        var comparisons: [SleepTrainingComparison] = []
        for exercise in TrainingExercise.allCases {
            guard let id = majorSeries[exercise], let original = completed.series(for: exercise).first(where: { $0.id == id }) else { continue }
            let points = original.basis == .standard && exercise != .pullup
                ? successful.series(for: exercise).first { $0.id == id }?.points(.estimatedOneRM) ?? [] : []
            let byDate = Dictionary(uniqueKeysWithValues: points.map { ($0.date, $0) })
            for day in Set(original.dates.values).sorted() {
                var issues: [SleepTrainingIssue] = []
                let unreported = original.sets.contains {
                    original.dates[$0.id] == day && $0.estimatedOneRM != nil && successfulBySetID[$0.id] == nil
                }
                let point = unreported ? nil : byDate[day]
                if unreported { issues.append(.successUnreported) }
                if point == nil { issues.append(.performanceMissing) }
                let night = nights[day]
                if let night {
                    if !night.mainSleepConfirmed { issues.append(.mainSleepUnconfirmed) }
                    if night.actualSleepSeconds == nil { issues.append(.sleepDurationMissing) }
                    let sessionIDs = Set(original.sets.filter { original.dates[$0.id] == day }.map(\.sessionID))
                    let relevantSessions = completedSessions.filter { sessionIDs.contains($0.id) }
                    let starts = relevantSessions.compactMap { $0.startedAt.flatMap(instant) }
                    if starts.count != relevantSessions.count { issues.append(.trainingTimeUnreported) }
                    if let earliest = starts.min() {
                        if night.end > earliest { issues.append(.sleepAfterTraining) }
                    }
                } else { issues.append(.sleepMissing) }
                comparisons.append(.init(date: day, exercise: exercise, seriesID: id, sleep: night, performance: point, issues: issues))
            }
        }
        comparisons.sort { ($0.date, $0.exercise.rawValue, $0.seriesID) > ($1.date, $1.exercise.rawValue, $1.seriesID) }
        return .init(asOf: asOf, from: from, selectedSleepSourceID: sleepSourceID, availableTrainingSeries: available,
                     comparisons: comparisons, comparableCount: comparisons.filter(\.hasComparableValues).count,
                     observedTrainingDays: Set(comparisons.map(\.date)).count)
    }

    public static func evaluate(rows: [LocalRow], asOf: String, from: String? = nil,
                                majorSeries: [TrainingExercise: String], sleepNights: [SleepTrainingNight],
                                sleepSourceID: String?) throws -> SleepTrainingInsightsReport {
        let trainingRows = rows.filter { ["TrainingSessions", "TrainingSets", "TrainingNotes"].contains($0.table) }
        let snapshot = try TrainingSnapshot(rows: trainingRows)
        let successes = trainingRows.filter { $0.active && $0.table == "TrainingSets" }.reduce(into: [String: Bool]()) { result, row in
            if case .bool(let value)? = row.values["successful"] { result[row.entityID] = value }
        }
        return try evaluate(snapshot: snapshot, successfulBySetID: successes, asOf: asOf, from: from,
                            majorSeries: majorSeries, sleepNights: sleepNights, sleepSourceID: sleepSourceID)
    }
    private static func instant(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
