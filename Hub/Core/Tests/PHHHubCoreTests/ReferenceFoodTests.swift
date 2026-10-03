import Foundation
import Testing
@testable import PHHHubCore

struct ReferenceFoodTests {
  private func sourceDatabase() throws -> ReferenceFoodDatabase {
    let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
    let data = try Data(contentsOf: core.appendingPathComponent("Sources/PHHHubCore/Resources/mext-foods.json"))
    return try ReferenceFoodDatabase.decode(data)
  }

  @Test func rawTraceMissingAndEstimatedValuesKeepTheirMeaning() throws {
    let zero = try ReferenceFoodValue(raw: "0")
    #expect(zero.kind == .numeric); #expect(zero.value == 0)
    let trace = try ReferenceFoodValue(raw: "Tr")
    #expect(trace.kind == .trace); #expect(trace.value == nil)
    let estimatedTrace = try ReferenceFoodValue(raw: "(Tr)")
    #expect(estimatedTrace.kind == .estimatedTrace); #expect(estimatedTrace.value == nil)
    let unknown = try ReferenceFoodValue(raw: "-")
    #expect(unknown.kind == .missing); #expect(unknown.value == nil)
    #expect(try ReferenceFoodValue(raw: "").value == nil)
    let estimate = try ReferenceFoodValue(raw: "(2.5)")
    #expect(estimate.kind == .estimated); #expect(estimate.value == 2.5)
    let estimatedZero = try ReferenceFoodValue(raw: "(0)")
    #expect(estimatedZero.kind == .estimated); #expect(estimatedZero.value == 0)
  }

  @Test func unsupportedRawValuesFailInsteadOfFallingBackToZero() throws {
    for raw in ["<0.1", "*", "unknown", "NaN", "-1", "(1〜2)", "100001"] {
      #expect(throws: ReferenceFoodFailure.invalidData) { try ReferenceFoodValue(raw: raw) }
    }
  }

  @Test func officialResourceContainsAllFoodsCorrectColumnsAndAttribution() throws {
    let database = try sourceDatabase()
    #expect(database.foods.count == 2538)
    #expect(database.expectedCount == 2538)
    #expect(database.groups.count == 18)
    #expect(database.revisionDate == "2026-03-27")
    #expect(database.basisQuantity == 100); #expect(database.basisUnit == "g")
    #expect(database.sourceSHA256 == "0d5a77077dd6cd91cbc2e6e317b8b218a38728c409eed452f1c10635a0d3099c")
    #expect(database.attribution == "日本食品標準成分表（八訂）増補2023年から引用")
    #expect(database.columns["kcal"] == "G:ENERC_KCAL")
    #expect(database.columns["protein"] == "J:PROT-")
    #expect(database.columns["fat"] == "M:FAT-")
    #expect(database.columns["carbohydrate"] == "U:CHOCDF-")
    let banana = try #require(database.foods.first { $0.code == "07107" })
    #expect(banana.name == "バナナ　生")
    #expect(banana.nutrients.kcal == 93)
    #expect(banana.nutrients.protein == 1.1)
    #expect(banana.nutrients.fat == 0.2)
    #expect(banana.nutrients.carbohydrate == 22.5)
    let egg = try #require(database.foods.first { $0.code == "12005" })
    #expect(egg.name == "鶏卵　全卵　ゆで")
    #expect(egg.nutrients.kcal == 134)
    #expect(egg.nutrients.protein == 12.5)
  }

  @Test func officialSpecialValuesRemainTraceMissingOrEstimated() throws {
    let database = try sourceDatabase()
    let cells = database.foods.flatMap { food in FoodNutrient.allCases.map { food.cell($0) } }
    #expect(cells.filter { $0.kind == .trace || $0.kind == .estimatedTrace }.count == 179)
    #expect(cells.filter { $0.kind == .missing }.count == 2)
    #expect(cells.filter { $0.kind == .estimated }.count == 846)
    #expect(cells.filter { $0.kind == .trace || $0.kind == .estimatedTrace || $0.kind == .missing }
      .allSatisfy { $0.value == nil })
    #expect(cells.contains { $0.kind == .estimated && ($0.value ?? 0) > 0 })
  }

  @Test func searchUsesKanaWidthCodeAndGroupWithoutReturningAnUnboundedList() throws {
    let database = try sourceDatabase()
    #expect(database.search(query: "ばなな").foods.map(\.code) == ["07107", "07108"])
    #expect(database.search(query: "ﾊﾞﾅﾅ").foods.map(\.code) == ["07107", "07108"])
    #expect(database.search(query: "０７１０７").foods.map(\.code) == ["07107"])
    #expect(database.search(query: "バナナ", groupCode: "11").total == 0)
    let all = database.search(limit: 30)
    #expect(all.foods.count == 30); #expect(all.total == 2538); #expect(all.omitted == 2508)
  }

  @Test func confirmationCreatesImmutable100GramVersionAndScalesPresetOnly() throws {
    let food = try ReferenceFood(
      code: "01001", groupCode: "01", group: "架空群", name: "架空食品　ゆで",
      kcal: "100", protein: "(5.0)", fat: "0", carbohydrate: "Tr")
    #expect(throws: ReferenceFoodFailure.confirmationRequired) { try food.registration(confirmed: false) }
    let registration = try food.registration(confirmed: true, presetName: "架空の定番", defaultQuantity: 150)
    let catalog = try registration.adding(to: FoodCatalog())
    #expect(registration.version.quantity == 100)
    #expect(registration.version.unit == "g")
    #expect(registration.version.source == "成分表")
    #expect(registration.version.name == "架空食品　ゆで")
    #expect(registration.version.nutrients.protein == 5)
    #expect(registration.version.nutrients.fat == 0)
    #expect(registration.version.nutrients.carbohydrate == nil)
    let snapshot = try #require(catalog.snapshot(registration.preset.id).first)
    #expect(snapshot.quantity == 150)
    #expect(snapshot.nutrients.kcal == 150)
    #expect(snapshot.nutrients.protein == 7.5)
    #expect(snapshot.nutrients.fat == 0)
    #expect(snapshot.nutrients.carbohydrate == nil)
    let meal = try FoodMeal(date: "2026-10-03", slot: "昼食", items: [snapshot])
    let again = try food.registration(confirmed: true)
    let revised = try again.adding(to: catalog)
    #expect(revised.versions.count == 2)
    #expect(registration.version.id != again.version.id)
    #expect(meal.items.first?.nutrients.kcal == 150)
  }

  @Test func invalidBasisCountAndNutrientColumnsRejectTamperedResources() throws {
    let database = try sourceDatabase()
    let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(database)) as! [String: Any]
    for (key, value) in [("basisQuantity", 1), ("expectedCount", 2537)] {
      var changed = original; changed[key] = value
      #expect(throws: ReferenceFoodFailure.invalidData) {
        try ReferenceFoodDatabase.decode(JSONSerialization.data(withJSONObject: changed))
      }
    }
    var wrongColumns = original
    var columns = database.columns; columns["kcal"] = "F:ENERC"
    wrongColumns["columns"] = columns
    #expect(throws: ReferenceFoodFailure.invalidData) {
      try ReferenceFoodDatabase.decode(JSONSerialization.data(withJSONObject: wrongColumns))
    }
  }
}
