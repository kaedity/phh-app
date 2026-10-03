import Foundation

public struct FoodPhotoBatch: Sendable, Equatable {
    public let jpegs: [Data]
    public init(_ jpegs: [Data]) throws {
        guard jpegs.count <= 4, jpegs.allSatisfy({ !$0.isEmpty && $0.count <= 10_000_000 }),
              jpegs.reduce(0, { $0 + $1.count }) <= 20_000_000 else { throw FoodFailure.invalidValue }
        self.jpegs = jpegs
    }
}
