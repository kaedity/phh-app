import Foundation

public enum FoodPresetRanking {
    public enum Mode: String, Codable, CaseIterable, Sendable { case frequent, mealTime }
    public static func order(_ presets: [FoodPreset], meals: [FoodMeal], slot: String, mode: Mode, fixedOrder: [String] = []) -> [FoodPreset] {
        var latest: [String: FoodMeal] = [:]
        for meal in meals where latest[meal.id].map({ $0.revision < meal.revision }) ?? true { latest[meal.id] = meal }
        let counted = latest.values.filter { !$0.removed }
        let all = Dictionary(grouping: counted.compactMap(\.presetID), by: { $0 }).mapValues(\.count)
        let inSlot = Dictionary(grouping: counted.filter { $0.slot == slot }.compactMap(\.presetID), by: { $0 }).mapValues(\.count)
        var fixed: [String: Int] = [:]
        for (index, id) in fixedOrder.enumerated() where fixed[id] == nil { fixed[id] = index }
        return presets.sorted { left, right in
            let l = fixed[left.id] ?? Int.max, r = fixed[right.id] ?? Int.max
            if l != r { return l < r }
            if mode == .mealTime, inSlot[left.id, default: 0] != inSlot[right.id, default: 0] {
                return inSlot[left.id, default: 0] > inSlot[right.id, default: 0]
            }
            if all[left.id, default: 0] != all[right.id, default: 0] { return all[left.id, default: 0] > all[right.id, default: 0] }
            let names = left.name.localizedStandardCompare(right.name)
            return names == .orderedSame ? left.id < right.id : names == .orderedAscending
        }
    }
}
