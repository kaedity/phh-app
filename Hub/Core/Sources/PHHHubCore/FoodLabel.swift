import Foundation

/// 商品表示の栄養値が対応する量です。括弧内の重量も単位に残し、1食と100gを混ぜません。
public struct FoodLabelBasis: Equatable, Sendable {
  public let quantity: Double
  public let unit: String
  public let displayText: String

  public init(quantity: Double, unit: String, displayText: String) {
    self.quantity = quantity
    self.unit = unit
    self.displayText = displayText
  }
}

/// 端末内OCRの確認前の候補です。カタログや食事へは自動で保存しません。
public struct FoodLabelReading: Equatable, Sendable {
  public let text: String
  public let basis: FoodLabelBasis?
  public let nutrients: FoodNutrients
  public let warnings: [String]
}

public enum FoodLabelFailure: String, Error, LocalizedError {
  case confirmationRequired, missingName, missingBasis, invalidNumber
  public var errorDescription: String? {
    switch self {
    case .confirmationRequired: "表示基準量と栄養値を確認してから登録してください。"
    case .missingName: "食品名を入力してください。"
    case .missingBasis: "表示に対応する基準量と単位を入力してください。"
    case .invalidNumber: "数字は0以上で入力してください。不明な栄養値は空欄にしてください。"
    }
  }
}

/// OCRの候補を本人が編集する入力。空欄は不明であり、数値0は既知の0です。
public struct FoodLabelEntry: Equatable, Sendable {
  public var name: String
  public var quantity: String
  public var unit: String
  public var kcal: String
  public var protein: String
  public var fat: String
  public var carbohydrate: String

  public init(reading: FoodLabelReading) {
    name = ""
    quantity = reading.basis.map { FoodLabelParser.numberText($0.quantity) } ?? ""
    unit = reading.basis?.unit ?? ""
    kcal = reading.nutrients.kcal.map(FoodLabelParser.numberText) ?? ""
    protein = reading.nutrients.protein.map(FoodLabelParser.numberText) ?? ""
    fat = reading.nutrients.fat.map(FoodLabelParser.numberText) ?? ""
    carbohydrate = reading.nutrients.carbohydrate.map(FoodLabelParser.numberText) ?? ""
  }

  public func validate() throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FoodLabelFailure.missingName
    }
    try FoodRules.text(name)
    _ = try values()
  }

  /// 明示確認を受けた時だけ、新しい食品版とそれを参照する単品プリセットを作ります。
  public func registration(confirmed: Bool, categoryID: String? = nil) throws
    -> FoodLabelRegistration
  {
    guard confirmed else { throw FoodLabelFailure.confirmationRequired }
    try validate()
    let values = try values()
    let version = try FoodVersion(
      name: name.trimmingCharacters(in: .whitespacesAndNewlines), quantity: values.quantity,
      unit: unit.trimmingCharacters(in: .whitespacesAndNewlines), source: "商品表示",
      nutrients: values.nutrients)
    let preset = try FoodPreset(
      name: version.name, categoryID: categoryID, components: [.init(versionID: version.id)])
    return FoodLabelRegistration(version: version, preset: preset)
  }

  private func values() throws -> (quantity: Double, nutrients: FoodNutrients) {
    guard let amount = try FoodLabelParser.inputNumber(quantity), amount > 0,
      !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw FoodLabelFailure.missingBasis }
    try FoodRules.quantity(amount)
    try FoodRules.text(unit)
    return (
      amount,
      try FoodNutrients(
        kcal: FoodLabelParser.inputNumber(kcal), protein: FoodLabelParser.inputNumber(protein),
        fat: FoodLabelParser.inputNumber(fat),
        carbohydrate: FoodLabelParser.inputNumber(carbohydrate)))
  }
}

public struct FoodLabelRegistration: Equatable, Sendable {
  public let version: FoodVersion
  public let preset: FoodPreset

  /// 既存の不変版と過去の食事を変更せず、既存の一括カタログ保存経路へ渡せます。
  public func adding(to catalog: FoodCatalog) throws -> FoodCatalog {
    var next = catalog
    try next.add(version)
    try next.save(preset)
    return next
  }
}

public enum FoodLabelParser {
  private static let numberPattern = #"(?:[0-9]{1,3}(?:,[0-9]{3})+|[0-9]+)(?:\.[0-9]+)?"#
  private static let amountPattern = #"(?<![0-9A-Za-z.,+\-])("# + numberPattern + #")\s*(g|ml|kg|l|グラム|食|袋|本|個|枚|杯|粒|包|パック|カップ)(?:分)?(\s*\([^\n)]*\))?"#
  private static let nutrientPattern =
    #"エネルギー|熱量|カロリー|たんぱく質|タンパク質|蛋白質|たん白質|脂質|炭水化物|\b(?:total\s+carbohydrates?|carbohydrates?|protein|total\s+fat|fat|energy|calories?|sodium|salt|dietary\s+fiber|sugars?)\b|食塩相当量|ナトリウム|食物繊維|糖質|糖類|飽和脂肪酸|ビタミン[^\s:：]*|内容量|原材料"#

  public static func read(_ sourceText: String) -> FoodLabelReading {
    let empty = try! FoodNutrients(kcal: nil, protein: nil, fat: nil, carbohydrate: nil)
    guard sourceText.count <= 20_000 else {
      return .init(
        text: String(sourceText.prefix(20_000)), basis: nil, nutrients: empty,
        warnings: ["読み取った文字が多すぎます。成分表示だけを撮り直してください。"])
    }
    let text = normalized(sourceText)
    var warnings: [String] = []
    let bases = basisCandidates(text)
    let basis: FoodLabelBasis? = bases.count == 1 ? bases[0] : nil
    if bases.isEmpty {
      warnings.append("表示基準量を読み取れませんでした。100g当たり・1食当たりなど、表示の量と単位を入力してください。")
    } else if bases.count > 1 {
      warnings.append("表示基準量が複数あります。使う列を確認し、その基準量と栄養値を入力してください。")
      // 複数列・複数表の数値を異なる基準量へ結び付けないよう、候補を採用しません。
      return .init(text: sourceText, basis: nil, nutrients: empty, warnings: warnings)
    }

    let labels = matches(nutrientPattern, text)
    var candidates: [FoodNutrient: [Double?]] = [:]
    for (index, match) in labels.enumerated() {
      let label = substring(text, match.range).lowercased()
      guard let key = nutrientKey(label) else { continue }
      let start = NSMaxRange(match.range)
      let end = index + 1 < labels.count ? labels[index + 1].range.location : (text as NSString).length
      let valueText = (text as NSString).substring(with: NSRange(location: start, length: end - start))
      candidates[key, default: []].append(nutrientValue(valueText, key: key))
    }
    var values: [FoodNutrient: Double] = [:]
    for key in FoodNutrient.allCases {
      let found = candidates[key] ?? []
      if found.count == 1, let value = found[0] { values[key] = value }
      else if found.count > 1 {
        warnings.append("\(label(key))の表示が複数あります。使う値を確認して入力してください。")
      } else {
        warnings.append("\(label(key))を読み取れませんでした。不明なら空欄のままにしてください。")
      }
    }
    let nutrients = try! FoodNutrients(
      kcal: values[.kcal], protein: values[.protein], fat: values[.fat],
      carbohydrate: values[.carbohydrate])
    return .init(text: sourceText, basis: basis, nutrients: nutrients, warnings: warnings)
  }

  /// 全角数字を正規化します。推測によるO→0/I→1などの訂正は行いません。
  public static func inputNumber(_ text: String) throws -> Double? {
    let value = normalized(text).trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return nil }
    guard !matches("^" + numberPattern + "$", value).isEmpty,
      let result = Double(value.replacingOccurrences(of: ",", with: "")), result.isFinite,
      result >= 0
    else { throw FoodLabelFailure.invalidNumber }
    return result
  }

  public static func numberText(_ value: Double) -> String {
    value.rounded() == value ? String(format: "%.0f", value) : String(value)
  }

  private static func normalized(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "−", with: "-")
  }

  private static func basisCandidates(_ text: String) -> [FoodLabelBasis] {
    var result: [FoodLabelBasis] = []
    let japanese = amountPattern + #"\s*\)?\s*(?:当たり|あたり|当り|につき)"#
    for match in matches(japanese, text) {
      if let basis = basis(match, text) { result.append(basis) }
    }
    // 栄養成分表示(100g)、Nutrition Facts / Serving size 30 g などの明示された基準。
    for line in text.components(separatedBy: .newlines) {
      let header = #"(?:栄養成分(?:表示)?|nutrition\s+facts?|serving\s+size)\s*[:：]?\s*\(?\s*"#
      for match in matches(header + amountPattern, line) {
        if matches(japanese, line).isEmpty, let basis = basis(match, line, offset: 0) {
          result.append(basis)
        }
      }
    }
    for match in matches(#"\bper\s+"# + amountPattern, text) {
      if let basis = basis(match, text) { result.append(basis) }
    }
    for match in matches(#"\bper\s+(serving|pack|piece|bottle|cup)(\s*\([^\n)]*\))?"#, text) {
      let unit = substring(text, match.range(at: 1)) + substring(text, match.range(at: 2))
      result.append(.init(quantity: 1, unit: unit, displayText: substring(text, match.range)))
    }
    // 同じ基準の繰返しは許容します。1食と100gは値が等しくても別の基準です。
    var unique: [FoodLabelBasis] = []
    for candidate in result where !unique.contains(where: {
      $0.quantity == candidate.quantity && $0.unit == candidate.unit
    }) { unique.append(candidate) }
    return unique
  }

  private static func basis(_ match: NSTextCheckingResult, _ text: String, offset: Int = 0)
    -> FoodLabelBasis?
  {
    guard let quantity = try? inputNumber(substring(text, match.range(at: 1 + offset))),
      quantity.isFinite, quantity > 0, quantity <= 1_000_000
    else { return nil }
    let unit = substring(text, match.range(at: 2 + offset)).lowercased()
    let detail = substring(text, match.range(at: 3 + offset)).trimmingCharacters(in: .whitespaces)
    return .init(
      quantity: quantity, unit: unit + detail, displayText: substring(text, match.range))
  }

  private static func nutrientValue(_ text: String, key: FoodNutrient) -> Double? {
    let unit = key == .kcal ? "kcal" : "(?:g|mg|グラム)"
    let pattern = #"^\s*[:：]?\s*(?:約\s*)?("# + numberPattern + #")\s*("# + unit + #")(?![a-z])"#
    guard let match = matches(pattern, text).first,
      let value = try? inputNumber(substring(text, match.range(at: 1)))
    else { return nil }
    // 1つの行に複数の値や、範囲/未満/以上があれば採用しません。
    let after = (text as NSString).substring(from: NSMaxRange(match.range))
    let firstLine = after.components(separatedBy: .newlines).first ?? ""
    guard matches(numberPattern + #"\s*("# + unit + #")(?![a-z])"#, after).isEmpty else { return nil }
    guard matches(#"[0-9]|未満|以下|以上|超|[<>~〜–-]"#, firstLine).isEmpty else {
      // kcalの後の換算kJだけは公式表示のkcalをそのまま保持します。
      guard key == .kcal,
        !matches(#"^\s*\(\s*"# + numberPattern + #"\s*kj\s*\)\s*$"#, firstLine).isEmpty
      else { return nil }
      return value <= 100_000 ? value : nil
    }
    let parsedUnit = substring(text, match.range(at: 2)).lowercased()
    let grams = parsedUnit == "mg" ? value / 1000 : value
    return grams <= 100_000 ? grams : nil
  }

  private static func nutrientKey(_ label: String) -> FoodNutrient? {
    if ["エネルギー", "熱量", "カロリー", "energy", "calorie", "calories"].contains(label) { return .kcal }
    if ["たんぱく質", "タンパク質", "蛋白質", "たん白質", "protein"].contains(label) { return .protein }
    if label == "脂質" || label == "fat" || label.hasPrefix("total") && label.hasSuffix("fat") { return .fat }
    if label == "炭水化物" || label.contains("carbohydrate") { return .carbohydrate }
    return nil
  }

  private static func label(_ key: FoodNutrient) -> String {
    switch key {
    case .kcal: "kcal"
    case .protein: "たんぱく質(P)"
    case .fat: "脂質(F)"
    case .carbohydrate: "炭水化物(C)"
    }
  }

  private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
  }

  private static func substring(_ text: String, _ range: NSRange) -> String {
    guard range.location != NSNotFound else { return "" }
    return (text as NSString).substring(with: range)
  }
}
