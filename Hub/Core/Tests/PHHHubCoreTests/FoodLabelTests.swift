import Foundation
import Testing
@testable import PHHHubCore

struct FoodLabelTests {
  private let serving = """
    架空バー
    栄養成分表示 1食(35g)当たり
    エネルギー 150kcal
    たんぱく質 10.5g
    脂質 0g
    炭水化物 25.0g
    食塩相当量 0.3g
    """

  @Test func servingBasisKeepsItsWeightAnnotationAndKnownZero() {
    let result = FoodLabelParser.read(serving)
    #expect(result.basis?.quantity == 1)
    #expect(result.basis?.unit == "食(35g)")
    #expect(result.nutrients.kcal == 150)
    #expect(result.nutrients.protein == 10.5)
    #expect(result.nutrients.fat == 0)
    #expect(result.nutrients.carbohydrate == 25)
    #expect(result.warnings.isEmpty)
  }

  @Test func fullWidthAndSplitRowsUseTheExplicit100GramBasis() {
    let result = FoodLabelParser.read("""
      内容量 １袋２００ｇ
      栄養成分表示（１００ｇ当たり）
      熱量
      ２４０ｋｃａｌ
      タンパク質　１２．５ｇ
      脂質
      ０ｇ
      炭水化物　４０ｇ
      """)
    #expect(result.basis?.quantity == 100)
    #expect(result.basis?.unit == "g")
    #expect(result.nutrients.kcal == 240)
    #expect(result.nutrients.protein == 12.5)
    #expect(result.nutrients.fat == 0)
    #expect(result.nutrients.carbohydrate == 40)
  }

  @Test func missingValuesDoNotBorrowSaltFiberOrPackageQuantity() {
    let result = FoodLabelParser.read("""
      内容量 200g
      熱量 80kcal
      たんぱく質 不明
      脂質 0g
      炭水化物 —
      食物繊維 3g
      食塩相当量 0.5g
      """)
    #expect(result.basis == nil)
    #expect(result.nutrients.kcal == 80)
    #expect(result.nutrients.protein == nil)
    #expect(result.nutrients.fat == 0)
    #expect(result.nutrients.carbohydrate == nil)
    #expect(result.warnings.count == 3)
  }

  @Test func multipleBasesClearNutrientsInsteadOfCombiningColumns() {
    let result = FoodLabelParser.read("""
      栄養成分表示
      100g当たり 1食(50g)当たり
      エネルギー 200kcal 100kcal
      たんぱく質 20g 10g
      脂質 0g 0g
      炭水化物 30g 15g
      """)
    #expect(result.basis == nil)
    #expect(FoodNutrient.allCases.allSatisfy { result.nutrients[$0] == nil })
    #expect(result.warnings.contains { $0.contains("複数") })
  }

  @Test func rangesInequalitiesAndRepeatedRowsRemainUnknown() {
    let result = FoodLabelParser.read("""
      1袋あたり
      熱量 100kcal 120kcal
      たんぱく質 0.5g未満
      脂質 0〜1g
      炭水化物 10g
      炭水化物 10g
      """)
    #expect(result.basis?.unit == "袋")
    #expect(FoodNutrient.allCases.allSatisfy { result.nutrients[$0] == nil })
  }

  @Test func englishHeadersAndKilojoulesKeepThePrintedKcal() {
    let result = FoodLabelParser.read("""
      Nutrition Facts
      Per 100 g
      Energy 180 kcal (753 kJ)
      Protein 8 g
      Total Fat 0 g
      Total Carbohydrate 30 g
      Sodium 200 mg
      """)
    #expect(result.basis?.quantity == 100)
    #expect(result.nutrients.kcal == 180)
    #expect(result.nutrients.protein == 8)
    #expect(result.nutrients.fat == 0)
    #expect(result.nutrients.carbohydrate == 30)
    #expect(FoodLabelParser.read("1食あたり\n熱量 753kJ").nutrients.kcal == nil)
  }

  @Test func incompleteNumbersAndMissingUnitsAreNotGuessed() {
    let result = FoodLabelParser.read("""
      100g当たり
      熱量 I00kcal
      たんぱく質 2,5g
      脂質 -1g
      炭水化物 25
      """)
    #expect(FoodNutrient.allCases.allSatisfy { result.nutrients[$0] == nil })
    #expect(FoodLabelParser.read("100g当たり\n熱量 100001kcal").nutrients.kcal == nil)
    #expect(FoodLabelParser.read("-100g当たり\n熱量 100kcal").basis == nil)
    #expect(FoodLabelParser.read("I100g当たり\n熱量 100kcal").basis == nil)
    #expect(FoodLabelParser.read("1,100g当たり\n熱量 100kcal").basis?.quantity == 1100)
    #expect(FoodLabelParser.read("100g当たり\n熱量 100kcal\n200kcal").nutrients.kcal == nil)
  }

  @Test func registrationRequiresConfirmationAndExplicitBasis() throws {
    var entry = FoodLabelEntry(reading: FoodLabelParser.read("熱量 100kcal\n脂質 0g"))
    entry.name = "架空ラベル"
    #expect(throws: FoodLabelFailure.confirmationRequired) { try entry.registration(confirmed: false) }
    #expect(throws: FoodLabelFailure.missingBasis) { try entry.registration(confirmed: true) }
    entry.quantity = "１００"
    entry.unit = "g"
    let saved = try entry.registration(confirmed: true)
    #expect(saved.version.quantity == 100)
    #expect(saved.version.nutrients.kcal == 100)
    #expect(saved.version.nutrients.protein == nil)
    #expect(saved.version.nutrients.fat == 0)
    #expect(saved.version.source == "商品表示")
    #expect(saved.preset.components.first?.versionID == saved.version.id)
    #expect(saved.preset.components.first?.factor == 1)
  }

  @Test func editedInputsAndCatalogAdditionPreservePriorMealSnapshots() throws {
    var entry = FoodLabelEntry(reading: FoodLabelParser.read(serving))
    entry.name = "架空バー"
    let first = try entry.registration(confirmed: true)
    let initial = try first.adding(to: FoodCatalog())
    let meal = try FoodMeal(date: "2026-10-03", slot: "間食", items: initial.snapshot(first.preset.id))
    entry.kcal = "160"
    entry.carbohydrate = ""
    let second = try entry.registration(confirmed: true)
    let catalog = try second.adding(to: initial)
    #expect(catalog.versions.count == 2)
    #expect(catalog.presets.count == 2)
    #expect(first.version.id != second.version.id)
    #expect(meal.items.first?.quantity == 1)
    #expect(meal.items.first?.unit == "食(35g)")
    #expect(meal.items.first?.nutrients.kcal == 150)
    #expect(second.version.nutrients.kcal == 160)
    #expect(second.version.nutrients.carbohydrate == nil)
  }

  @Test func malformedManualValuesFailRatherThanTurnIntoUnknownOrZero() throws {
    var entry = FoodLabelEntry(reading: FoodLabelParser.read(serving))
    entry.name = "架空バー"
    entry.protein = "不明"
    #expect(throws: FoodLabelFailure.invalidNumber) { try entry.registration(confirmed: true) }
    entry.protein = ""
    entry.quantity = "0"
    #expect(throws: FoodLabelFailure.missingBasis) { try entry.registration(confirmed: true) }
    #expect(try FoodLabelParser.inputNumber(" ０ ") == 0)
    #expect(try FoodLabelParser.inputNumber(" ") == nil)
    #expect(try FoodLabelParser.inputNumber("1,000") == 1000)
    #expect(throws: FoodLabelFailure.invalidNumber) { try FoodLabelParser.inputNumber("NaN") }
  }
}
