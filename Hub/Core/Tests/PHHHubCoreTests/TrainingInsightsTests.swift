import Foundation
import Testing
@testable import PHHHubCore

@Suite struct TrainingInsightsTests {
    private let base = TrainingTests()
    private func snapshot(_ values: [Double], states: [TrainingLifecycle]? = nil,
                          exercise: String = "ベンチプレス", basis: TrainingWeightBasis = .standard,
                          equipment: String? = "fictional-bar", variant: String? = "タッチアンドゴー") throws -> TrainingSnapshot {
        let sessions = try values.enumerated().map { index, _ in
            try base.session(index + 1, date: String(format: "2026-10-%02d", index + 1),
                             state: states?[index] ?? .completed)
        }
        let sets = try values.enumerated().map { index, weight in
            try TrainingSet(id: base.id(index + 100), sessionID: sessions[index].id, exercise: exercise,
                            number: 1, weight: weight, reps: 5, basis: basis, equipment: equipment, variant: variant)
        }
        return try .init(sessions: sessions, sets: sets, notes: [])
    }
    private func success(_ snapshot: TrainingSnapshot) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: snapshot.sets.map { ($0.id, true) })
    }
    private func report(_ snapshot: TrainingSnapshot, successes: [String: Bool]? = nil,
                        asOf: String = "2026-10-10") throws -> TrainingInsightsReport {
        let series = try #require(snapshot.series(for: .bench).first)
        return try TrainingInsights.evaluate(snapshot: snapshot, asOf: asOf, majorSeries: [.bench: series.id],
                                              successfulBySetID: successes ?? success(snapshot))
    }

    @Test func threeConsecutiveComparisonsNeedFourCompletedDatesAndShowEvidence() throws {
        let source = try snapshot([70, 70, 69, 69]), result = try report(source)
        let assessment = try #require(result.assessments.first)
        #expect(assessment.state == .suggested)
        #expect(assessment.referenceDates == ["2026-10-01", "2026-10-02", "2026-10-03", "2026-10-04"])
        #expect(assessment.observations.count == 4)
        #expect(assessment.observations[0].value == source.sets[0].estimatedOneRM)
        #expect(assessment.observations.map(\.id) == source.sets.map(\.id))
        #expect(source.sessions.allSatisfy { $0.lifecycle == .completed })
        #expect(source.sets.map(\.weight) == [70, 70, 69, 69])
    }

    @Test func threeDaysCannotProveThreeComparisonsAndAnIncreaseBreaksThePlateau() throws {
        let short = try report(snapshot([70, 70, 70]))
        #expect(short.assessments.first?.state == .insufficientHistory)
        #expect(short.assessments.first?.remainingObservations == 1)
        let growth = try report(snapshot([70, 70, 71, 70]))
        #expect(growth.assessments.first?.state == .growing)
        let oldGrowth = try report(snapshot([70, 71, 71, 71, 71]))
        #expect(oldGrowth.assessments.first?.state == .suggested)
        #expect(oldGrowth.assessments.first?.referenceDates.first == "2026-10-02")
    }

    @Test func missingSuccessAndAnIneligibleMiddleDateDoNotGetSkipped() throws {
        let source = try snapshot([70, 70, 70, 70, 70])
        var successes = success(source); successes.removeValue(forKey: source.sets[2].id)
        let missing = try report(source, successes: successes)
        #expect(missing.assessments.first?.state == .missingEvidence)
        #expect(missing.assessments.first?.missingEvidenceDates == ["2026-10-03"])
        #expect(missing.assessments.first?.referenceDates.count == 4)
        var sets = source.sets
        sets[2] = try .init(id: sets[2].id, sessionID: sets[2].sessionID, exercise: sets[2].exercise,
                            number: 1, weight: 70, reps: 11, equipment: sets[2].equipment, variant: sets[2].variant)
        let manyReps = try TrainingSnapshot(sessions: source.sessions, sets: sets, notes: [])
        let ineligible = try report(manyReps)
        #expect(ineligible.assessments.first?.state == .missingEvidence)
        #expect(ineligible.assessments.first?.missingEvidenceDates == ["2026-10-03"])
    }

    @Test func explicitFailureDoesNotInflateDailyOneRMAndUnknownComparableSetBlocks() throws {
        let source = try snapshot([70, 70, 70, 70])
        let failed = try TrainingSet(id: base.id(990), sessionID: source.sessions.last!.id, exercise: "ベンチプレス",
                                     number: 2, weight: 120, reps: 2, equipment: "fictional-bar", variant: "タッチアンドゴー")
        let withFailure = try TrainingSnapshot(sessions: source.sessions, sets: source.sets + [failed], notes: [])
        var successes = success(source); successes[failed.id] = false
        let result = try report(withFailure, successes: successes)
        #expect(result.assessments.first?.state == .suggested)
        #expect(result.assessments.first?.observations.last?.set.weight == 70)
        successes.removeValue(forKey: failed.id)
        let unknown = try report(withFailure, successes: successes)
        #expect(unknown.assessments.first?.state == .missingEvidence)
        #expect(unknown.assessments.first?.missingEvidenceDates == ["2026-10-04"])
    }

    @Test func equipmentAndTechniqueSeriesRemainSeparateAndRequireSelection() throws {
        let main = try snapshot([70, 70, 70, 70])
        var added = main.sets
        for (index, session) in main.sessions.enumerated() {
            added.append(try .init(id: base.id(500 + index), sessionID: session.id, exercise: "ベンチプレス",
                                   number: 2, weight: Double(90 + index), reps: 5,
                                   equipment: "fictional-bar", variant: "ポーズベンチ"))
            added.append(try .init(id: base.id(600 + index), sessionID: session.id, exercise: "ベンチプレス",
                                   number: 3, weight: Double(100 + index), reps: 5,
                                   equipment: "other-machine", variant: "タッチアンドゴー"))
        }
        let mixed = try TrainingSnapshot(sessions: main.sessions, sets: added, notes: [])
        let primaryID = try #require(main.series(for: .bench).first).id
        let result = try TrainingInsights.evaluate(snapshot: mixed, asOf: "2026-10-10",
                                                    majorSeries: [.bench: primaryID], successfulBySetID: success(mixed))
        #expect(result.availableSeries.filter { $0.exercise == .bench }.count == 3)
        #expect(result.assessments.first?.state == .suggested)
        #expect(result.assessments.first?.observations.allSatisfy { $0.set.variant == "タッチアンドゴー" && $0.set.equipment == "fictional-bar" } == true)
        let unselected = try TrainingInsights.evaluate(snapshot: mixed, asOf: "2026-10-10", majorSeries: [:], successfulBySetID: success(mixed))
        #expect(unselected.assessments.isEmpty)
        #expect(unselected.unselectedExercises.contains(.bench))
    }

    @Test func futureCancelledAndInProgressSessionsCannotCreateTheFourthObservation() throws {
        let future = try report(snapshot([70, 70, 70, 70]), asOf: "2026-10-03")
        #expect(future.assessments.first?.state == .insufficientHistory)
        for state in [TrainingLifecycle.cancelled, .inProgress, .planned] {
            let source = try snapshot([70, 70, 70, 70], states: [.completed, .completed, .completed, state])
            let result = try report(source)
            #expect(result.assessments.first?.state == .insufficientHistory)
            #expect(result.assessments.first?.observations.count == 3)
        }
    }

    @Test func sameDaySessionsAndExtraSetsCountAsOneObservation() throws {
        let sessions = try (1...4).map { try base.session($0, date: "2026-10-01", state: .completed) }
        let sets = try sessions.enumerated().map { index, session in
            try TrainingSet(id: base.id(100 + index), sessionID: session.id, exercise: "ベンチプレス",
                            number: 1, weight: 70, reps: 5)
        }
        let source = try TrainingSnapshot(sessions: sessions, sets: sets, notes: [])
        let result = try report(source)
        #expect(result.assessments.first?.state == .insufficientHistory)
        #expect(result.assessments.first?.observations.count == 1)
        #expect(result.assessments.first?.remainingObservations == 3)
    }

    @Test func pullupAndAssistedWeightDoNotUseBigThreeOneRM() throws {
        let pullup = try snapshot([10, 10, 10, 10], exercise: "懸垂", basis: .added)
        let id = try #require(pullup.series(for: .pullup).first).id
        let result = try TrainingInsights.evaluate(snapshot: pullup, asOf: "2026-10-10", majorSeries: [.pullup: id], successfulBySetID: success(pullup))
        #expect(result.assessments.first?.state == .unsupportedBasis)
        let assisted = try report(snapshot([70, 70, 70, 70], basis: .assisted))
        #expect(assisted.assessments.first?.state == .unsupportedBasis)
    }

    @Test func invalidDatesAndUnrelatedSuccessIDsReject() throws {
        let source = try snapshot([70, 70, 70, 70]), id = try #require(source.series(for: .bench).first).id
        #expect(throws: HubError.invalidResponse) {
            try TrainingInsights.evaluate(snapshot: source, asOf: "2026-02-30", majorSeries: [.bench: id], successfulBySetID: success(source))
        }
        #expect(throws: HubError.invalidResponse) {
            try TrainingInsights.evaluate(snapshot: source, asOf: "2026-10-10", majorSeries: [.bench: id], successfulBySetID: [base.id(999): true])
        }
    }
}
