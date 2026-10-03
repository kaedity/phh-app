import Foundation
import Testing
@testable import PHHHubCore
@Suite @MainActor struct HealthScreenTests {
    let h = HealthTests()
    @Test func sourceUnitRepresentativeAndReadFailureKeepOriginalID() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(), a = try h.sample(), b = try h.sample(61, at: h.time.addingTimeInterval(60))
        try store.registerHealthScope(scope); try store.ingestHealth(h.page(scope, added: [a,b]), synthetic: true)
        let screen = try HealthScreenModel(store: store, date: HealthDates.local(h.time))
        #expect(screen.latestWeight?.id == b.id); #expect(screen.weightDays.first?.representativeID == b.id); #expect(screen.weightSources.first == h.source)
        #expect(HealthMetric.bodyFatPercentage.displayValue(0.2) == 20); #expect(HealthMetric.bodyMass.displayUnit == "kg")
        try store.markHealthReadFailure(scope.id, state: .temporaryFailure); try screen.refresh(date: screen.date)
        #expect(screen.latestWeight?.value == 61); #expect(screen.readState(.bodyMass) == .temporaryFailure)
        let before = screen.weightSamples
        #expect(throws: HealthFailure.invalidValue) { try screen.refresh(date: "bad") }; #expect(screen.weightSamples == before)
    }
    @Test func missingZeroAndSelectedSourceNeverFallbackSilently() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(), screen = try HealthScreenModel(store: store, date: HealthDates.local(h.time))
        #expect(screen.latestWeight == nil); #expect(screen.dailyStatistics[.stepCount] == nil)
        try store.registerHealthScope(scope); try store.ingestHealth(h.page(scope, added: [try h.sample(0)]), synthetic: true); try screen.refresh(date: screen.date)
        #expect(screen.latestWeight?.value == 0); screen.selectedWeightSource = "unknown"; #expect(screen.latestWeight == nil)
        try screen.refresh(date: screen.date); #expect(screen.selectedWeightSource == "unknown")
    }
    @Test func boundedWeightHistoryLoadsNextPageWithoutInventingMissingDays() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope()
        try store.registerHealthScope(scope)
        let samples = try (0..<105).map { try h.sample(60 + Double($0)/100, at: h.time.addingTimeInterval(Double($0)*60)) }
        try store.ingestHealth(h.page(scope, added: samples), synthetic: true)
        let screen = try HealthScreenModel(store: store, date: HealthDates.local(h.time))
        #expect(screen.weightSamples.count == 100); #expect(screen.hasMoreWeight); try screen.loadMoreWeight()
        #expect(screen.weightSamples.count == 105); #expect(!screen.hasMoreWeight); #expect(screen.weightDays.count == 1)
        #expect(screen.weightDays.first?.minimum == 60); #expect(screen.weightDays.first?.measurementCount == 105)
    }
    @Test func sleepKeepsSourceAndWakeDayWithoutClaimingMainOrNap() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(metric: .sleepAnalysis)
        let sleep = try HealthSample(id: UUID().uuidString, metric: .sleepAnalysis, source: h.source, start: h.time.addingTimeInterval(-2*3600), end: h.time, value: nil, unit: "interval", sleepStage: .asleep)
        try store.registerHealthScope(scope); try store.ingestHealth(h.page(scope, added: [sleep]), synthetic: true)
        let screen = try HealthScreenModel(store: store, date: HealthDates.local(h.time))
        #expect(screen.currentSleep?.seconds == 7200); #expect(screen.currentSleep?.date == screen.date); #expect(screen.currentSleep?.classification == .unclassified)
        screen.selectedSleepSource = "missing"; #expect(screen.currentSleep == nil)
    }
    @Test func explicitBedWindowIncludesPreviousDayStagesAndNoWindowStaysUnclassified() throws {
        let store = try HubStore(owner: "synthetic@example.test"), scope = try h.scope(metric: .sleepAnalysis)
        let end = HealthDates.calendar.startOfDay(for: h.time).addingTimeInterval(7*3600), start = end.addingTimeInterval(-8*3600)
        func sample(_ a: Date, _ b: Date, _ stage: HealthSleepStage) throws -> HealthSample { try HealthSample(id:UUID().uuidString,metric:.sleepAnalysis,source:h.source,start:a,end:b,value:nil,unit:"interval",sleepStage:stage) }
        let first = try sample(start,start.addingTimeInterval(2*3600),.core), last = try sample(start.addingTimeInterval(2*3600),end,.deep)
        try store.registerHealthScope(scope); try store.ingestHealth(h.page(scope,added:[first,last]),synthetic:true)
        let screen = try HealthScreenModel(store:store,date:HealthDates.local(end)); #expect(screen.currentSleep == nil)
        let bed = try sample(start,end,.inBed); try store.ingestHealth(h.page(scope,anchor:Data([1]),next:2,added:[bed]),synthetic:true); try screen.refresh(date:screen.date)
        #expect(screen.currentSleep?.seconds == 28800.0); #expect(screen.currentSleepWindow?.id == bed.id)
    }
}
