import Foundation
import Testing
@testable import PHHHubCore

@Suite struct NumericEntryDefaultsTests {
    @Test func absenceIsNilAndUnitAndExerciseDoNotMix() throws {
        var value = NumericEntryDefaults()
        #expect(try value.previous(.quantity, reference: "food", unit: "個") == nil)
        try value.remember(.quantity, reference: "food", unit: "g", value: 100)
        #expect(try value.previous(.quantity, reference: "food", unit: "個") == nil)
        try value.remember(.trainingWeight, reference: "bench|standard", unit: "kg", value: 60)
        #expect(try value.previous(.trainingWeight, reference: "bench|paused", unit: "kg") == nil)
        let restored = try JSONDecoder().decode(NumericEntryDefaults.self, from: JSONEncoder().encode(value))
        #expect(restored == value); #expect(try restored.previous(.quantity, reference: "food", unit: "g") == 100)
    }
    @Test func knownZeroIsPreservedAndInvalidValueDoesNotOverwritePrior() throws {
        var value = NumericEntryDefaults()
        try value.remember(.trainingWeight, reference: "bodyweight", unit: "kg", value: 0)
        #expect(try value.previous(.trainingWeight, reference: "bodyweight", unit: "kg") == 0)
        #expect(throws: FoodFailure.invalidValue) { try value.remember(.trainingWeight, reference: "bodyweight", unit: "kg", value: .nan) }
        #expect(throws: FoodFailure.invalidValue) { try value.remember(.quantity, reference: "food", unit: "g", value: 0) }
        #expect(throws: FoodFailure.invalidValue) { try value.remember(.reps, reference: "bench", unit: "回", value: 2.5) }
        #expect(try value.previous(.trainingWeight, reference: "bodyweight", unit: "kg") == 0)
    }
}
