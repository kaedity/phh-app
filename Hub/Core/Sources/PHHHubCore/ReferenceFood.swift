import Foundation

public enum ReferenceFoodFailure: String, Error, LocalizedError {
  case unavailable, invalidData, confirmationRequired
  public var errorDescription: String? {
    switch self {
    case .unavailable: "食品成分表を読み込めませんでした。"
    case .invalidData: "食品成分表の版・基準量・値を確認できませんでした。"
    case .confirmationRequired: "食品名・調理状態・基準量・成分値を確認してから登録してください。"
    }
  }
}

/// 文科省の原表記を保持します。微量・欠測と数値0を区別します。
public struct ReferenceFoodValue: Equatable, Sendable {
  public enum Kind: String, Equatable, Sendable {
    case numeric, estimated, trace, estimatedTrace, missing
  }
  public let raw: String
  public let kind: Kind
  public let value: Double?

  public init(raw: String) throws {
    self.raw = raw
    let text = raw.precomposedStringWithCompatibilityMapping
      .trimmingCharacters(in: .whitespacesAndNewlines)
    switch text.lowercased() {
    case "", "-", "—": kind = .missing; value = nil
    case "tr": kind = .trace; value = nil
    case "(tr)": kind = .estimatedTrace; value = nil
    default:
      let estimated = text.hasPrefix("(") && text.hasSuffix(")")
      let number = estimated ? String(text.dropFirst().dropLast()) : text
      guard number.range(of: #"^\d+(?:\.\d+)?$"#, options: .regularExpression) != nil,
        let parsed = Double(number), parsed.isFinite, parsed >= 0, parsed <= 100_000
      else { throw ReferenceFoodFailure.invalidData }
      kind = estimated ? .estimated : .numeric
      value = parsed
    }
  }

  public var explanation: String {
    switch kind {
    case .numeric: "成分表の値"
    case .estimated: "括弧付きの推定値"
    case .trace: "微量（Tr）・数値は不明"
    case .estimatedTrace: "推定の微量（Tr）・数値は不明"
    case .missing: "未測定・不明"
    }
  }
}

public struct ReferenceFood: Codable, Equatable, Identifiable, Sendable {
  public var id: String { code }
  public let code: String, groupCode: String, group: String, name: String, note: String
  public let kcal: String, protein: String, fat: String, carbohydrate: String
  private let searchKey: String
  private let commonNameKeys: [String]
  // 原表の名称・数値は保ち、食品番号が確定している通称だけ検索へ追加します。
  private static let commonNames = [
    "12005": ["ゆで卵", "ゆでたまご", "茹で卵", "ゆで玉子", "茹で玉子"]
  ]
  private enum CodingKeys: String, CodingKey {
    case code, groupCode, group, name, note, kcal, protein, fat, carbohydrate
  }

  public init(
    code: String, groupCode: String, group: String, name: String, note: String = "",
    kcal: String, protein: String, fat: String, carbohydrate: String
  ) throws {
    self.code = code; self.groupCode = groupCode; self.group = group; self.name = name
    self.note = note; self.kcal = kcal; self.protein = protein; self.fat = fat
    self.carbohydrate = carbohydrate
    searchKey = JapaneseSearch.normalized(name + " " + code)
    commonNameKeys = (Self.commonNames[code] ?? []).map(JapaneseSearch.normalized)
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      code: values.decode(String.self, forKey: .code),
      groupCode: values.decode(String.self, forKey: .groupCode),
      group: values.decode(String.self, forKey: .group), name: values.decode(String.self, forKey: .name),
      note: values.decode(String.self, forKey: .note), kcal: values.decode(String.self, forKey: .kcal),
      protein: values.decode(String.self, forKey: .protein), fat: values.decode(String.self, forKey: .fat),
      carbohydrate: values.decode(String.self, forKey: .carbohydrate))
  }

  public func validate() throws {
    guard code.range(of: #"^\d{5}$"#, options: .regularExpression) != nil,
      groupCode.range(of: #"^\d{2}$"#, options: .regularExpression) != nil,
      code.hasPrefix(groupCode)
    else { throw ReferenceFoodFailure.invalidData }
    try FoodRules.text(name)
    try FoodRules.text(group)
    for nutrient in FoodNutrient.allCases { _ = try ReferenceFoodValue(raw: raw(nutrient)) }
  }

  public func raw(_ key: FoodNutrient) -> String {
    switch key {
    case .kcal: kcal
    case .protein: protein
    case .fat: fat
    case .carbohydrate: carbohydrate
    }
  }

  public func cell(_ key: FoodNutrient) -> ReferenceFoodValue {
    // 生成とデコードで全ての原表記を検証済みです。
    try! ReferenceFoodValue(raw: raw(key))
  }

  public var nutrients: FoodNutrients {
    try! FoodNutrients(
      kcal: cell(.kcal).value, protein: cell(.protein).value, fat: cell(.fat).value,
      carbohydrate: cell(.carbohydrate).value)
  }

  fileprivate func matches(_ normalizedQuery: String) -> Bool {
    normalizedQuery.isEmpty || searchKey.contains(normalizedQuery)
      || commonNameKeys.contains { $0.contains(normalizedQuery) }
  }

  /// 100gの食品版を保存し、プリセットの既定量は倍率で表します。過去の版は書き換えません。
  public func registration(
    confirmed: Bool, presetName: String? = nil, defaultQuantity: Double = 100,
    categoryID: String? = nil
  ) throws -> ReferenceFoodRegistration {
    guard confirmed else { throw ReferenceFoodFailure.confirmationRequired }
    try validate()
    try FoodRules.quantity(defaultQuantity)
    let factor = defaultQuantity / 100
    _ = try nutrients.scaled(factor)
    let version = try FoodVersion(
      name: name, quantity: 100, unit: "g", preparation: "食品名の記載どおり", source: "成分表",
      nutrients: nutrients)
    let preset = try FoodPreset(
      name: presetName ?? name, categoryID: categoryID,
      components: [.init(versionID: version.id, factor: factor)])
    return .init(version: version, preset: preset)
  }
}

public struct ReferenceFoodRegistration: Equatable, Sendable {
  public let version: FoodVersion
  public let preset: FoodPreset
  public func adding(to catalog: FoodCatalog) throws -> FoodCatalog {
    var next = catalog
    try next.add(version)
    try next.save(preset)
    return next
  }
}

public struct ReferenceFoodSearchResult: Equatable, Sendable {
  public let foods: [ReferenceFood]
  public let total: Int
  public var omitted: Int { max(0, total - foods.count) }
}

public struct ReferenceFoodDatabase: Codable, Equatable, Sendable {
  public let schema: Int
  public let title: String, publisher: String, revisionDate: String, attribution: String
  public let sourcePage: String, downloadURL: String, licenseURL: String, guideURL: String
  public let sourceSHA256: String, worksheet: String
  public let columns: [String: String]
  public let basisQuantity: Double
  public let basisUnit: String
  public let expectedCount: Int
  public let foods: [ReferenceFood]

  public static func decode(_ data: Data) throws -> Self {
    let database = try JSONDecoder().decode(Self.self, from: data)
    try database.validate()
    return database
  }

  public static func bundled() throws -> Self {
    guard let url = Bundle.module.url(forResource: "mext-foods", withExtension: "json") else {
      throw ReferenceFoodFailure.unavailable
    }
    return try decode(Data(contentsOf: url))
  }

  public func validate() throws {
    let expectedColumns = [
      "code": "B:食品番号", "name": "D:食品名", "kcal": "G:ENERC_KCAL",
      "protein": "J:PROT-", "fat": "M:FAT-", "carbohydrate": "U:CHOCDF-",
    ]
    guard schema == 1, publisher == "文部科学省", !title.isEmpty, !attribution.isEmpty,
      basisQuantity == 100, basisUnit == "g", expectedCount == foods.count, expectedCount > 0,
      Set(foods.map(\.code)).count == foods.count, columns == expectedColumns,
      sourceSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
      worksheet == "表全体"
    else { throw ReferenceFoodFailure.invalidData }
    try FoodRules.date(revisionDate)
    for link in [sourcePage, downloadURL, licenseURL, guideURL] {
      guard let url = URL(string: link), url.scheme == "https", url.host == "www.mext.go.jp" else {
        throw ReferenceFoodFailure.invalidData
      }
    }
    for food in foods { try food.validate() }
  }

  public var groups: [(code: String, name: String)] {
    var names: [String: String] = [:]
    for food in foods { names[food.groupCode] = food.group }
    return names.keys.sorted().map { ($0, names[$0]!) }
  }

  public func search(query: String = "", groupCode: String? = nil, limit: Int = 100)
    -> ReferenceFoodSearchResult
  {
    let key = JapaneseSearch.normalized(query)
    let matches = foods.filter {
      (groupCode == nil || $0.groupCode == groupCode) && $0.matches(key)
    }
    return .init(foods: Array(matches.prefix(max(0, min(limit, 500)))), total: matches.count)
  }
}
