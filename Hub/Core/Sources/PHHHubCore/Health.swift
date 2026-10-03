import Foundation
import CryptoKit

public enum HealthFailure: Error, Equatable { case invalidValue, invalidScope, anchorConflict, pageIDReused, sampleIDReused }
public enum HealthMetric: String, Codable, CaseIterable, Sendable {
  case bodyMass, bodyFatPercentage, bodyMassIndex, leanBodyMass, stepCount, activeEnergyBurned, basalEnergyBurned, sleepAnalysis
  public var unit: String {
    switch self {
    case .bodyMass, .leanBodyMass: "kg"
    case .bodyFatPercentage: "fraction"
    case .bodyMassIndex, .stepCount: "count"
    case .activeEnergyBurned, .basalEnergyBurned: "kcal"
    case .sleepAnalysis: "interval"
    }
  }
  public var isCumulative: Bool { [.stepCount, .activeEnergyBurned, .basalEnergyBurned].contains(self) }
}
public enum HealthReadState: String, Codable, Sendable { case available, unavailable, noDataOrNotAuthorized, temporaryFailure }
public enum HealthSleepStage: String, Codable, Sendable {
  case inBed, awake, asleep, core, deep, rem
  public var isAsleep: Bool { ![.inBed, .awake].contains(self) }
}
public struct HealthSource: Codable, Equatable, Sendable {
  public let id: String, name: String, device: String?
  public init(id: String, name: String, device: String? = nil) throws {
    guard !id.isEmpty, id.count <= 500, !name.isEmpty, name.count <= 500, device == nil || device!.count <= 500 else { throw HealthFailure.invalidValue }
    self.id = id; self.name = name; self.device = device
  }
}
public struct HealthSample: Codable, Equatable, Identifiable, Sendable {
  public let id: String, metric: HealthMetric, source: HealthSource, start: Date, end: Date, value: Double?, unit: String, sleepStage: HealthSleepStage?
  public init(id: String, metric: HealthMetric, source: HealthSource, start: Date, end: Date, value: Double?, unit: String, sleepStage: HealthSleepStage? = nil) throws {
    self.id = id.lowercased(); self.metric = metric; self.source = source; self.start = start; self.end = end; self.value = value; self.unit = unit; self.sleepStage = sleepStage
    try validate()
  }
  public func validate() throws {
    guard UUID(uuidString: id) != nil, unit == metric.unit, start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, end >= start,
      !source.id.isEmpty, !source.name.isEmpty, source.id.count <= 500, source.name.count <= 500, source.device == nil || source.device!.count <= 500,
      value == nil || value!.isFinite && value! >= 0 else { throw HealthFailure.invalidValue }
    if metric == .sleepAnalysis {
      guard sleepStage != nil, value == nil, end > start else { throw HealthFailure.invalidValue }
    } else {
      guard sleepStage == nil else { throw HealthFailure.invalidValue }
      if metric == .bodyFatPercentage, let value { guard value <= 1 else { throw HealthFailure.invalidValue } }
      if metric == .stepCount, let value { guard value.rounded() == value else { throw HealthFailure.invalidValue } }
    }
  }
  public var affectedDates: Set<String> {
    if metric == .sleepAnalysis { return [HealthDates.local(end)] }
    var dates: Set<String> = [HealthDates.local(start)]
    var day = HealthDates.calendar.startOfDay(for: start)
    while let next = HealthDates.calendar.date(byAdding: .day, value: 1, to: day), next < end, dates.count <= 500 {
      dates.insert(HealthDates.local(next)); day = next
    }
    return dates
  }
}
public enum HealthDates {
  public static var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Tokyo")!; return c }
  public static func local(_ date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
  }
}
public enum HealthImportPhase: String, Codable, Sendable { case recent, history }
public struct HealthQueryScope: Codable, Equatable, Identifiable, Sendable {
  public let id: String, deviceID: String, metric: HealthMetric, phase: HealthImportPhase, conditionVersion: Int, lowerBound: Date, upperBound: Date?
  public init(id: String = UUID().uuidString.lowercased(), deviceID: String, metric: HealthMetric, phase: HealthImportPhase,
    conditionVersion: Int = 1, lowerBound: Date, upperBound: Date? = nil) throws {
    self.id = id.lowercased(); self.deviceID = deviceID.lowercased(); self.metric = metric; self.phase = phase; self.conditionVersion = conditionVersion; self.lowerBound = lowerBound; self.upperBound = upperBound
    try validate()
  }
  public func validate() throws {
    guard UUID(uuidString: id) != nil, UUID(uuidString: deviceID) != nil, conditionVersion > 0, lowerBound.timeIntervalSince1970.isFinite,
      upperBound == nil || upperBound!.timeIntervalSince1970.isFinite && upperBound! > lowerBound else { throw HealthFailure.invalidScope }
  }
}
public struct HealthImportPage: Codable, Equatable, Identifiable, Sendable {
  public let id: String, scopeID: String, expectedAnchor: Data?, nextAnchor: Data, added: [HealthSample], deletedIDs: [String], hasMore: Bool, receivedAt: Date
  public let statistics: [HealthDailyStatistics]
  public init(id: String = UUID().uuidString.lowercased(), scopeID: String, expectedAnchor: Data?, nextAnchor: Data,
    added: [HealthSample], deletedIDs: [String], hasMore: Bool, receivedAt: Date, statistics: [HealthDailyStatistics] = []) {
    self.id = id.lowercased(); self.scopeID = scopeID.lowercased(); self.expectedAnchor = expectedAnchor; self.nextAnchor = nextAnchor
    self.statistics = statistics; self.added = added; self.deletedIDs = deletedIDs.map { $0.lowercased() }; self.hasMore = hasMore; self.receivedAt = receivedAt
  }
}
public struct HealthLocalRecord: Codable, Equatable, Sendable {
  public var sample: HealthSample?, removed: Bool
  public init(sample: HealthSample?, removed: Bool) { self.sample = sample; self.removed = removed }
}
public struct HealthImportProgress: Codable, Equatable, Sendable {
  public let scope: HealthQueryScope
  public var anchor: Data?, complete: Bool, receivedAt: Date?, readState: HealthReadState
}
/// アンカー・端末の取得条件は含めない、送信候補の写しです。
public struct HealthCloudDelta: Codable, Equatable, Identifiable, Sendable {
  public let id: String, metric: HealthMetric, added: [HealthSample], deletedIDs: [String], affectedDates: [String]
  public let statistics: [HealthDailyStatistics]
  public init(id: String, metric: HealthMetric, added: [HealthSample], deletedIDs: [String], affectedDates: [String], statistics: [HealthDailyStatistics] = []) {
    self.id = id; self.metric = metric; self.added = added; self.deletedIDs = deletedIDs; self.affectedDates = affectedDates; self.statistics = statistics
  }
}
public struct HealthLocalLedger: Codable, Equatable, Sendable {
  public private(set) var records: [String: HealthLocalRecord] = [:], scopes: [String: HealthImportProgress] = [:], receipts: [String: String] = [:]
  public init() {}
  public mutating func register(_ scope: HealthQueryScope) throws {
    try scope.validate()
    if let existing = scopes[scope.id] { guard existing.scope == scope else { throw HealthFailure.invalidScope }; return }
    guard !scopes.values.contains(where: { $0.scope.deviceID == scope.deviceID && $0.scope.metric == scope.metric && $0.scope.phase == scope.phase && $0.scope.conditionVersion == scope.conditionVersion }) else { throw HealthFailure.invalidScope }
    scopes[scope.id] = HealthImportProgress(scope: scope, anchor: nil, complete: false, receivedAt: nil, readState: .noDataOrNotAuthorized)
  }
  // 保存層は該当ページのUUIDとscopeだけを読み、全年度の本文を復元しません。
  init(records: [String: HealthLocalRecord], progress: HealthImportProgress, receipts: [String: String]) throws {
    try progress.scope.validate()
    for (key, record) in records {
      guard UUID(uuidString: key) != nil, record.sample != nil || record.removed else { throw HealthFailure.invalidValue }
      if let sample = record.sample { try sample.validate(); guard key == sample.id else { throw HealthFailure.invalidValue } }
    }
    self.records = records; self.scopes = [progress.scope.id: progress]; self.receipts = receipts
  }
  public var activeSamples: [HealthSample] { records.values.filter { !$0.removed }.compactMap(\.sample) }
  /// 値型の作業コピーで検証し、全ページ成功時だけ状態を切り替えます。
  public mutating func apply(_ page: HealthImportPage) throws -> HealthCloudDelta? {
    guard UUID(uuidString: page.id) != nil, !page.nextAnchor.isEmpty, page.receivedAt.timeIntervalSince1970.isFinite,
      page.added.count + page.deletedIDs.count <= 500, Set(page.added.map(\.id)).count == page.added.count,
      Set(page.deletedIDs).count == page.deletedIDs.count, page.deletedIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
      let current = scopes[page.scopeID] else { throw HealthFailure.invalidValue }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let hash = SHA256.hash(data: try encoder.encode(page)).map { String(format: "%02x", $0) }.joined()
    if let old = receipts[page.id] { guard old == hash else { throw HealthFailure.pageIDReused }; return nil }
    guard current.anchor == page.expectedAnchor else { throw HealthFailure.anchorConflict }
    var next = self, affected: Set<String> = [], added: [HealthSample] = [], deleted: [String] = []
    for sample in page.added {
      try sample.validate()
      guard sample.metric == current.scope.metric, sample.end >= current.scope.lowerBound,
        current.scope.upperBound == nil || sample.start < current.scope.upperBound! else { throw HealthFailure.invalidScope }
      let old = next.records[sample.id]
      if let previous = old?.sample { guard previous == sample else { throw HealthFailure.sampleIDReused } }
      if old?.removed == true { continue }
      if old == nil { next.records[sample.id] = HealthLocalRecord(sample: sample, removed: false); added.append(sample); affected.formUnion(sample.affectedDates) }
    }
    for id in page.deletedIDs {
      let old = next.records[id]
      if let sample = old?.sample { guard sample.metric == current.scope.metric else { throw HealthFailure.invalidScope }; affected.formUnion(sample.affectedDates) }
      if old?.removed != true { next.records[id] = HealthLocalRecord(sample: old?.sample, removed: true); deleted.append(id) }
    }
    for statistic in page.statistics { try statistic.validate(); guard statistic.metric == current.scope.metric else { throw HealthFailure.invalidScope }; affected.insert(statistic.date) }
    let candidate = HealthCloudDelta(id: page.id, metric: current.scope.metric, added: added.filter { !deleted.contains($0.id) }, deletedIDs: deleted, affectedDates: affected.sorted(), statistics: page.statistics)
    try candidate.validate()
    let readState: HealthReadState = next.activeSamples.contains(where: { $0.metric == current.scope.metric }) ? .available : .noDataOrNotAuthorized
    next.scopes[page.scopeID]?.anchor = page.nextAnchor; next.scopes[page.scopeID]?.complete = !page.hasMore
    next.scopes[page.scopeID]?.receivedAt = page.receivedAt
    next.scopes[page.scopeID]?.readState = readState
    next.receipts[page.id] = hash; self = next
    return candidate
  }
  public mutating func markReadFailure(scopeID: String, state: HealthReadState) throws {
    guard scopes[scopeID] != nil, [.unavailable, .temporaryFailure].contains(state) else { throw HealthFailure.invalidScope }
    scopes[scopeID]?.readState = state
  }
}
public struct HealthWeightDay: Equatable, Sendable {
  public let date: String, sourceID: String, representativeID: String, value: Double, minimum: Double, maximum: Double, measurementCount: Int, unknownCount: Int
}
public struct HealthSleepInterval: Equatable, Sendable { public let start: Date, end: Date }
public enum HealthSleepClassification: String, Codable, Sendable { case main, nap, unclassified }
public struct HealthSleepSession: Equatable, Sendable {
  public let sourceID: String, date: String, classification: HealthSleepClassification, intervals: [HealthSleepInterval], seconds: Double?
}
public struct HealthDailyStatistics: Codable, Equatable, Sendable {
  public let metric: HealthMetric, date: String, value: Double?, unit: String, method: String, measuredAt: Date
  public init(metric: HealthMetric, date: String, value: Double?, measuredAt: Date) throws {
    guard metric.isCumulative, Schema.validDate(date), value == nil || value!.isFinite && value! >= 0 else { throw HealthFailure.invalidValue }
    self.metric = metric; self.date = date; self.value = value; unit = metric.unit; method = "healthkit-statistics-v1"; self.measuredAt = measuredAt
  }
}
public enum HealthPresentation {
  public static func weightDays(_ samples: [HealthSample], sourceID: String) -> [HealthWeightDay] {
    let groups = Dictionary(grouping: samples.filter { $0.metric == .bodyMass && $0.source.id == sourceID }, by: { HealthDates.local($0.start) })
    return groups.compactMap { date, allRows -> HealthWeightDay? in
      let rows = allRows.filter { $0.value != nil }; guard !rows.isEmpty else { return nil }
      // 代表値は朝いちばんの測定（DESIGN 6章：朝・飲食前に測る）。4時より前の測定は夜更かし中の可能性があるので、
      // 4時以降の測定があればその最初を使い、なければその日の最初を使う。範囲（最小〜最大）は全測定のまま。
      let ordered = rows.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
      let morning = ordered.first { HealthDates.calendar.component(.hour, from: $0.start) >= 4 } ?? ordered.first!
      return HealthWeightDay(date: date, sourceID: sourceID, representativeID: morning.id, value: morning.value!, minimum: rows.map { $0.value! }.min()!, maximum: rows.map { $0.value! }.max()!, measurementCount: allRows.count, unknownCount: allRows.count - rows.count)
    }.sorted { $0.date < $1.date }
  }
  /// 主睡眠/昼寝の境界は元セッションまたは明示した区間を受け、推定の隙間で結合しません。
  public static func sleep(_ samples: [HealthSample], sourceID: String, start: Date, end: Date, classification: HealthSleepClassification) throws -> HealthSleepSession {
    guard end > start else { throw HealthFailure.invalidValue }
    let values = samples.filter { $0.metric == .sleepAnalysis && $0.source.id == sourceID && $0.sleepStage?.isAsleep == true }
      .compactMap { sample -> HealthSleepInterval? in let a = max(sample.start, start), b = min(sample.end, end); return b > a ? HealthSleepInterval(start: a, end: b) : nil }.sorted { $0.start < $1.start }
    var merged: [HealthSleepInterval] = []
    for interval in values {
      if let last = merged.last, interval.start <= last.end { merged[merged.count - 1] = HealthSleepInterval(start: last.start, end: max(last.end, interval.end)) }
      else { merged.append(interval) }
    }
    return HealthSleepSession(sourceID: sourceID, date: HealthDates.local(end), classification: classification, intervals: merged, seconds: merged.isEmpty ? nil : merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) })
  }
}

// 体重の7日平均と週の変化（DESIGN 6章：判断は単日でなく7日平均）。測った日が7日のうち5日未満なら出さない。欠けた日は補わない。
public struct HealthWeightTrend: Equatable, Sendable {
  public let average: Double, previousAverage: Double?, change: Double?, percentPerWeek: Double?, measuredDays: Int
}
extension HealthPresentation {
  static func shift(_ date: String, _ days: Int) -> String? {
    guard let d = HealthDates.calendar.date(from: DateComponents(year: Int(date.prefix(4)), month: Int(date.dropFirst(5).prefix(2)), day: Int(date.suffix(2)))),
          let s = HealthDates.calendar.date(byAdding: .day, value: days, to: d) else { return nil }
    return HealthDates.local(s.addingTimeInterval(3600))
  }
  static func window(_ days: [HealthWeightDay], end: String, length: Int = 7) -> [HealthWeightDay] {
    guard let start = shift(end, -(length - 1)) else { return [] }
    return days.filter { $0.date >= start && $0.date <= end }
  }
  public static func weightTrend(_ days: [HealthWeightDay], end: String, minimumDays: Int = 5) -> HealthWeightTrend? {
    let now = window(days, end: end); guard now.count >= minimumDays else { return nil }
    let average = now.map(\.value).reduce(0, +) / Double(now.count)
    let previous = shift(end, -7).map { window(days, end: $0) } ?? []
    guard previous.count >= minimumDays else { return HealthWeightTrend(average: average, previousAverage: nil, change: nil, percentPerWeek: nil, measuredDays: now.count) }
    let before = previous.map(\.value).reduce(0, +) / Double(previous.count), change = average - before
    return HealthWeightTrend(average: average, previousAverage: before, change: change, percentPerWeek: before > 0 ? change / before * 100 : nil, measuredDays: now.count)
  }
  /// グラフ用の7日平均。各日について、その日までの7日に5日以上の測定がある日だけ点を作る。
  public static func weightAverages(_ days: [HealthWeightDay], minimumDays: Int = 5) -> [(date: String, value: Double)] {
    days.compactMap { day in let w = window(days, end: day.date); return w.count >= minimumDays ? (day.date, w.map(\.value).reduce(0, +) / Double(w.count)) : nil }
  }
}
