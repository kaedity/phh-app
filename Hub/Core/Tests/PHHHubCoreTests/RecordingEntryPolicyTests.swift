import Foundation
import Testing
@testable import PHHHubCore

struct RecordingEntryPolicyTests {
    @Test func unusualEntryUsesEachUnitsOwnThreshold() {
        #expect(!UnusualNumericEntry.needsConfirmation(.quantity, value: 4.99, baseline: 1))
        #expect(UnusualNumericEntry.needsConfirmation(.quantity, value: 5, baseline: 1))
        #expect(UnusualNumericEntry.needsConfirmation(.bodyWeight, value: 67, baseline: 70))
        #expect(!UnusualNumericEntry.needsConfirmation(.bodyWeight, value: 72.99, baseline: 70))
        #expect(UnusualNumericEntry.needsConfirmation(.trainingWeight, value: 70, baseline: 100))
        #expect(UnusualNumericEntry.needsConfirmation(.trainingWeight, value: 130, baseline: 100))
        #expect(!UnusualNumericEntry.needsConfirmation(.trainingWeight, value: 0, baseline: 0))
        #expect(!UnusualNumericEntry.needsConfirmation(.quantity, value: 5, baseline: nil))
    }
    @Test func midnightCutoffHonorsExplicitDayAndJSTBoundary() throws {
        let parse = ISO8601DateFormatter()
        let policy = try RecordingDayPolicy()
        #expect(try policy.recordingDay(at: parse.date(from: "2026-10-02T18:59:59Z")!) == "2026-10-02")
        #expect(try policy.recordingDay(at: parse.date(from: "2026-10-02T19:00:00Z")!) == "2026-10-03")
        #expect(try policy.recordingDay(at: parse.date(from: "2026-10-02T15:00:00Z")!, explicitDay: "2026-09-30") == "2026-09-30")
        #expect(try RecordingDayPolicy(cutoffMinutes: 0).recordingDay(at: parse.date(from: "2026-12-31T15:00:00Z")!) == "2027-01-01")
        #expect(throws: FoodFailure.self) { try RecordingDayPolicy(cutoffMinutes: 1440) }
        #expect(throws: FoodFailure.self) { try policy.recordingDay(at: Date(), explicitDay: "2026-02-30") }
    }
    @Test func mealWarningUsesFrozenFoodVersionAndUnknownBaseUsesRecordedAmount() throws {
        let version = try FoodVersion(name: "架空の食品", quantity: 1, unit: "個", source: "本人", nutrients: .init(kcal: 10, protein: nil, fat: nil, carbohydrate: nil))
        let catalog = try FoodCatalog(versions: [version])
        let item = try FoodItemSnapshot(name: version.name, quantity: 3, unit: version.unit, source: version.source, versionID: version.id, nutrients: .init(kcal: 30, protein: nil, fat: nil, carbohydrate: nil))
        let meal = try FoodMeal(date: "2026-10-03", slot: "朝食", items: [item])
        #expect(UnusualNumericEntry.unusualMealQuantity(meal, factor: 2, catalog: catalog))
        #expect(!UnusualNumericEntry.unusualMealQuantity(meal, factor: 2, catalog: nil))
    }
}
