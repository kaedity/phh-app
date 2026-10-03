import Foundation
import Testing
@testable import PHHHubCore

@Suite @MainActor struct HealthImportPipelineTests {
    let h = HealthTests()
    func store(_ scope: HealthQueryScope) throws -> HubStore { let s = try HubStore(owner: "synthetic@example.test"); try s.registerHealthScope(scope); return s }
    func page(_ scope: HealthQueryScope, anchor: Data? = nil, next: UInt8 = 1, added: [HealthSample] = [], deleted: [String] = [], more: Bool = false) -> HealthImportPage {
        HealthImportPage(scopeID: scope.id, expectedAnchor: anchor, nextAnchor: Data([next]), added: added, deletedIDs: deleted, hasMore: more, receivedAt: h.time)
    }
    @Test func initialSettingIsDisabledAndFiveHundredThenEmptyCommitsBeforeCompletion() async throws {
        let scope = try h.scope(), store = try store(scope), client = ImportFake()
        #expect(try !store.healthReadEnabled)
        let samples = try (0..<500).map { try h.sample(Double($0), at: h.time.addingTimeInterval(Double($0))) }
        client.pages = [page(scope, added: samples, more: true), page(scope, anchor: Data([1]), next: 2)]
        let pipeline = HealthImportPipeline(store: store, client: client, synthetic: true)
        var completions = 0, committedAtCompletion = false
        let result = await pipeline.catchUp(metric: .bodyMass, completion: {
            completions += 1; committedAtCompletion = (try? store.healthProgress(scope.id)?.anchor) == Data([2])
        })
        #expect(result.pages == 2); #expect(!result.needsMore); #expect(result.issues.isEmpty)
        #expect(completions == 1 && committedAtCompletion); #expect(client.limits == [500,500])
        #expect(try store.healthRecords(metric: .bodyMass, limit: 1).totalCount == 500); #expect(try store.pending().count == 1)
    }
    @Test func failedSaveKeepsAnchorAndSamePageIDRestarts() async throws {
        let scope = try h.scope(), store = try store(scope), client = ImportFake(), p = page(scope, added: [try h.sample()])
        client.pages = [p]; store.healthCommitCheck = { throw CocoaError(.fileWriteUnknown) }
        let pipeline = HealthImportPipeline(store: store, client: client, synthetic: true); var completed = 0
        let failed = await pipeline.catchUp(metric: .bodyMass, completion: { completed += 1 })
        #expect(failed.issues == [.storageFailed]); #expect(try store.healthProgress(scope.id)?.anchor == nil)
        #expect(try store.healthProgress(scope.id)?.readState == .temporaryFailure); #expect(try store.pending().isEmpty)
        store.healthCommitCheck = nil
        let retried = await pipeline.catchUp(metric: .bodyMass, completion: { completed += 1 })
        #expect(retried.pages == 1); #expect(completed == 2); #expect(try store.pending().first?.id == p.id)
    }
    @Test func queryFailureAndUnavailableRetainOldValueAndAnchor() async throws {
        let scope = try h.scope(), store = try store(scope), sample = try h.sample(), client = ImportFake()
        try store.ingestHealth(page(scope, added: [sample]), synthetic: true); client.failure = .temporaryFailure
        let pipeline = HealthImportPipeline(store: store, client: client, synthetic: true)
        #expect(await pipeline.catchUp(metric: .bodyMass).issues == [.queryFailed])
        #expect(try store.healthRecord(sample.id)?.sample == sample); #expect(try store.healthProgress(scope.id)?.anchor == Data([1]))
        client.failure = .unavailable; _ = await pipeline.catchUp(metric: .bodyMass)
        #expect(try store.healthProgress(scope.id)?.readState == .unavailable); #expect(try store.healthRecord(sample.id)?.removed == false)
    }
    @Test func boundedPagesAndSeparateHistoryResumeWithoutChangingConditions() async throws {
        let recent = try h.scope(), history = try h.scope(.history), store = try store(recent), client = ImportFake()
        try store.registerHealthScope(history)
        client.pages = [page(recent, added: [try h.sample()], more: true), page(recent, anchor: Data([1]), next: 2, added: [try h.sample(61)]), page(history)]
        let pipeline = HealthImportPipeline(store: store, client: client, synthetic: true)
        let first = await pipeline.catchUp(metric: .bodyMass, maxPages: 1)
        #expect(first.pages == 1 && first.needsMore); #expect(try store.healthProgress(history.id)?.anchor == nil)
        let next = await pipeline.catchUp(metric: .bodyMass, maxPages: 3)
        #expect(next.pages == 2 && !next.needsMore); #expect(client.requestedScopes == [recent.id,recent.id,history.id])
        #expect(try store.healthProgress(recent.id)?.scope == recent); #expect(try store.healthProgress(history.id)?.scope == history)
        #expect(try store.healthRecords(metric: .bodyMass).totalCount == 2)
    }
    @Test func statisticFailurePreservesRawAnchorDirtyAndOldStatisticThenSameTokenSends() async throws {
        let scope = try h.scope(metric: .stepCount), store = try store(scope), client = ImportFake(), date = HealthDates.local(h.time)
        try store.ingestHealth(page(scope, added: [try h.sample(100, metric: .stepCount)]), synthetic: true)
        let seededDirty = try #require(store.healthDirtyDays(metric: .stepCount).first)
        try store.commitHealthStatistics(HealthDailyStatistics(metric: .stepCount, date: date, value: 100, measuredAt: h.time), dirty: seededDirty, synthetic: true)
        let changed = page(scope, anchor: Data([1]), next: 2, added: [try h.sample(80, metric: .stepCount)])
        client.pages = [changed]; client.statisticsFailure = true
        let pipeline = HealthImportPipeline(store: store, client: client, synthetic: true)
        let failed = await pipeline.catchUp(metric: .stepCount)
        #expect(failed.pages == 1 && failed.issues == [.statisticsFailed]); #expect(try store.healthProgress(scope.id)?.anchor == Data([2]))
        #expect(try store.healthStatistics(metric: .stepCount, date: date)?.value == 100)
        let dirty = try #require(store.healthDirtyDays(metric: .stepCount).first)
        client.pages.append(page(scope, anchor: Data([2]), next: 3)); client.statisticsFailure = false
        client.statistic = try HealthDailyStatistics(metric: .stepCount, date: date, value: 120, measuredAt: h.time.addingTimeInterval(60))
        let success = await pipeline.catchUp(metric: .stepCount)
        #expect(success.statistics == 1 && success.issues.isEmpty); #expect(try store.healthDirtyDays(metric: .stepCount).isEmpty)
        #expect(try store.pending().contains { $0.id == dirty.id && $0.operation.health?.statistics.first?.value == 120 })
        #expect(try store.healthRecords(metric: .stepCount).totalCount == 2)
    }
    @Test func statisticSaveFailureAndStaleTokenNeverClearDirtyOrChangeAnchor() throws {
        let scope = try h.scope(metric: .activeEnergyBurned), store = try store(scope), date = HealthDates.local(h.time)
        try store.ingestHealth(page(scope, added: [try h.sample(100, metric: .activeEnergyBurned)]), synthetic: true)
        let dirty = try #require(store.healthDirtyDays(metric: .activeEnergyBurned).first)
        let stat = try HealthDailyStatistics(metric: .activeEnergyBurned, date: date, value: 100, measuredAt: h.time)
        store.healthCommitCheck = { throw CocoaError(.fileWriteUnknown) }
        #expect(throws: CocoaError.self) { try store.commitHealthStatistics(stat, dirty: dirty, synthetic: true) }
        #expect(try store.healthStatistics(metric: .activeEnergyBurned, date: date) == nil); #expect(try store.healthDirtyDays(metric: .activeEnergyBurned) == [dirty])
        #expect(try store.pending().count == 1); #expect(try store.healthProgress(scope.id)?.anchor == Data([1]))
        store.healthCommitCheck = nil
        try store.ingestHealth(page(scope, anchor: Data([1]), next: 2, added: [try h.sample(10, metric: .activeEnergyBurned)]), synthetic: true)
        #expect(try !store.commitHealthStatistics(stat, dirty: dirty, synthetic: true)); #expect(try store.healthDirtyDays(metric: .activeEnergyBurned).first?.id != dirty.id)
        let fresh = try #require(store.healthDirtyDays(metric: .activeEnergyBurned).first)
        #expect(try store.commitHealthStatistics(stat, dirty: fresh, synthetic: true)); #expect(try !store.commitHealthStatistics(stat, dirty: fresh, synthetic: true))
        #expect(try store.pending().filter { $0.id == fresh.id }.count == 1)
    }
    @Test func emptyStatisticCannotEraseKnownValueButZeroIsARealResult() throws {
        let scope = try h.scope(metric: .basalEnergyBurned), store = try store(scope), date = HealthDates.local(h.time)
        try store.ingestHealth(page(scope, added: [try h.sample(100, metric: .basalEnergyBurned)]), synthetic: true)
        let first = try #require(store.healthDirtyDays(metric: .basalEnergyBurned).first)
        try store.commitHealthStatistics(HealthDailyStatistics(metric: .basalEnergyBurned, date: date, value: 100, measuredAt: h.time), dirty: first, synthetic: true)
        try store.ingestHealth(page(scope, anchor: Data([1]), next: 2, deleted: [try #require(store.healthRecords(metric: .basalEnergyBurned).records.first?.sample?.id)]), synthetic: true)
        let dirty = try #require(store.healthDirtyDays(metric: .basalEnergyBurned).first)
        #expect(try !store.commitHealthStatistics(HealthDailyStatistics(metric: .basalEnergyBurned, date: date, value: nil, measuredAt: h.time.addingTimeInterval(1)), dirty: dirty, synthetic: true))
        #expect(try store.healthStatistics(metric: .basalEnergyBurned, date: date)?.value == 100)
        try store.commitHealthStatistics(HealthDailyStatistics(metric: .basalEnergyBurned, date: date, value: 0, measuredAt: h.time.addingTimeInterval(1)), dirty: dirty, synthetic: true)
        #expect(try store.healthStatistics(metric: .basalEnergyBurned, date: date)?.value == 0); #expect(try store.healthDirtyDays(metric: .basalEnergyBurned).isEmpty)
    }
    @Test func simultaneousNotificationsShareOneMetricFlightAndEachCompletesOnce() async throws {
        let scope = try h.scope(), store = try store(scope), client = ImportFake()
        client.pages = [page(scope, added: [try h.sample()]), page(scope, anchor: Data([1]), next: 2)]
        client.pauseFirst = true
        let pipeline = HealthImportPipeline(store: store, client: client, synthetic: true); var completed = 0
        let first = Task { await pipeline.catchUp(metric: .bodyMass, completion: { completed += 1 }) }
        await client.waitForFirst()
        let second = Task { await pipeline.catchUp(metric: .bodyMass, completion: { completed += 1 }) }
        await Task.yield(); client.resumeFirst()
        let a = await first.value, b = await second.value
        #expect(a == b && a.pages == 2); #expect(completed == 2); #expect(client.maximumActive == 1)
        #expect(try store.pending().count == 1)
    }
    @Test func cancellationAfterReadBeforeSaveKeepsAnchorAndMarksFailureBeforeCompletion() async throws {
        let scope = try h.scope(), store = try store(scope), client = ImportFake()
        client.pages = [page(scope, added: [try h.sample()])]; client.pauseFirst = true
        let pipeline = HealthImportPipeline(store: store, client: client, synthetic: true); var completed = false
        let task = Task { await pipeline.catchUp(metric: .bodyMass, completion: { completed = (try? store.healthProgress(scope.id)?.readState) == .temporaryFailure }) }
        await client.waitForFirst(); pipeline.cancel(metric: .bodyMass); client.resumeFirst()
        #expect(await task.value.issues == [.cancelled]); #expect(completed); #expect(try store.healthProgress(scope.id)?.anchor == nil); #expect(try store.pending().isEmpty)
    }
    @Test func notificationDuringStatisticsPersistsCatchUpPendingAcrossNextRun() async throws {
        let scope = try h.scope(metric: .stepCount), store = try store(scope), client = ImportFake(), date = HealthDates.local(h.time)
        client.pages = [page(scope, added: [try h.sample(100, metric: .stepCount)]), page(scope, anchor: Data([1]), next: 2)]
        client.statistic = try HealthDailyStatistics(metric: .stepCount, date: date, value: 100, measuredAt: h.time); client.pauseStatistic = true
        let pipeline = HealthImportPipeline(store: store, client: client, synthetic: true)
        let first = Task { await pipeline.catchUp(metric: .stepCount) }
        await client.waitForStatistic()
        let second = Task { await pipeline.catchUp(metric: .stepCount) }
        await Task.yield(); client.resumeStatistic()
        #expect(await first.value.needsMore); #expect(await second.value.needsMore)
        #expect(try store.healthProgress(scope.id)?.complete == false); #expect(try store.healthProgress(scope.id)?.anchor == Data([1]))
        let resumed = await pipeline.catchUp(metric: .stepCount)
        #expect(resumed.pages == 1 && !resumed.needsMore); #expect(try store.healthProgress(scope.id)?.complete == true)
    }
    @Test func sleepDateIndexUsesEndDayAndPreservesOriginalUTCInterval() throws {
        let scope = try h.scope(metric: .sleepAnalysis), store = try store(scope)
        let start = HealthDates.calendar.startOfDay(for: h.time).addingTimeInterval(-3600), end = start.addingTimeInterval(8 * 3600)
        let sleep = try HealthSample(id: UUID().uuidString, metric: .sleepAnalysis, source: h.source, start: start, end: end, value: nil, unit: "interval", sleepStage: .asleep)
        try store.ingestHealth(page(scope, added: [sleep]), synthetic: true)
        #expect(try store.healthRecords(metric: .sleepAnalysis, date: HealthDates.local(start)).totalCount == 0)
        #expect(try store.healthRecords(metric: .sleepAnalysis, date: HealthDates.local(end)).records.first?.sample == sleep)
    }
}

@MainActor private final class ImportFake: HealthImportClient {
    var pages: [HealthImportPage] = [], limits: [Int] = [], requestedScopes: [String] = []
    var failure: HealthClientFailure?, statisticsFailure = false, statistic: HealthDailyStatistics?
    var pauseFirst = false, active = 0, maximumActive = 0
    private var firstGate: CheckedContinuation<Void, Never>?, firstWaiter: CheckedContinuation<Void, Never>?
    private var started = false
    var pauseStatistic = false
    private var statisticStarted = false
    private var statisticGate: CheckedContinuation<Void, Never>?, statisticWaiter: CheckedContinuation<Void, Never>?
    func waitForFirst() async { if !started { await withCheckedContinuation { firstWaiter = $0 } } }
    func resumeFirst() { firstGate?.resume(); firstGate = nil }
    func waitForStatistic() async { if !statisticStarted { await withCheckedContinuation { statisticWaiter = $0 } } }
    func resumeStatistic() { statisticGate?.resume(); statisticGate = nil }
    func page(scope: HealthQueryScope, anchor: Data?, limit: Int) async throws -> HealthImportPage {
        limits.append(limit); requestedScopes.append(scope.id); active += 1; maximumActive = max(maximumActive, active); defer { active -= 1 }
        if pauseFirst && !started {
            await withCheckedContinuation { continuation in firstGate = continuation; started = true; firstWaiter?.resume(); firstWaiter = nil }
        }
        if let failure { throw failure }
        guard let page = pages.first(where: { $0.scopeID == scope.id && $0.expectedAnchor == anchor }) else { throw HealthClientFailure.temporaryFailure }; return page
    }
    func statistics(metric: HealthMetric, date: String) async throws -> HealthDailyStatistics {
        if pauseStatistic && !statisticStarted {
            await withCheckedContinuation { continuation in statisticGate = continuation; statisticStarted = true; statisticWaiter?.resume(); statisticWaiter = nil }
        }
        guard !statisticsFailure, let statistic else { throw HealthClientFailure.temporaryFailure }; return statistic
    }
}
