import Foundation

public struct NumericEntryDefaults: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable { case bodyWeight, trainingWeight, reps, quantity }
    private var values: [String: Double] = [:]
    public init() {}
    private func key(_ field: Field, reference: String, unit: String) throws -> String {
        guard !reference.isEmpty, reference.utf8.count <= 200, !unit.isEmpty, unit.utf8.count <= 40 else { throw FoodFailure.invalidValue }
        return field.rawValue + ":" + Data(reference.utf8).base64EncodedString() + ":" + Data(unit.utf8).base64EncodedString()
    }
    public func previous(_ field: Field, reference: String, unit: String) throws -> Double? {
        let value = values[try key(field, reference: reference, unit: unit)]
        guard value.map({ valid(field, value: $0) }) ?? true else { throw FoodFailure.invalidValue }
        return value
    }
    private func valid(_ field: Field, value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1_000_000 &&
            (field != .quantity && field != .bodyWeight || value > 0) &&
            (field != .reps || value >= 1 && value.rounded() == value)
    }
    public mutating func remember(_ field: Field, reference: String, unit: String, value: Double) throws {
        guard valid(field, value: value) else { throw FoodFailure.invalidValue }
        let key = try key(field, reference: reference, unit: unit)
        guard values[key] != nil || values.count < 500 else { throw FoodFailure.invalidValue }
        values[key] = value
    }
}
