import Foundation
import CryptoKit
import Testing
@testable import PHHHubCore

@Suite @MainActor struct NightlyFoodSnapshotIndexTests {
    func syntheticMeals(_ count: Int) throws -> [LocalRow] {
        struct Row: Decodable { let table: String, record: [String: Cell] }
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<4 { root.deleteLastPathComponent() }
        let template = try JSONDecoder().decode([Row].self, from: Data(contentsOf: root.appending(path: "Server/food-p4-rows-fixture.json")))
          .filter { ["Meals", "MealItems", "IntakeNutrients"].contains($0.table) }
        var rows: [LocalRow] = []
        for meal in 0..<count {
            let ids = Dictionary(uniqueKeysWithValues: template.enumerated().map { number, row in (row.record["id"]!.text!, String(format: "00000000-0000-4000-a000-%012d", 400_000 + meal * 100 + number)) })
            rows += template.map { row in
                let values = row.record.mapValues { value -> Cell in
                    if let text = value.text, let replacement = ids[text] { return .string(replacement) }
                    return value
                }
                return LocalRow(table: row.table, values: values)
            }
        }
        return rows
    }
    @Test func multipleMealsKeepRootOrderAndRecordedItemValuesWithoutCrossContamination() throws {
        let rows = try syntheticMeals(3).reversed(), wire = try FoodWireTests().fixture()
        let meals = try FoodSnapshotReader.meals(Array(rows))
        #expect(meals.map(\.id) == rows.filter { $0.table == "Meals" }.map(\.entityID))
        for meal in meals {
            #expect(meal.items.map(\.name) == wire.payload.items.map(\.name))
            #expect(meal.items.map(\.nutrients) == wire.payload.items.map(\.nutrients))
            #expect(meal.items.map(\.versionID) == wire.payload.items.map(\.versionID))
        }
        #expect(Set(meals.flatMap { $0.items.map(\.id) }).count == meals.reduce(0) { $0 + $1.items.count })
    }
    @Test func distinctMealsKeepNutrientsAndReferenceVersionsAttachedToOwnParent() throws {
        var rows = try syntheticMeals(3)
        let roots = rows.filter { $0.table == "Meals" }
        var expected: [String: (kcal: Double, version: String, item: String)] = [:]
        for (index, root) in roots.enumerated() {
            let child = try #require(rows.firstIndex { $0.table == "MealItems" && $0.values["meal_id"]?.text == root.entityID && $0.values["number"]?.number == 1 })
            let itemID = rows[child].entityID, version = UUID().uuidString, kcal = Double(100 + index)
            rows[child].values["reference_version"] = .string(version)
            let nutrient = try #require(rows.firstIndex { $0.table == "IntakeNutrients" && $0.values["item_id"]?.text == itemID && $0.values["nutrient_id"]?.text == "kcal" })
            rows[nutrient].values["value"] = .number(kcal)
            expected[root.entityID] = (kcal, version, itemID)
        }
        let meals = try FoodSnapshotReader.meals(Array(rows.reversed()))
        for meal in meals {
            let value = try #require(expected[meal.id]), first = try #require(meal.items.first)
            #expect(first.id == value.item)
            #expect(first.versionID == value.version)
            #expect(first.nutrients.kcal == value.kcal)
        }
    }
    @Test func invalidCrossMealOrdinalAndOrphanNutrientRejectEntireSnapshot() throws {
        let rows = try syntheticMeals(2), roots = rows.filter { $0.table == "Meals" }
        var bad = rows
        let child = try #require(bad.firstIndex { $0.table == "MealItems" && $0.values["meal_id"]?.text == roots[1].entityID })
        bad[child].values["meal_id"] = .string(roots[0].entityID)
        #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(bad) }
        bad = rows
        let nutrient = try #require(bad.firstIndex { $0.table == "IntakeNutrients" })
        bad[nutrient].values["item_id"] = .string(UUID().uuidString)
        #expect(throws: HubError.invalidResponse) { try FoodSnapshotReader.meals(bad) }
    }
    @Test func snapshotReaderBenchmark() throws {
        guard ProcessInfo.processInfo.environment["PHH_FOOD_READER_BENCHMARK"] == "1" else { return }
        let rows = try syntheticMeals(200), clock = ContinuousClock(), start = clock.now
        for _ in 0..<5 { #expect(try FoodSnapshotReader.meals(rows).count == 200) }
        let elapsed = start.duration(to: clock.now), encoding = JSONEncoder(); encoding.outputFormatting = [.sortedKeys]
        let input = rows.map { row in var values = row.values; values["__table"] = .string(row.table); return values }
        let inputHash = SHA256.hash(data: try encoding.encode(input)).map { String(format: "%02x", $0) }.joined()
        let outputHash = SHA256.hash(data: try encoding.encode(FoodSnapshotReader.meals(rows))).map { String(format: "%02x", $0) }.joined()
        print("PHH_FOOD_READER_BENCHMARK input_sha256=\(inputHash) output_sha256=\(outputHash) meals=200 rows=\(rows.count) reads=5 duration=\(elapsed)")
    }
}
