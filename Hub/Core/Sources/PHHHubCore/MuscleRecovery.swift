import Foundation

public enum MuscleRegion: String, CaseIterable, Codable, Sendable, Identifiable {
    case chest = "胸", shoulders = "肩", arms = "腕", back = "背中", hips = "臀部・股関節"
    case thighs = "太もも", calves = "ふくらはぎ・すね", abdomen = "腹部", neck = "首"
    public var id: String { rawValue }
}
public enum MuscleMappingOrigin: String, Codable, Sendable { case generalCandidate, userDefined }
public struct MuscleExerciseMapping: Codable, Equatable, Sendable, Identifiable {
    public let exercise: String, regions: [MuscleRegion], origin: MuscleMappingOrigin
    public let sourceTitle: String?, sourceURL: String?
    public var id: String { exercise }
    public init(exercise: String, regions: [MuscleRegion], origin: MuscleMappingOrigin = .userDefined,
                sourceTitle: String? = nil, sourceURL: String? = nil) throws {
        guard !exercise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, exercise.count <= 500,
              Set(regions).count == regions.count else { throw HubError.invalidResponse }
        self.exercise = exercise; self.regions = regions; self.origin = origin
        self.sourceTitle = sourceTitle; self.sourceURL = sourceURL
    }
}
public enum MuscleActivityTimeBasis: String, Sendable { case ended, started, dateOnly }
public struct MuscleUseEvidence: Sendable, Identifiable {
    public let sessionID: String, date: String, exercises: [String], setIDs: [String]
    public let referenceTime: Date?, timeBasis: MuscleActivityTimeBasis, timeIssue: String?
    public var id: String { sessionID }
}
public struct MuscleRegionActivity: Sendable, Identifiable {
    public let region: MuscleRegion, latestDate: String, evidence: [MuscleUseEvidence]
    public let referenceTime: Date?, timeBasis: MuscleActivityTimeBasis, elapsedSeconds: Double?
    public let timeIssue: String?
    public var id: String { region.id }
    public let recoveryPercent: Double? = nil
    public let nextPossibleTrainingAt: Date? = nil
}
public struct MuscleRecoveryReport: Sendable {
    public let asOf: Date, activities: [MuscleRegionActivity], mappings: [MuscleExerciseMapping]
    public let unmappedExercises: [String]
    public let pendingReason = "回復率と次回可能時刻は、計算方法と係数が未設定のため保留しています。現在は対応表と報告済みの実施日時を表示します。"
}

public enum MuscleRecovery {
    /// ACE公式の対象部位と記述を、日本語の広い部位へ当てはめた初期候補です。本人が変更できます。
    /// https://www.acefitness.org/resources/everyone/exercise-library/（2026-10-04確認）
    public static func initialCandidate(for exercise: String) throws -> MuscleExerciseMapping {
        let part: [MuscleRegion], path: String?
        switch TrainingExercise.identify(exercise) {
        case .bench: part = [.chest, .arms, .shoulders]; path = "5/chest-press/"
        case .squat: part = [.hips, .thighs]; path = "11/back-squat/"
        case .deadlift: part = [.hips, .thighs]; path = "6/deadlift/"
        case .pullup: part = [.back, .arms]; path = "190/chin-ups/"
        case nil: part = []; path = nil
        }
        return try .init(exercise: exercise, regions: part, origin: .generalCandidate,
                         sourceTitle: path == nil ? nil : "ACE Exercise Library・一般的な部位の候補",
                         sourceURL: path.map { "https://www.acefitness.org/resources/everyone/exercise-library/" + $0 })
    }

    public static func evaluate(snapshot: TrainingSnapshot, asOf: Date,
                                overrides: [MuscleExerciseMapping] = []) throws -> MuscleRecoveryReport {
        guard asOf.timeIntervalSince1970.isFinite, Set(overrides.map(\.exercise)).count == overrides.count
        else { throw HubError.invalidResponse }
        for mapping in overrides {
            _ = try MuscleExerciseMapping(exercise: mapping.exercise, regions: mapping.regions, origin: mapping.origin,
                                           sourceTitle: mapping.sourceTitle, sourceURL: mapping.sourceURL)
        }
        let day = HealthDates.local(asOf)
        let sessions = snapshot.performedSessions.filter { $0.date <= day }
        let ids = Set(sessions.map(\.id)), sets = snapshot.sets.filter { ids.contains($0.sessionID) }
        let exercises = Set(sets.map(\.exercise)).sorted()
        let overrideByName = Dictionary(uniqueKeysWithValues: overrides.map { ($0.exercise, $0) })
        let mappings = try exercises.map { try overrideByName[$0] ?? initialCandidate(for: $0) }
        let byExercise = Dictionary(uniqueKeysWithValues: mappings.map { ($0.exercise, $0) })
        var activities: [MuscleRegionActivity] = []
        for region in MuscleRegion.allCases {
            let matching = sets.filter { byExercise[$0.exercise]?.regions.contains(region) == true }
            let matchingIDs = Set(matching.map(\.sessionID))
            let selectedSessions = sessions.filter { matchingIDs.contains($0.id) }
            guard let latestDate = selectedSessions.map(\.date).max() else { continue }
            let latest = selectedSessions.filter { $0.date == latestDate }
            let evidence: [MuscleUseEvidence] = latest.map { session in
                let regionSets = matching.filter { $0.sessionID == session.id }
                let time = referenceTime(session, asOf: asOf)
                return .init(sessionID: session.id, date: session.date, exercises: Set(regionSets.map(\.exercise)).sorted(),
                             setIDs: regionSets.map(\.id).sorted(), referenceTime: time.date, timeBasis: time.basis, timeIssue: time.issue)
            }.sorted { $0.sessionID < $1.sessionID }
            let reference: Date?, basis: MuscleActivityTimeBasis, issue: String?
            // 最新日内の時刻欠測があれば、既知の別セッションだけを「最終」として時間計算しません。
            if evidence.contains(where: { $0.referenceTime == nil }) {
                reference = nil; basis = .dateOnly
                issue = evidence.compactMap(\.timeIssue).first ?? "最新日の一部セッションで時刻が未報告です。"
            } else {
                let newest = evidence.max { $0.referenceTime! < $1.referenceTime! }!
                reference = newest.referenceTime; basis = newest.timeBasis; issue = newest.timeIssue
            }
            activities.append(.init(region: region, latestDate: latestDate, evidence: evidence, referenceTime: reference,
                                    timeBasis: basis, elapsedSeconds: reference.map { asOf.timeIntervalSince($0) }, timeIssue: issue))
        }
        return .init(asOf: asOf, activities: activities, mappings: mappings,
                     unmappedExercises: mappings.filter { $0.regions.isEmpty }.map(\.exercise))
    }

    private static func referenceTime(_ session: TrainingSession, asOf: Date) -> (date: Date?, basis: MuscleActivityTimeBasis, issue: String?) {
        let raw: String?, basis: MuscleActivityTimeBasis
        if let end = session.endedAt { raw = end; basis = .ended }
        else if let start = session.startedAt { raw = start; basis = .started }
        else { return (nil, .dateOnly, "時刻が未報告です。実施日だけを表示します。") }
        guard let raw, let parsed = instant(raw) else { return (nil, .dateOnly, "報告時刻の形式を確認できません。実施日だけを表示します。") }
        guard parsed <= asOf else { return (nil, .dateOnly, "報告時刻が現在より後です。経過時間の計算を保留しています。") }
        if let start = session.startedAt.flatMap(instant), let end = session.endedAt.flatMap(instant), end < start {
            return (nil, .dateOnly, "終了が開始より前です。経過時間の計算を保留しています。")
        }
        return (parsed, basis, nil)
    }
    private static func instant(_ value: String) -> Date? {
        guard value.range(of: #"(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
}
