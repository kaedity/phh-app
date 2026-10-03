import Foundation
import Testing
@testable import PHHHubCore

struct FoodPhotoBatchTests {
    @Test func sameMealPhotosKeepOrderAndRespectCountAndByteLimits() throws {
        let a=Data([1,2]), b=Data([3,4])
        #expect(try FoodPhotoBatch([a,b]).jpegs == [a,b])
        #expect(try FoodPhotoBatch([]).jpegs.isEmpty)
        #expect(throws: FoodFailure.invalidValue) { try FoodPhotoBatch(Array(repeating:a,count:5)) }
        #expect(throws: FoodFailure.invalidValue) { try FoodPhotoBatch([Data()]) }
        #expect(throws: FoodFailure.invalidValue) { try FoodPhotoBatch([Data(repeating:0,count:10_000_001)]) }
        #expect(throws: FoodFailure.invalidValue) { try FoodPhotoBatch(Array(repeating:Data(repeating:0,count:7_000_000),count:3)) }
    }
}
