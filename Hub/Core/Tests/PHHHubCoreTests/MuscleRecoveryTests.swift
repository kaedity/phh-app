import Foundation
import Testing
@testable import PHHHubCore

@Suite struct MuscleRecoveryTests {
    private let base = TrainingTests()
    private let now = ISO8601DateFormatter().date(from: "2026-10-04T12:00:00+09:00")!
    private func session(_ id: Int, date: String = "2026-10-03", start: String? = nil,
                         end: String? = nil, state: TrainingLifecycle = .completed) throws -> TrainingSession {
        try .init(id: base.id(id), date: date, name: "Push", lifecycle: state, startedAt: start, endedAt: end)
    }
    private func snapshot(_ sessions: [TrainingSession], exercises: [String]? = nil) throws -> TrainingSnapshot {
        try .init(sessions: sessions, sets: sessions.enumerated().map { index, session in
            try base.set(index + 100, session: Int(session.id.suffix(12))!, exercise: exercises?[index] ?? "ベンチプレス")
        }, notes: [])
    }

    @Test func endedTimeHasPriorityAndProducesElapsedTimeWithExplicitEvidence() throws {
        let source = try snapshot([session(1, start: "2026-10-03T17:00:00+09:00", end: "2026-10-03T18:00:00+09:00")])
        let result = try MuscleRecovery.evaluate(snapshot: source, asOf: now)
        let chest = try #require(result.activities.first { $0.region == .chest })
        #expect(chest.timeBasis == .ended)
        #expect(chest.elapsedSeconds == 64_800.0)
        #expect(chest.evidence.first?.setIDs == [base.id(100)])
        #expect(chest.recoveryPercent == nil)
        #expect(chest.nextPossibleTrainingAt == nil)
        #expect(result.pendingReason.contains("未設定"))
    }

    @Test func startedTimeIsNeverPromotedToTheEndAndDateOnlyStaysDateOnly() throws {
        let started = try MuscleRecovery.evaluate(snapshot: snapshot([session(1, start: "2026-10-03T17:00:00+09:00", state: .inProgress)]), asOf: now)
        #expect(started.activities.first?.timeBasis == .started)
        #expect(started.activities.first?.elapsedSeconds == 68_400.0)
        let dateOnly = try MuscleRecovery.evaluate(snapshot: snapshot([session(1)]), asOf: now)
        #expect(dateOnly.activities.first?.timeBasis == .dateOnly)
        #expect(dateOnly.activities.first?.referenceTime == nil)
        #expect(dateOnly.activities.first?.elapsedSeconds == nil)
        #expect(dateOnly.activities.first?.latestDate == "2026-10-03")
    }

    @Test func latestDayWithPartialMissingTimeCannotBorrowOlderOrOtherSessionTime() throws {
        let sessions = try [session(1, date: "2026-10-02", end: "2026-10-02T18:00:00+09:00"),
                            session(2, end: "2026-10-03T18:00:00+09:00"), session(3)]
        let result = try MuscleRecovery.evaluate(snapshot: snapshot(sessions), asOf: now)
        #expect(result.activities.first?.latestDate == "2026-10-03")
        #expect(result.activities.first?.elapsedSeconds == nil)
        #expect(result.activities.first?.evidence.count == 2)
        #expect(result.activities.first?.timeIssue != nil)
    }

    @Test func cancelledPlannedWithoutSetsAndFutureDatesDoNotCountAsActivity() throws {
        let source = try snapshot([session(1, state: .cancelled), session(2, date: "2026-10-05")])
        #expect(try MuscleRecovery.evaluate(snapshot: source, asOf: now).activities.isEmpty)
        let planned = try TrainingSnapshot(sessions: [session(3, state: .planned)], sets: [], notes: [])
        #expect(try MuscleRecovery.evaluate(snapshot: planned, asOf: now).activities.isEmpty)
    }

    @Test func editedAndEmptyMappingsOverrideCandidatesAndUnknownNamesStayUnmapped() throws {
        let source = try snapshot([session(1), session(2)], exercises: ["ベンチプレス", "架空の独自種目"])
        let overrides = try [MuscleExerciseMapping(exercise: "ベンチプレス", regions: []),
                             MuscleExerciseMapping(exercise: "架空の独自種目", regions: [.back])]
        let result = try MuscleRecovery.evaluate(snapshot: source, asOf: now, overrides: overrides)
        #expect(result.activities.map(\.region) == [.back])
        #expect(result.unmappedExercises == ["ベンチプレス"])
        #expect(result.mappings.allSatisfy { $0.origin == .userDefined })
        let initial = try MuscleRecovery.evaluate(snapshot: source, asOf: now)
        #expect(initial.unmappedExercises == ["架空の独自種目"])
        #expect(try MuscleRecovery.initialCandidate(for: "バーベルベンチプレス").regions == [.chest, .arms, .shoulders])
    }

    @Test func sameRegionUsesLatestKnownReferenceAndRetainsAllLatestDayEvidence() throws {
        let sessions = try [session(1, end: "2026-10-03T16:00:00+09:00"), session(2, end: "2026-10-03T18:00:00+09:00")]
        let result = try MuscleRecovery.evaluate(snapshot: snapshot(sessions), asOf: now)
        #expect(result.activities.first?.elapsedSeconds == 64_800.0)
        #expect(result.activities.first?.evidence.count == 2)
    }

    @Test func invalidFutureAndReversedTimesStayUnconfirmedWithoutZeroElapsed() throws {
        let variants = try [session(1, end: "not-a-time"), session(2, end: "2026-10-04T13:00:00+09:00"),
                            session(3, start: "2026-10-03T18:00:00+09:00", end: "2026-10-03T17:00:00+09:00")]
        for session in variants {
            let result = try MuscleRecovery.evaluate(snapshot: snapshot([session]), asOf: now)
            #expect(result.activities.first?.elapsedSeconds == nil)
            #expect(result.activities.first?.timeIssue != nil)
        }
    }

    @Test func malformedMappingAndDuplicateOverridesReject() throws {
        #expect(throws: HubError.invalidResponse) { try MuscleExerciseMapping(exercise: "", regions: [.chest]) }
        #expect(throws: HubError.invalidResponse) { try MuscleExerciseMapping(exercise: "架空", regions: [.chest, .chest]) }
        let mapping = try MuscleExerciseMapping(exercise: "ベンチプレス", regions: [.chest])
        #expect(throws: HubError.invalidResponse) {
            try MuscleRecovery.evaluate(snapshot: snapshot([session(1)]), asOf: now, overrides: [mapping, mapping])
        }
    }
}
