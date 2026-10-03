import Foundation

public enum FoodFailure: String, Error, LocalizedError {
  case invalidValue, missingReference, duplicateID, unresolvedQuestions, revisionConflict,
    pendingEdit, invalidReceipt
  public var errorDescription: String? {
    switch self {
    case .invalidValue: "食品・量・栄養値を確認してください。"
    case .missingReference: "参照する食品の版が見つかりません。"
    case .duplicateID: "同じIDの内容が一致しません。"
    case .unresolvedQuestions: "確認が必要な質問へ回答してください。"
    case .revisionConflict: "別の更新があります。確定値を確認してください。"
    case .pendingEdit: "この食事の変更を送信中です。"
    case .invalidReceipt: "保存結果を確認できません。前回の確定値を保持します。"
    }
  }
}
public enum FoodNutrient: String, Codable, CaseIterable, Sendable {
  case kcal, protein, fat, carbohydrate
}
public struct FoodNutrients: Codable, Equatable, Sendable {
  public var kcal: Double?, protein: Double?, fat: Double?, carbohydrate: Double?
  public init(kcal: Double?, protein: Double?, fat: Double?, carbohydrate: Double?) throws {
    self.kcal = kcal
    self.protein = protein
    self.fat = fat
    self.carbohydrate = carbohydrate
    try validate()
  }
  public subscript(_ key: FoodNutrient) -> Double? {
    switch key {
    case .kcal: kcal
    case .protein: protein
    case .fat: fat
    case .carbohydrate: carbohydrate
    }
  }
  public func validate() throws {
    guard
      FoodNutrient.allCases.allSatisfy({
        self[$0].map { $0.isFinite && $0 >= 0 && $0 <= 100_000 } ?? true
      })
    else { throw FoodFailure.invalidValue }
  }
  public func scaled(_ factor: Double) throws -> Self {
    guard factor.isFinite && factor > 0 && factor <= 1000 else { throw FoodFailure.invalidValue }
    return try .init(
      kcal: kcal.map { $0 * factor }, protein: protein.map { $0 * factor },
      fat: fat.map { $0 * factor }, carbohydrate: carbohydrate.map { $0 * factor })
  }
}
public enum FoodRules {
  public static let sources = ["推定","商品表示","成分表","レシピ","プリセット","本人"]
  public static let slots = ["朝食", "昼食", "夕食", "間食"]
  public static func date(_ value: String) throws {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    f.dateFormat = "yyyy-MM-dd"
    f.isLenient = false
    guard value.count == 10, let d = f.date(from: value), f.string(from: d) == value else {
      throw FoodFailure.invalidValue
    }
  }
  public static func text(_ value: String, limit: Int = 200) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= limit
    else { throw FoodFailure.invalidValue }
  }
  public static func id(_ value: String) throws {
    guard UUID(uuidString: value) != nil else { throw FoodFailure.invalidValue }
  }
  public static func quantity(_ value: Double) throws {
    guard value.isFinite && value > 0 && value <= 1_000_000 else { throw FoodFailure.invalidValue }
  }
}
/// 食品版は不変。調理状態と表示単位も栄養値と同じ版に含めます。
public struct FoodVersion: Codable, Equatable, Identifiable, Sendable {
  public let id: String, foodID: String, revision: Int, name: String, quantity: Double,
    unit: String, preparation: String, source: String, nutrients: FoodNutrients
  public init(
    id: String = UUID().uuidString, foodID: String = UUID().uuidString, revision: Int = 1,
    name: String, quantity: Double = 1, unit: String, preparation: String = "未指定", source: String,
    nutrients: FoodNutrients
  ) throws {
    self.id = id
    self.foodID = foodID
    self.revision = revision
    self.name = name
    self.quantity = quantity
    self.unit = unit
    self.preparation = preparation
    self.source = source
    self.nutrients = nutrients
    try validate()
  }
  public func validate() throws {
    try FoodRules.id(id)
    try FoodRules.id(foodID)
    guard revision > 0 else { throw FoodFailure.invalidValue }
    for s in [name, unit, preparation, source] { try FoodRules.text(s) }
    guard FoodRules.sources.contains(source) else { throw FoodFailure.invalidValue }
    try FoodRules.quantity(quantity)
    try nutrients.validate()
  }
}
public struct FoodCategory: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public var name: String, archived: Bool
  public init(id: String = UUID().uuidString, name: String, archived: Bool = false) throws {
    try FoodRules.id(id)
    try FoodRules.text(name)
    self.id = id
    self.name = name
    self.archived = archived
  }
}
public struct FoodComponent: Codable, Equatable, Sendable {
  public let versionID: String, factor: Double
  public init(versionID: String, factor: Double = 1) throws {
    try FoodRules.id(versionID)
    try FoodRules.quantity(factor)
    self.versionID = versionID
    self.factor = factor
  }
}
public struct FoodPreset: Codable, Equatable, Identifiable, Sendable {
  public let id: String, revision: Int
  public var name: String, categoryID: String?, components: [FoodComponent], archived: Bool
  public init(
    id: String = UUID().uuidString, revision: Int = 1, name: String, categoryID: String? = nil,
    components: [FoodComponent], archived: Bool = false
  ) throws {
    self.id = id
    self.revision = revision
    self.name = name
    self.categoryID = categoryID
    self.components = components
    self.archived = archived
    try validate()
  }
  public func validate() throws {
    try FoodRules.id(id)
    try FoodRules.text(name)
    if let categoryID { try FoodRules.id(categoryID) }
    guard revision > 0 && !components.isEmpty && components.count <= 50 && Set(components.map(\.versionID)).count==components.count else {
      throw FoodFailure.invalidValue
    }
    for c in components {
      try FoodRules.id(c.versionID)
      try FoodRules.quantity(c.factor)
    }
  }
}
public struct FoodItemSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let id: String, name: String, quantity: Double, unit: String, preparation: String,
    source: String, versionID: String?, confidence: String?, nutrients: FoodNutrients
  public init(
    id: String = UUID().uuidString, name: String, quantity: Double, unit: String,
    preparation: String = "未指定", source: String, versionID: String? = nil,
    confidence: String? = nil, nutrients: FoodNutrients
  ) throws {
    self.id = id
    self.name = name
    self.quantity = quantity
    self.unit = unit
    self.preparation = preparation
    self.source = source
    self.versionID = versionID
    self.confidence = confidence
    self.nutrients = nutrients
    try validate()
  }
  public func validate() throws {
    try FoodRules.id(id)
    for s in [name, unit, preparation, source] { try FoodRules.text(s) }
    guard FoodRules.sources.contains(source) else { throw FoodFailure.invalidValue }
    try FoodRules.quantity(quantity)
    try nutrients.validate()
    if let versionID { try FoodRules.id(versionID) }
    if let confidence {
      guard ["高", "中", "低"].contains(confidence) else { throw FoodFailure.invalidValue }
    }
  }
  public func scaled(_ factor: Double) throws -> Self {
    try .init(
      id: id, name: name, quantity: quantity * factor, unit: unit, preparation: preparation,
      source: source, versionID: versionID, confidence: confidence,
      nutrients: nutrients.scaled(factor))
  }
}
public struct FoodCatalog: Codable, Equatable, Sendable {
  public private(set) var versions: [FoodVersion], categories: [FoodCategory], presets: [FoodPreset]
  public init(
    versions: [FoodVersion] = [], categories: [FoodCategory] = [], presets: [FoodPreset] = []
  ) throws {
    self.versions = versions
    self.categories = categories
    self.presets = presets
    try validate()
  }
  public func validate() throws {
    let versionIDs = Set(versions.map(\.id)), categoryIDs = Set(categories.map(\.id))
    guard versionIDs.count == versions.count,
      categoryIDs.count == categories.count,
      Set(presets.map(\.id)).count == presets.count
    else { throw FoodFailure.duplicateID }
    for v in versions { try v.validate() }
    for c in categories {
      try FoodRules.id(c.id)
      try FoodRules.text(c.name)
    }
    for p in presets {
      try p.validate()
      guard p.categoryID.map({ categoryIDs.contains($0) }) ?? true,
        p.components.allSatisfy({ versionIDs.contains($0.versionID) })
      else { throw FoodFailure.missingReference }
    }
    guard Set(versions.map { "\($0.foodID)#\($0.revision)" }).count == versions.count else {
      throw FoodFailure.duplicateID
    }
  }
  public mutating func add(_ version: FoodVersion) throws {
    try version.validate()
    if let old = versions.first(where: { $0.id == version.id }) {
      guard old == version else { throw FoodFailure.duplicateID }
      return
    }
    var copy = self
    copy.versions.append(version)
    try copy.validate()
    self = copy
  }
  public mutating func save(_ category: FoodCategory) throws {
    var copy = self
    copy.categories.removeAll { $0.id == category.id }
    copy.categories.append(category)
    try copy.validate()
    self = copy
  }
  public mutating func save(_ preset: FoodPreset) throws {
    if let old = presets.first(where: { $0.id == preset.id }) {
      if old == preset { return }
      guard preset.revision == old.revision + 1 else { throw FoodFailure.revisionConflict }
    } else {
      guard preset.revision == 1 else { throw FoodFailure.revisionConflict }
    }
    var copy = self
    copy.presets.removeAll { $0.id == preset.id }
    copy.presets.append(preset)
    try copy.validate()
    self = copy
  }
  public func visiblePresets(query: String = "", categoryID: String? = nil) -> [FoodPreset] {
    presets.filter { p in
      !p.archived && (categoryID == nil || p.categoryID == categoryID)
        && !(p.categoryID.flatMap { id in categories.first { $0.id == id } }?.archived ?? false)
        && (query.isEmpty || p.name.localizedStandardContains(query))
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  public func snapshot(_ presetID: String) throws -> [FoodItemSnapshot] {
    guard let p = presets.first(where: { $0.id == presetID && !$0.archived }) else {
      throw FoodFailure.missingReference
    }
    return try p.components.map { c in
      guard let v = versions.first(where: { $0.id == c.versionID }) else {
        throw FoodFailure.missingReference
      }
      return try .init(
        name: v.name, quantity: v.quantity * c.factor, unit: v.unit, preparation: v.preparation,
        source: v.source, versionID: v.id, nutrients: v.nutrients.scaled(c.factor))
    }
  }
}
public struct FoodMeal: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public private(set) var revision: Int, date: String, slot: String, items: [FoodItemSnapshot],
    removed: Bool
  public let presetID: String?, presetRevision: Int?
  public init(
    id: String = UUID().uuidString, revision: Int = 1, date: String, slot: String,
    items: [FoodItemSnapshot], removed: Bool = false, presetID: String? = nil,
    presetRevision: Int? = nil
  ) throws {
    self.id = id
    self.revision = revision
    self.date = date
    self.slot = slot
    self.items = items
    self.removed = removed
    self.presetID = presetID
    self.presetRevision = presetRevision
    try validate()
  }
  public func validate() throws {
    try FoodRules.id(id)
    try FoodRules.date(date)
    guard revision > 0, FoodRules.slots.contains(slot), !items.isEmpty, items.count <= 50,
      Set(items.map(\.id)).count == items.count,items.allSatisfy({$0.id != id})
    else { throw FoodFailure.invalidValue }
    for i in items { try i.validate() }
    guard (presetID == nil) == (presetRevision == nil) else { throw FoodFailure.invalidValue }
    if let presetID, let presetRevision {
      try FoodRules.id(presetID)
      guard presetRevision > 0 else { throw FoodFailure.invalidValue }
    }
  }
  public func edited(
    factor: Double = 1, date: String? = nil, slot: String? = nil, remove: Bool = false
  ) throws -> Self {
    try .init(
      id: id, revision: revision + 1, date: date ?? self.date, slot: slot ?? self.slot,
      items: items.map { try $0.scaled(factor) }, removed: remove, presetID: presetID,
      presetRevision: presetRevision)
  }
}
public struct FoodTotal: Equatable, Sendable {
  public let known: [FoodNutrient: Double], missing: [FoodNutrient: Int]
  init(known: [FoodNutrient: Double], missing: [FoodNutrient: Int]) {
    self.known = known; self.missing = missing
  }
  public init(items: [FoodItemSnapshot]) {
    var sums: [FoodNutrient: Double] = [:]
    var unknown: [FoodNutrient: Int] = [:]
    for k in FoodNutrient.allCases {
      sums[k] = items.compactMap { $0.nutrients[k] }.reduce(0, +)
      unknown[k] = items.filter { $0.nutrients[k] == nil }.count
    }
    known = sums
    missing = unknown
  }
  public static func day(_ date: String, meals: [FoodMeal]) -> Self {
    .init(items: meals.filter { !$0.removed && $0.date == date }.flatMap(\.items))
  }
}
public struct FoodDraft: Codable, Equatable, Sendable {
  public var items: [FoodItemSnapshot], uncertainty: [String], questions: [String],
    answers: [String: String]
  public init(
    items: [FoodItemSnapshot], uncertainty: [String] = [], questions: [String] = [],
    answers: [String: String] = [:]
  ) {
    self.items = items
    self.uncertainty = uncertainty
    self.questions = questions
    self.answers = answers
  }
  public func confirm(date: String, slot: String, id: String = UUID().uuidString) throws -> FoodMeal {
    guard
      questions.allSatisfy({
        !(answers[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      })
    else { throw FoodFailure.unresolvedQuestions }
    return try .init(id: id, date: date, slot: slot, items: items)
  }
}
