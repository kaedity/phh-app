import Foundation

public struct TrainingMajorSeriesOption: Identifiable, Sendable {
    public let id: String, exercise: TrainingExercise, basis: TrainingWeightBasis
}
public enum TrainingDeloadState: String, Equatable, Sendable {
    case suggested, growing, insufficientHistory, missingEvidence, unsupportedBasis, unavailableSeries
}
public struct TrainingDeloadAssessment: Identifiable, Sendable {
    public let id: String, exercise: TrainingExercise, state: TrainingDeloadState, reason: String
    public let referenceDates: [String], observations: [TrainingPoint], missingEvidenceDates: [String]
    public let remainingObservations: Int
    public let calculationVersion = "deload-three-comparisons-epley-v1"
    public var isSuggested: Bool { state == .suggested }
}
public struct TrainingInsightsReport: Sendable {
    public let asOf: String, availableSeries: [TrainingMajorSeriesOption]
    public let assessments: [TrainingDeloadAssessment]
    public let unselectedExercises: [TrainingExercise]
}

/// 選択した主系列の確定実績から提案するだけで、計画・セッション・セットを変更しません。
public enum TrainingInsights {
    /// 完了セッションに記録した全セットを使う。成功・失敗の区別はない（10/4本人決定）。
    public static func evaluate(snapshot: TrainingSnapshot, asOf: String,
                                majorSeries: [TrainingExercise: String]) throws -> TrainingInsightsReport {
        guard Schema.validDate(asOf) else { throw HubError.invalidResponse }
        let historicalSessions = snapshot.sessions.filter { $0.date <= asOf }
        let historicalIDs = Set(historicalSessions.map(\.id))
        let historical = try TrainingSnapshot(sessions: historicalSessions,
                                             sets: snapshot.sets.filter { historicalIDs.contains($0.sessionID) },
                                             notes: [])
        let completedSessions = historicalSessions.filter { $0.lifecycle == .completed }
        let completedIDs = Set(completedSessions.map(\.id))
        let completed = try TrainingSnapshot(sessions: completedSessions,
                                            sets: historical.sets.filter { completedIDs.contains($0.sessionID) }, notes: [])
        var options: [TrainingMajorSeriesOption] = [], assessments: [TrainingDeloadAssessment] = []
        for exercise in TrainingExercise.allCases {
            options += historical.series(for: exercise).map { .init(id: $0.id, exercise: exercise, basis: $0.basis) }
            guard let selectedID = majorSeries[exercise] else { continue }
            guard let original = completed.series(for: exercise).first(where: { $0.id == selectedID }) else {
                assessments.append(.init(id: selectedID, exercise: exercise, state: .unavailableSeries,
                                         reason: "この主系列の完了した記録がありません。", referenceDates: [],
                                         observations: [], missingEvidenceDates: [], remainingObservations: 4))
                continue
            }
            guard original.basis == .standard, exercise != .pullup else {
                assessments.append(.init(id: selectedID, exercise: exercise, state: .unsupportedBasis,
                                         reason: "自重・加重・補助の系列と懸垂には、この推定1RMの停滞条件を適用しません。", referenceDates: [],
                                         observations: [], missingEvidenceDates: [], remainingObservations: 4))
                continue
            }
            // 既存の系列・Epley式・日代表の最大値を再利用。同日複数セット/セッションを別の回に数えません。
            let dates = Array(Set(original.sets.compactMap { original.dates[$0.id] }).sorted().suffix(4))
            let points = original.points(.estimatedOneRM)
            let byDate = Dictionary(uniqueKeysWithValues: points.map { ($0.date, $0) })
            let observations = dates.compactMap { byDate[$0] }
            let missing = dates.filter { byDate[$0] == nil }
            let state: TrainingDeloadState, reason: String
            if !missing.isEmpty {
                state = .missingEvidence
                reason = "推定1RMを出せるセット（通常重量・1〜10回）がない日があります。欠測を飛ばして連続判定しません。"
            } else if dates.count < 4 {
                state = .insufficientHistory
                reason = "3回連続の前回比較には、同じ主系列の完了した実施日が4回分必要です。"
            } else if zip(observations.dropFirst(), observations).allSatisfy({ pair in pair.0.value <= pair.1.value }) {
                state = .suggested
                reason = "同じ主系列の直近4回の実施日で、推定1RMが前回から3回続けて伸びていません。負荷を落とす週を検討できます。"
            } else {
                state = .growing
                reason = "直近の比較に推定1RMが伸びた回があり、3回連続の停滞条件には当たりません。"
            }
            assessments.append(.init(id: selectedID, exercise: exercise, state: state, reason: reason,
                                     referenceDates: dates, observations: observations, missingEvidenceDates: missing,
                                     remainingObservations: max(0, 4 - dates.count)))
        }
        return .init(asOf: asOf, availableSeries: options, assessments: assessments,
                     unselectedExercises: TrainingExercise.allCases.filter { majorSeries[$0] == nil })
    }

    public static func evaluate(rows: [LocalRow], asOf: String,
                                majorSeries: [TrainingExercise: String]) throws -> TrainingInsightsReport {
        let trainingRows = rows.filter { ["TrainingSessions", "TrainingSets", "TrainingNotes"].contains($0.table) }
        let snapshot = try TrainingSnapshot(rows: trainingRows)
        return try evaluate(snapshot: snapshot, asOf: asOf, majorSeries: majorSeries)
    }
}
