import Foundation

public enum SupplementFailure: Error, LocalizedError {
  case invalidValue, missingReference, revisionConflict
  public var errorDescription: String? {
    switch self {
    case .invalidValue: "サプリの量・成分・対象日を確認してください。"
    case .missingReference: "サプリの予定と商品版を確認してください。"
    case .revisionConflict: "サプリの記録に変更があります。現在の内容を確認してください。"
    }
  }
}
/// 欠測はnil、表示に根拠があるゼロは0。単位と出典を成分ごとに保持します。
public struct SupplementNutrient: Codable, Equatable, Sendable {
  public let nutrientID: String, value: Double?, unit: String, source: String
  public init(nutrientID: String, value: Double?, unit: String, source: String) throws {
    self.nutrientID = nutrientID; self.value = value; self.unit = unit; self.source = source
    try validate()
  }
  public func validate() throws {
    try FoodRules.text(nutrientID); try FoodRules.text(unit)
    let units = ["kcal":"kcal", "protein":"g", "fat":"g", "carbohydrate":"g"]
    guard FoodRules.sources.contains(source), ["kcal", "g", "mg", "µg"].contains(unit),
      units[nutrientID].map({ $0 == unit }) ?? true,
      value.map({ $0.isFinite && $0 >= 0 && $0 <= 100_000 }) ?? true
    else { throw SupplementFailure.invalidValue }
  }
  public func scaled(by factor: Double) throws -> Self {
    guard factor.isFinite, factor > 0 else { throw SupplementFailure.invalidValue }
    return try .init(nutrientID: nutrientID, value: value.map { $0 * factor }, unit: unit, source: source)
  }
}
public struct SupplementProductVersion: Codable, Equatable, Sendable, Identifiable {
  public let id: String, productID: String, revision: Int, name: String,
    referenceAmount: Double, unit: String, nutrients: [SupplementNutrient]
  public init(id: String = UUID().uuidString, productID: String = UUID().uuidString,
    revision: Int = 1, name: String, referenceAmount: Double = 1, unit: String,
    nutrients: [SupplementNutrient]) throws {
    self.id = id; self.productID = productID; self.revision = revision; self.name = name
    self.referenceAmount = referenceAmount; self.unit = unit; self.nutrients = nutrients
    try validate()
  }
  public func validate() throws {
    try FoodRules.id(id); try FoodRules.id(productID); try FoodRules.text(name)
    try FoodRules.text(unit); try FoodRules.quantity(referenceAmount)
    guard revision > 0, Set(nutrients.map(\.nutrientID)).count == nutrients.count,
      Set(nutrients.map(\.nutrientID)).isSuperset(of: ["kcal", "protein", "fat", "carbohydrate"])
    else { throw SupplementFailure.invalidValue }
    for nutrient in nutrients { try nutrient.validate() }
  }
}
/// 適用日を持つ不変の予定版。商品改訂は新しい商品版を参照する予定版で行います。
public struct SupplementPlanVersion: Codable, Equatable, Sendable, Identifiable {
  public let id: String, planID: String, revision: Int, productVersionID: String,
    dailyAmount: Double, effectiveFrom: String, effectiveThrough: String?, autoCount: Bool
  public init(id: String = UUID().uuidString, planID: String = UUID().uuidString,
    revision: Int = 1, productVersionID: String, dailyAmount: Double,
    effectiveFrom: String, effectiveThrough: String? = nil, autoCount: Bool = true) throws {
    self.id = id; self.planID = planID; self.revision = revision
    self.productVersionID = productVersionID; self.dailyAmount = dailyAmount
    self.effectiveFrom = effectiveFrom; self.effectiveThrough = effectiveThrough; self.autoCount = autoCount
    try validate()
  }
  public func validate() throws {
    for id in [id, planID, productVersionID] { try FoodRules.id(id) }
    try FoodRules.quantity(dailyAmount); try FoodRules.date(effectiveFrom)
    guard revision > 0 else { throw SupplementFailure.invalidValue }
    if let effectiveThrough {
      try FoodRules.date(effectiveThrough)
      guard effectiveThrough >= effectiveFrom else { throw SupplementFailure.invalidValue }
    }
  }
}
public enum SupplementDayState: String, Codable, Sendable { case planned, confirmed, excluded }
public struct SupplementDay: Codable, Equatable, Sendable, Identifiable {
  public let id: String, planID: String, date: String, planVersionID: String,
    productVersionID: String, productName: String, amount: Double, unit: String,
    nutrients: [SupplementNutrient], revision: Int, state: SupplementDayState, dailyOverride: Bool
  public var key: String { "\(planID)|\(date)" }
  public var isCounted: Bool { state != .excluded }
  public var isConfirmed: Bool { state == .confirmed }
  fileprivate init(id: String = UUID().uuidString, date: String, plan: SupplementPlanVersion,
    product: SupplementProductVersion, amount: Double, revision: Int = 1,
    state: SupplementDayState = .planned, dailyOverride: Bool = false) throws {
    self.id = id; self.planID = plan.planID; self.date = date; planVersionID = plan.id
    productVersionID = product.id; productName = product.name; self.amount = amount; unit = product.unit
    nutrients = try product.nutrients.map { try $0.scaled(by: amount / product.referenceAmount) }
    self.revision = revision; self.state = state; self.dailyOverride = dailyOverride
    try validate()
  }
  public func validate() throws {
    for id in [id, planID, planVersionID, productVersionID] { try FoodRules.id(id) }
    try FoodRules.date(date); try FoodRules.text(productName); try FoodRules.text(unit)
    try FoodRules.quantity(amount)
    guard revision > 0, Set(nutrients.map(\.nutrientID)).count == nutrients.count,
      Set(nutrients.map(\.nutrientID)).isSuperset(of: ["kcal", "protein", "fat", "carbohydrate"])
    else { throw SupplementFailure.invalidValue }
    for nutrient in nutrients { try nutrient.validate() }
  }
}
public struct SupplementLedger: Codable, Equatable, Sendable {
  public private(set) var products: [SupplementProductVersion], plans: [SupplementPlanVersion], days: [SupplementDay]
  public init(products: [SupplementProductVersion] = [], plans: [SupplementPlanVersion] = [],
    days: [SupplementDay] = []) throws {
    self.products = products; self.plans = plans; self.days = days; try validate()
  }
  public func validate() throws {
    guard Set(products.map(\.id)).count == products.count,
      Set(products.map { "\($0.productID)|\($0.revision)" }).count == products.count,
      Set(plans.map(\.id)).count == plans.count,
      Set(plans.map { "\($0.planID)|\($0.revision)" }).count == plans.count,
      Set(days.map(\.id)).count == days.count, Set(days.map(\.key)).count == days.count
    else { throw SupplementFailure.invalidValue }
    for p in products { try p.validate() }
    for p in plans { try p.validate(); _ = try product(p.productVersionID) }
    for group in Dictionary(grouping: plans, by: \.planID).values {
      let ordered = group.sorted { $0.revision < $1.revision }
      for (a,b) in zip(ordered, ordered.dropFirst()) {
        guard b.effectiveFrom >= a.effectiveFrom else { throw SupplementFailure.invalidValue }
      }
    }
    for d in days {
      try d.validate()
      guard let p = plans.first(where: { $0.id == d.planVersionID }), p.planID == d.planID,
        p.productVersionID == d.productVersionID, d.date >= p.effectiveFrom,
        p.effectiveThrough.map({ d.date <= $0 }) ?? true else { throw SupplementFailure.missingReference }
      let product = try product(d.productVersionID)
      guard d.productName == product.name, d.unit == product.unit,
        d.nutrients == (try product.nutrients.map { try $0.scaled(by: d.amount / product.referenceAmount) })
      else { throw SupplementFailure.invalidValue }
    }
  }
  private func product(_ id: String) throws -> SupplementProductVersion {
    guard let p = products.first(where: { $0.id == id }) else { throw SupplementFailure.missingReference }
    return p
  }
  private func plan(_ id: String, date: String) -> SupplementPlanVersion? {
    // 新版の開始日以降に、終了済みの旧版が復活することも防ぎます。
    guard let latest = plans.filter({ $0.planID == id && $0.effectiveFrom <= date })
      .max(by: { $0.revision < $1.revision }), latest.effectiveThrough.map({ date <= $0 }) ?? true
    else { return nil }
    return latest
  }
  public mutating func addProduct(_ value: SupplementProductVersion) throws {
    try value.validate()
    if let old = products.first(where: { $0.id == value.id }) {
      guard old == value else { throw SupplementFailure.revisionConflict }; return
    }
    guard value.revision == (products.filter { $0.productID == value.productID }.map(\.revision).max() ?? 0) + 1
    else { throw SupplementFailure.revisionConflict }
    var next = self; next.products.append(value); try next.validate(); self = next
  }
  public mutating func addPlan(_ value: SupplementPlanVersion) throws {
    try value.validate()
    if let old = plans.first(where: { $0.id == value.id }) {
      guard old == value else { throw SupplementFailure.revisionConflict }; return
    }
    guard value.revision == (plans.filter { $0.planID == value.planID }.map(\.revision).max() ?? 0) + 1
    else { throw SupplementFailure.revisionConflict }
    var next = self; next.plans.append(value); try next.validate(); self = next
  }
  /// 過去に保存した写し、明示除外・確認・日別量は自動処理で変えません。
  @discardableResult public mutating func materialize(planID: String, date: String, today: String) throws -> SupplementDay? {
    try validate(); try FoodRules.id(planID); try FoodRules.date(date); try FoodRules.date(today)
    guard date <= today else { throw SupplementFailure.invalidValue }
    let old = days.first(where: { $0.planID == planID && $0.date == date })
    if let old, date < today || old.dailyOverride || old.state == .confirmed { return old }
    guard let p = plan(planID, date: date), p.autoCount else {
      guard let old, old.state != .excluded,
        let oldPlan = plans.first(where: { $0.id == old.planVersionID }) else { return old }
      let value = try SupplementDay(id: old.id, date: date, plan: oldPlan,
        product: product(old.productVersionID), amount: old.amount, revision: old.revision + 1,
        state: .excluded)
      replace(value); return value
    }
    let product = try product(p.productVersionID)
    if let old, old.planVersionID == p.id, old.state == .planned { return old }
    let value = try SupplementDay(id: old?.id ?? UUID().uuidString, date: date, plan: p,
      product: product, amount: p.dailyAmount, revision: (old?.revision ?? 0) + 1)
    replace(value); return value
  }
  /// 手動報告は同じ予定ID/日付を更新。取り消した日は明示的な服用報告でのみ復帰します。
  @discardableResult public mutating func change(planID: String, date: String, expectedRevision: Int,
    amount: Double? = nil, state: SupplementDayState) throws -> SupplementDay {
    try validate(); try FoodRules.id(planID); try FoodRules.date(date)
    let old = days.first(where: { $0.planID == planID && $0.date == date })
    guard expectedRevision == (old?.revision ?? 0) else { throw SupplementFailure.revisionConflict }
    guard let p = old.flatMap({ d in plans.first { $0.id == d.planVersionID } }) ?? plan(planID, date: date)
    else { throw SupplementFailure.missingReference }
    let value = try SupplementDay(id: old?.id ?? UUID().uuidString, date: date, plan: p,
      product: product(p.productVersionID), amount: amount ?? old?.amount ?? p.dailyAmount,
      revision: expectedRevision + 1, state: state, dailyOverride: true)
    replace(value); return value
  }
  private mutating func replace(_ day: SupplementDay) {
    if let index = days.firstIndex(where: { $0.key == day.key }) { days[index] = day }
    else { days.append(day) }
  }
}
