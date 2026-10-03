import Foundation

/// 表示だけの投影。正本・Outbox・操作IDは変更しません。
public struct FoodDayPresentation: Equatable, Sendable {
    public let date: String
    public let meals: [FoodMeal]
    public let pending: [FoodPendingOperation]
    public let reviewIDs: [String]
    public let confirmedTotal: FoodTotal
    public let localTotal: FoodTotal

    public init(date: String, snapshot: FoodScreenSnapshot) throws {
        try FoodRules.date(date)
        for meal in snapshot.confirmed { try meal.validate() }
        for operation in snapshot.pending { try operation.validate() }
        guard Set(snapshot.confirmed.map(\.id)).count == snapshot.confirmed.count,
              Set(snapshot.pending.map(\.id)).count == snapshot.pending.count,
              Set(snapshot.pending.map { $0.meal.id }).count == snapshot.pending.count
        else { throw FoodFailure.duplicateID }
        self.date = date
        confirmedTotal = .day(date, meals: snapshot.confirmed)
        var projected = Dictionary(uniqueKeysWithValues: snapshot.confirmed.map { ($0.id, $0) })
        var reviews: [String] = []
        pending = snapshot.pending.filter { operation in
            operation.meal.date == date || snapshot.confirmed.contains { $0.id == operation.meal.id && $0.date == date }
        }
        for operation in snapshot.pending {
            let previous = projected[operation.meal.id]
            guard operation.state != .needsReview,
                  (previous?.revision ?? 0) == operation.expectedRevision else {
                if pending.contains(where: { $0.id == operation.id }) { reviews.append(operation.id) }
                continue
            }
            // 送信済みの追加の取消は、同じIDの確定→取消の順で送ります。
            if operation.undoRequested && operation.expectedRevision == 0 {
                projected.removeValue(forKey: operation.meal.id)
            } else if operation.undoRequested, let restoration = operation.undoReplacement {
                projected[operation.meal.id] = try FoodMeal(id: restoration.id, revision: operation.expectedRevision,
                    date: restoration.date, slot: restoration.slot, items: restoration.items, removed: restoration.removed,
                    presetID: restoration.presetID, presetRevision: restoration.presetRevision)
            } else {
                projected[operation.meal.id] = operation.meal
            }
        }
        reviewIDs = reviews
        meals = projected.values.filter { !$0.removed && $0.date == date }.sorted { $0.id < $1.id }
        localTotal = .day(date, meals: meals)
    }
}

extension FoodTotal {
    /// 予定/服用確認の写しだけを加え、不明な栄養値の件数も保持します。
    public func includingSupplements(_ days: [SupplementDay], date: String) throws -> FoodTotal {
        try FoodRules.date(date)
        guard Set(days.map(\.id)).count == days.count else { throw FoodFailure.duplicateID }
        var known = self.known, missing = self.missing, counts = self.knownCount
        for day in days where day.date == date && day.isCounted {
            try day.validate()
            for nutrient in FoodNutrient.allCases {
                let value = day.nutrients.first { $0.nutrientID == nutrient.rawValue }?.value
                if let value { known[nutrient, default: 0] += value; counts[nutrient,default:0] += 1 }
                else { missing[nutrient, default: 0] += 1 }
            }
        }
        return .init(known: known, missing: missing, knownCount: counts)
    }
    public func goalValues() throws -> GoalValues {
        func value(_ nutrient: FoodNutrient) -> Double? {
            (missing[nutrient] ?? 0) > 0 ? nil : known[nutrient]
        }
        return try .init(kcal: value(.kcal), protein: value(.protein), fat: value(.fat), carbohydrate: value(.carbohydrate))
    }
}
