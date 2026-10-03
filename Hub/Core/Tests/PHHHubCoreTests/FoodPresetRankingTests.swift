import Testing
@testable import PHHHubCore

struct FoodPresetRankingTests {
    @Test func frequencySlotFixedOrderAndCancellationUseLatestMealOnly() throws {
        let version = try FoodVersion(name: "架空", unit: "個", source: "本人", nutrients: .init(kcal: 10, protein: nil, fat: nil, carbohydrate: nil))
        let a = try FoodPreset(name: "A", components: [.init(versionID: version.id)])
        let b = try FoodPreset(name: "B", components: a.components)
        let c = try FoodPreset(name: "C", components: a.components)
        let catalog = try FoodCatalog(versions: [version], presets: [a,b,c])
        func meal(_ preset: FoodPreset, _ slot: String) throws -> FoodMeal {
            try FoodMeal(date: "2026-10-03", slot: slot, items: catalog.snapshot(preset.id), presetID: preset.id, presetRevision: 1)
        }
        let dinner = try meal(a,"夕食"), breakfast = try meal(b,"朝食"), canceled = try meal(c,"朝食")
        let meals = try [dinner, meal(a,"夕食"), breakfast, breakfast, canceled, canceled.edited(remove: true)]
        #expect(FoodPresetRanking.order([a,b,c], meals: meals, slot: "朝食", mode: .frequent).map(\.id) == [a.id,b.id,c.id])
        #expect(FoodPresetRanking.order([a,b,c], meals: meals, slot: "朝食", mode: .mealTime).map(\.id) == [b.id,a.id,c.id])
        #expect(FoodPresetRanking.order([a,b,c], meals: meals, slot: "朝食", mode: .mealTime, fixedOrder: [c.id,a.id]).map(\.id) == [c.id,a.id,b.id])
        #expect(FoodPresetRanking.order([a,b], meals: [], slot: "朝食", mode: .frequent, fixedOrder: [c.id]).map(\.id) == [a.id,b.id])
    }
}
