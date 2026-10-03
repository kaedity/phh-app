import Foundation

/// 取り消し対象と戻す写し。本人が5秒以内に選んだ後は、通信が遅れても保持します。
public struct FoodUndoChange: Codable, Equatable, Sendable {
    public let operationID: String, undoID: String
    public let before: FoodMeal?, after: FoodMeal
    public let expiresAt: Date
    public init(operationID: String, before: FoodMeal?, after: FoodMeal, at: Date = .now, undoID: String = UUID().uuidString) throws {
        self.operationID=operationID; self.undoID=undoID; self.before=before; self.after=after; expiresAt=at.addingTimeInterval(5)
        try validate()
    }
    public func validate() throws {
        try FoodRules.id(operationID); try FoodRules.id(undoID); try after.validate()
        guard operationID != undoID, expiresAt.timeIntervalSince1970.isFinite else { throw FoodFailure.invalidValue }
        if let before {
            try before.validate()
            guard before.id == after.id, before.revision+1 == after.revision else { throw FoodFailure.revisionConflict }
        } else { guard after.revision == 1, !after.removed else { throw FoodFailure.invalidValue } }
    }
    public func available(at: Date = .now) -> Bool { at < expiresAt }
    public func restoration(current: FoodMeal) throws -> FoodMeal {
        try validate(); guard current == after else { throw FoodFailure.revisionConflict }
        guard let before else { return try current.edited(remove: true) }
        return try FoodMeal(id: current.id, revision: current.revision+1, date: before.date, slot: before.slot,
            items: before.items, removed: before.removed, presetID: before.presetID, presetRevision: before.presetRevision)
    }
}
