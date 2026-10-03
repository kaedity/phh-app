import Foundation

public enum UnusualNumericEntry {
    public static func unusualMealQuantity(_ meal: FoodMeal, factor: Double, catalog: FoodCatalog?) -> Bool {
        meal.items.contains { item in
            let version = catalog?.versions.first { $0.id == item.versionID && $0.unit == item.unit }
            return needsConfirmation(.quantity, value: item.quantity * factor, baseline: version?.quantity ?? item.quantity)
        }
    }
    // 呼出側で通常の入力検証を済ませてから、確認の要否を調べます。
    public static func needsConfirmation(_ field: NumericEntryDefaults.Field, value: Double, baseline: Double?) -> Bool {
        guard value.isFinite, value >= 0, let baseline, baseline.isFinite, baseline > 0 else { return false }
        switch field {
        case .bodyWeight: return abs(value - baseline) >= 3
        case .quantity: return value / baseline >= 5
        case .trainingWeight: return abs(value - baseline) / baseline >= 0.3
        case .reps: return false
        }
    }
}
