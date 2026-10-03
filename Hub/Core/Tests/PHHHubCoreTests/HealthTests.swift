import Foundation
import Testing
@testable import PHHHubCore

@Suite struct HealthTests {
  let source = try! HealthSource(id: "synthetic.eufy", name: "架空Eufy")
  let time = Date(timeIntervalSince1970: 1790953200)
  func scope(_ phase: HealthImportPhase = .recent, metric: HealthMetric = .bodyMass, device: String = "00000000-0000-4000-a000-000000000001") throws -> HealthQueryScope {
    try HealthQueryScope(deviceID: device, metric: metric, phase: phase, lowerBound: time.addingTimeInterval(-30 * 86400))
  }
  func sample(_ value: Double? = 60, metric: HealthMetric = .bodyMass, at: Date? = nil, id: String = UUID().uuidString) throws -> HealthSample {
    try HealthSample(id: id, metric: metric, source: source, start: at ?? time, end: at ?? time, value: value, unit: metric.unit)
  }
  func page(_ scope: HealthQueryScope, anchor: Data? = nil, next: UInt8 = 1, added: [HealthSample] = [], deleted: [String] = [], id: String = UUID().uuidString) -> HealthImportPage {
    HealthImportPage(id: id, scopeID: scope.id, expectedAnchor: anchor, nextAnchor: Data([next]), added: added, deletedIDs: deleted, hasMore: false, receivedAt: time)
  }
  @Test func metricUnitsNullZeroAndSourceMetadataRemainDistinct() throws {
    #expect(try sample(nil, metric: .activeEnergyBurned).value == nil)
    #expect(try sample(0, metric: .activeEnergyBurned).value == 0)
    #expect(throws: HealthFailure.invalidValue) { try sample(.nan) }
    #expect(throws: HealthFailure.invalidValue) { try sample(12, metric: .bodyFatPercentage) }
    #expect(throws: HealthFailure.invalidValue) { try sample(0.5, metric: .stepCount) }
    #expect(throws: HealthFailure.invalidValue) { try HealthSample(id: UUID().uuidString, metric: .bodyMass, source: source, start: time, end: time, value: 60, unit: "lb") }
    #expect(try sample(0.12, metric: .bodyFatPercentage).unit == "fraction")
  }
  @Test func fixedScopesOverlapIdempotentlyAndBadPageNeverPartiallyApplies() throws {
    var ledger = HealthLocalLedger(); let recent = try scope(), history = try scope(.history), s = try sample()
    try ledger.register(recent); try ledger.register(history)
    let first = page(recent, added: [s]); #expect(try ledger.apply(first)?.added == [s]); #expect(try ledger.apply(first) == nil)
    #expect(try ledger.apply(page(history, added: [s]))?.added.isEmpty == true); #expect(ledger.activeSamples == [s])
    let before = ledger
    #expect(throws: HealthFailure.anchorConflict) { try ledger.apply(page(recent, added: [try sample()])) }
    #expect(ledger == before)
    let different = try sample(90, id: s.id)
    #expect(throws: HealthFailure.sampleIDReused) { try ledger.apply(page(recent, anchor: Data([1]), next: 2, added: [try sample(), different])) }
    #expect(ledger == before)
    #expect(throws: HealthFailure.pageIDReused) { try ledger.apply(page(recent, added: [different], id: first.id)) }
    let moved = try HealthQueryScope(id: recent.id, deviceID: recent.deviceID, metric: recent.metric, phase: recent.phase, lowerBound: time)
    #expect(throws: HealthFailure.invalidScope) { try ledger.register(moved) }
  }
  @Test func deletionAheadOfHistoryNeverResurrectsAndCorrectionUsesNewUUID() throws {
    var ledger = HealthLocalLedger(); let recent = try scope(), history = try scope(.history), old = try sample(), replacement = try sample(61)
    try ledger.register(recent); try ledger.register(history)
    #expect(try ledger.apply(page(recent, deleted: [old.id]))?.deletedIDs == [old.id])
    #expect(try ledger.apply(page(history, added: [old]))?.added.isEmpty == true); #expect(ledger.activeSamples.isEmpty)
    let delta = try ledger.apply(page(recent, anchor: Data([1]), next: 2, added: [replacement], deleted: [old.id]))
    #expect(ledger.activeSamples == [replacement]); #expect(delta?.affectedDates == [HealthDates.local(time)])
    #expect(ledger.records[old.id]?.removed == true)
    let encoder = JSONEncoder(); let body = String(decoding: try encoder.encode(delta), as: UTF8.self)
    #expect(!body.contains("Anchor")); #expect(!body.contains("scopeID")); #expect(!body.contains("deviceID"))
  }
  @Test func emptyOrFailedReadRetainsPriorMeasurementsAndOtherScopes() throws {
    var ledger = HealthLocalLedger(); let recent = try scope(), sleep = try scope(metric: .sleepAnalysis), s = try sample()
    try ledger.register(recent); try ledger.register(sleep); _ = try ledger.apply(page(recent, added: [s]))
    try ledger.markReadFailure(scopeID: recent.id, state: .temporaryFailure)
    #expect(ledger.activeSamples == [s]); #expect(ledger.scopes[recent.id]?.anchor == Data([1]))
    _ = try ledger.apply(page(recent, anchor: Data([1]), next: 2))
    #expect(ledger.activeSamples == [s]); #expect(ledger.scopes[sleep.id]?.complete == false)
    #expect(ledger.scopes[sleep.id]?.readState == .noDataOrNotAuthorized)
  }
  @Test func weightRepresentativesKeepAllMeasurementsAndSourcesSeparate() throws {
    let other = try HealthSource(id: "synthetic.other", name: "別の架空情報源")
    let a = try sample(60), b = try sample(61, at: time.addingTimeInterval(3600))
    let c = try HealthSample(id: UUID().uuidString, metric: .bodyMass, source: other, start: time, end: time, value: 90, unit: "kg")
    let all = [a,b,c,try sample(nil)]
    let days = HealthPresentation.weightDays(all, sourceID: source.id)
    #expect(days.count == 1); #expect(days[0].representativeID == a.id); #expect(days[0].value == 60)
    #expect(days[0].minimum == 60); #expect(days[0].maximum == 61); #expect(days[0].measurementCount == 3); #expect(days[0].unknownCount == 1); #expect(all.count == 4)
    #expect(HealthPresentation.weightDays(all, sourceID: "missing").isEmpty)
  }
  @Test func weightRepresentativeIsTheFirstMorningMeasurementNotTheEvening() throws {
    // time は 10/3 0:00 JST。2:00の夜ふかし計測・7:00の朝・22:00の入浴後。
    let late = try sample(71.0, at: time.addingTimeInterval(2*3600)), morning = try sample(70.2, at: time.addingTimeInterval(7*3600)), evening = try sample(71.4, at: time.addingTimeInterval(22*3600))
    let day = HealthPresentation.weightDays([evening, late, morning], sourceID: source.id)[0]
    #expect(day.representativeID == morning.id); #expect(day.value == 70.2); #expect(day.minimum == 70.2); #expect(day.maximum == 71.4)
  }
  @Test func sleepUnionUsesOneSourceWakeDateAndExplicitSessionNotInventedStageTotals() throws {
    let start = Date(timeIntervalSince1970: 1790951400), end = start.addingTimeInterval(8*3600)
    func sleep(_ offset: Double, _ duration: Double, _ stage: HealthSleepStage, _ src: HealthSource? = nil) throws -> HealthSample {
      try HealthSample(id: UUID().uuidString, metric: .sleepAnalysis, source: src ?? source, start: start.addingTimeInterval(offset), end: start.addingTimeInterval(offset+duration), value: nil, unit: "interval", sleepStage: stage)
    }
    let other = try HealthSource(id: "synthetic.watch", name: "架空Watch")
    let values = [try sleep(0, 4*3600, .asleep), try sleep(2*3600, 4*3600, .core), try sleep(0, 8*3600, .inBed), try sleep(6*3600, 3600, .awake), try sleep(0, 8*3600, .deep, other)]
    let session = try HealthPresentation.sleep(values, sourceID: source.id, start: start, end: end, classification: .main)
    #expect(session.seconds == 21600.0); #expect(session.intervals.count == 1); #expect(session.date == HealthDates.local(end)); #expect(session.classification == .main)
    #expect(try HealthPresentation.sleep(values, sourceID: "missing", start: start, end: end, classification: .unclassified).seconds == nil)
    let nap = try HealthPresentation.sleep(values, sourceID: other.id, start: start.addingTimeInterval(7*3600), end: end, classification: .nap)
    #expect(nap.seconds == 3600); #expect(nap.classification == .nap)
    let stats = try HealthDailyStatistics(metric: .stepCount, date: HealthDates.local(time), value: 100, measuredAt: time)
    #expect(stats.value == 100); #expect(stats.method == "healthkit-statistics-v1")
    #expect(try HealthDailyStatistics(metric: .stepCount, date: stats.date, value: nil, measuredAt: time).value == nil)
  }
}

struct HealthWeightTrendTests {
  func day(_ date: String, _ v: Double) -> HealthWeightDay { HealthWeightDay(date: date, sourceID: "s", representativeID: date, value: v, minimum: v, maximum: v, measurementCount: 1, unknownCount: 0) }
  @Test func weeklyTrendNeedsFiveDaysAndComparesWithThePreviousWeek() throws {
    let last = (0..<7).map { day(String(format: "2026-10-%02d", 4 + $0), 65.5 + 0.05 * Double($0)) }
    let prev = ["2026-09-28","2026-09-29","2026-09-30","2026-10-01","2026-10-02"].map { day($0, 65.2) }
    let t = try #require(HealthPresentation.weightTrend(prev + last, end: "2026-10-10"))
    #expect(abs(t.average - 65.65) < 1e-9); #expect(abs((t.change ?? 0) - 0.45) < 1e-9); #expect(t.measuredDays == 7)
    #expect(HealthPresentation.weightTrend(Array(last.prefix(4)), end: "2026-10-07") == nil)
    #expect(HealthPresentation.weightTrend(last, end: "2026-10-10")?.change == nil)
    #expect(HealthPresentation.weightAverages(prev + last).first?.date == "2026-10-02")
  }
}
