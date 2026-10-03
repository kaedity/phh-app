import Foundation

public enum HydrationFailure: String, Error {
  case invalidValue, conflictingRevision
}

/// F11の水分記録。食品名から推定せず、mlを明示して独立した記録として扱います。
public struct HydrationRecord: Codable, Equatable, Identifiable, Sendable {
  public let id: String, date: String, revision: Int, amountML: Double, removed: Bool
  public init(id: String = UUID().uuidString, date: String, revision: Int = 1,
              amountML: Double, removed: Bool = false) throws {
    self.id=id; self.date=date; self.revision=revision; self.amountML=amountML; self.removed=removed
    try validate()
  }
  public func validate() throws {
    try FoodRules.id(id); try FoodRules.date(date)
    guard revision > 0, amountML.isFinite, amountML > 0 else { throw HydrationFailure.invalidValue }
  }
}

public struct HydrationPreferences: Codable, Equatable, Sendable {
  public let addAmountML: Double, dailyGoalML: Double?
  public init(addAmountML: Double = 250, dailyGoalML: Double? = nil) throws {
    self.addAmountML=addAmountML; self.dailyGoalML=dailyGoalML
    try validate()
  }
  public func validate() throws {
    guard addAmountML.isFinite, addAmountML > 0,
          dailyGoalML.map({ $0.isFinite && $0 > 0 }) ?? true else { throw HydrationFailure.invalidValue }
  }
}

public struct HydrationDaySummary: Equatable, Sendable {
  public let totalML: Double, recordCount: Int, goalML: Double?
  public var remainingML: Double? { goalML.map { max(0,$0-totalML) } }
  public var excessML: Double? { goalML.map { max(0,totalML-$0) } }
  public var progress: Double? { goalML.map { min(1,totalML/$0) } }
}

/// 渡された記録の集計だけを行います。未取得の記録を補完しません。
public enum HydrationAggregation {
  public static func day(_ date: String, records: [HydrationRecord],
                         preferences: HydrationPreferences) throws -> HydrationDaySummary {
    try FoodRules.date(date); try preferences.validate()
    var versions: [String:[Int:HydrationRecord]]=[:]
    for record in records {
      try record.validate()
      if let prior=versions[record.id]?[record.revision], prior != record {
        throw HydrationFailure.conflictingRevision
      }
      versions[record.id,default:[:]][record.revision]=record
    }
    let current=versions.values.compactMap { $0.values.max { $0.revision < $1.revision } }
      .filter { !$0.removed && $0.date == date }
    let total=current.reduce(0) { $0+$1.amountML }
    guard total.isFinite else { throw HydrationFailure.invalidValue }
    return .init(totalML:total,recordCount:current.count,goalML:preferences.dailyGoalML)
  }
}
