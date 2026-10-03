import Foundation

/// 端末保存が成功した後の表示読取失敗を、保存失敗として再送させません。
@MainActor public enum FoodCommit {
    public struct SavedMeal {
        public let operationID: String
        public let mealID: String
        public let snapshot: FoodScreenSnapshot?
    }
    public static func confirm(_ draft: FoodDraft, date: String, slot: String, store: any FoodEditingStore, identity: String? = nil) throws -> SavedMeal {
        let meal = try draft.confirm(date: date, slot: slot, id: identity ?? UUID().uuidString)
        let id = try store.enqueue(meal, operationID: identity ?? UUID().uuidString)
        return SavedMeal(operationID: id, mealID: meal.id, snapshot: try? store.snapshot())
    }
    public static func saveCatalog(_ catalog: FoodCatalog, store: any FoodEditingStore) throws -> FoodScreenSnapshot? {
        try store.saveCatalog(catalog)
        return try? store.snapshot()
    }
}
