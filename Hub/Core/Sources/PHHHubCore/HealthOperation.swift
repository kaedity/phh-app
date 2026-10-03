import Foundation

// 通信と端末保存でUnix秒を明示し、Foundationの参照日を外部へ漏らしません。
extension HealthSample {
  enum CodingKeys: String, CodingKey { case id, metric, source, start_utc, end_utc, value, unit, sleepStage }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(id: c.decode(String.self, forKey: .id), metric: c.decode(HealthMetric.self, forKey: .metric), source: c.decode(HealthSource.self, forKey: .source), start: Date(timeIntervalSince1970: c.decode(Double.self, forKey: .start_utc)), end: Date(timeIntervalSince1970: c.decode(Double.self, forKey: .end_utc)), value: c.decodeIfPresent(Double.self, forKey: .value), unit: c.decode(String.self, forKey: .unit), sleepStage: c.decodeIfPresent(HealthSleepStage.self, forKey: .sleepStage))
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id); try c.encode(metric, forKey: .metric); try c.encode(source, forKey: .source)
    try c.encode(start.timeIntervalSince1970, forKey: .start_utc); try c.encode(end.timeIntervalSince1970, forKey: .end_utc)
    try c.encode(value, forKey: .value); try c.encode(unit, forKey: .unit); try c.encode(sleepStage, forKey: .sleepStage)
  }
}
extension HealthDailyStatistics {
  public func validate() throws {
    guard metric.isCumulative, Schema.validDate(date), unit == metric.unit, method == "healthkit-statistics-v1", measuredAt.timeIntervalSince1970.isFinite,
      value == nil || value!.isFinite && value! >= 0 else { throw HealthFailure.invalidValue }
  }
  enum CodingKeys: String, CodingKey { case metric, date, value, unit, method, measured_at_utc }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(metric: c.decode(HealthMetric.self, forKey: .metric), date: c.decode(String.self, forKey: .date), value: c.decodeIfPresent(Double.self, forKey: .value), measuredAt: Date(timeIntervalSince1970: c.decode(Double.self, forKey: .measured_at_utc)))
    guard try c.decode(String.self, forKey: .unit) == unit, try c.decode(String.self, forKey: .method) == method else { throw HealthFailure.invalidValue }
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(metric, forKey: .metric); try c.encode(date, forKey: .date); try c.encode(value, forKey: .value)
    try c.encode(unit, forKey: .unit); try c.encode(method, forKey: .method); try c.encode(measuredAt.timeIntervalSince1970, forKey: .measured_at_utc)
  }
}

public struct HealthUploadPolicy: Codable, Equatable, Sendable {
  public let allowedMetrics: Set<HealthMetric>, from: String?, authorizedAt: Date?
  public init(allowedMetrics: Set<HealthMetric> = [], from: String? = nil, authorizedAt: Date? = nil) throws {
    guard allowedMetrics.isEmpty ? from == nil && authorizedAt == nil : from != nil && Schema.validDate(from!) && authorizedAt != nil && authorizedAt!.timeIntervalSince1970.isFinite else { throw HealthFailure.invalidScope }
    self.allowedMetrics = allowedMetrics; self.from = from; self.authorizedAt = authorizedAt
  }
  public func allows(_ delta: HealthCloudDelta) -> Bool {
    guard let from, authorizedAt != nil, allowedMetrics.contains(delta.metric) else { return false }
    // 原値を持たない先行削除は、承認済み種類のUUID索引にだけ作用します。
    if delta.affectedDates.isEmpty { return delta.added.isEmpty && delta.statistics.isEmpty && !delta.deletedIDs.isEmpty }
    return delta.affectedDates.allSatisfy { $0 >= from }
  }
}
extension HealthCloudDelta {
  public func validate() throws {
    guard UUID(uuidString: id) != nil, added.count + deletedIDs.count + statistics.count <= 500,
      Set(added.map(\.id)).count == added.count, Set(deletedIDs).count == deletedIDs.count,
      Set(added.map(\.id)).isDisjoint(with: Set(deletedIDs)),
      deletedIDs.allSatisfy({ UUID(uuidString: $0) != nil }), Set(affectedDates).count == affectedDates.count,
      affectedDates.allSatisfy(Schema.validDate), affectedDates.count <= 500 else { throw HealthFailure.invalidValue }
    guard statistics.count <= 500, Set(statistics.map(\.date)).count == statistics.count else { throw HealthFailure.invalidValue }
    for statistic in statistics { try statistic.validate(); guard statistic.metric == metric, affectedDates.contains(statistic.date) else { throw HealthFailure.invalidValue } }
    for sample in added { try sample.validate(); guard sample.metric == metric, sample.affectedDates.isSubset(of: Set(affectedDates)) else { throw HealthFailure.invalidValue } }
    let required = Set(added.flatMap { $0.affectedDates }).union(statistics.map(\.date))
    guard !deletedIDs.isEmpty || required == Set(affectedDates) else { throw HealthFailure.invalidValue }
  }
}
extension HubOperation {
  public init(health: HealthCloudDelta, synthetic: Bool) throws {
    self.init(action: "save_health_delta", entityID: health.id)
    operation_id = health.id; self.health = health; self.synthetic = synthetic
    try validate()
  }
  func validateHealth() throws {
    guard action == "save_health_delta", expected_revision == 0, let health, operation_id == health.id, entity_id == health.id,
      payload == nil, planning == nil, foodMeal == nil, foodVersion == nil, foodCategory == nil, foodPreset == nil, trainingCycle == nil, trainingSession == nil else { throw HubError.invalidOperation }
    do { try health.validate() } catch { throw HubError.invalidOperation }
    guard try JSONEncoder().encode(self).count <= 200 * 1024 else { throw HubError.invalidOperation }
  }
}
