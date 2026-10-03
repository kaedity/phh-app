import Foundation

public extension HubOperation {
  init(foodVersion: FoodVersion) { self.init(action:"save_food_version",entityID:foodVersion.id);self.foodVersion=foodVersion }
  init(foodCategory: FoodCategory, expectedRevision: Int) { self.init(action:"save_food_category",entityID:foodCategory.id,revision:expectedRevision);self.foodCategory=foodCategory }
  init(foodPreset: FoodPreset) { self.init(action:"save_food_preset",entityID:foodPreset.id,revision:foodPreset.revision-1);self.foodPreset=foodPreset }
  internal func validateFoodCatalog() throws {
    guard payload == nil,foodMeal == nil,trainingCycle == nil,trainingSession == nil else { throw HubError.invalidOperation }
    do {
      switch action {
      case "save_food_version":
        guard let foodVersion,foodCategory == nil,foodPreset == nil,entity_id==foodVersion.id,expected_revision==0 else { throw HubError.invalidOperation }
        try foodVersion.validate()
      case "save_food_category":
        guard let foodCategory,foodVersion == nil,foodPreset == nil,entity_id==foodCategory.id else { throw HubError.invalidOperation }
        try FoodRules.id(foodCategory.id);try FoodRules.text(foodCategory.name)
      case "save_food_preset":
        guard let foodPreset,foodVersion == nil,foodCategory == nil,entity_id==foodPreset.id,foodPreset.revision==expected_revision+1 else { throw HubError.invalidOperation }
        try foodPreset.validate()
        guard Set(foodPreset.components.map(\.versionID)).count==foodPreset.components.count else { throw HubError.invalidOperation }
      default: throw HubError.invalidOperation
      }
    } catch { throw HubError.invalidOperation }
  }
}
