import PHHHubCore
import SwiftUI

enum FoodSearchPreferences {
    static var aliases: [String: [String]] {
        guard let data=RecordingPreferences.defaults.data(forKey: "food-search-aliases"),
              let value=try? JSONDecoder().decode([String:[String]].self, from: data), value.count<=500 else { return [:] }
        return value.filter { $0.value.count<=50 && $0.value.allSatisfy { !$0.isEmpty && $0.count<=80 } }
    }
    static func prepared(_ text: String, for id: String) throws -> Data {
        var values=aliases
        let list=try JapaneseSearch.aliases(from: text)
        guard values[id] != nil || values.count<500 else { throw FoodFailure.invalidValue }
        values[id]=list
        return try JSONEncoder().encode(values)
    }
    static func save(_ data: Data) { RecordingPreferences.defaults.set(data, forKey: "food-search-aliases") }
}
