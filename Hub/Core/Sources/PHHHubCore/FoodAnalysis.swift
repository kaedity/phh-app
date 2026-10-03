import Foundation

extension FoodDraft {
  /// 完了した解析応答の境界。不正な数値・出典・信頼度は下書きにも採用しません。
  public static func fromAnalysisJSON(_ data: Data) throws -> Self {
    struct Response: Decodable {
      struct Item: Decodable {
        let name: String, quantity: Double, unit: String, kcal: Double?, protein_g: Double?,
          fat_g: Double?, carbohydrate_g: Double?, source: String, confidence: String
      }
      let items: [Item], uncertain_points: [String], questions: [String]
    }
    guard data.count <= 256_000 else { throw FoodFailure.invalidValue }
    let response = try JSONDecoder().decode(Response.self, from: data)
    guard response.items.count <= 50, response.questions.count <= 30,
      response.uncertain_points.count <= 30,
      Set(response.questions).count == response.questions.count
    else { throw FoodFailure.invalidValue }
    for text in response.questions + response.uncertain_points {
      try FoodRules.text(text, limit: 2000)
    }
    let items = try response.items.map { i in
      guard ["推定", "商品表示"].contains(i.source) else { throw FoodFailure.invalidValue }
      return try FoodItemSnapshot(
        name: i.name, quantity: i.quantity, unit: i.unit, source: i.source,
        confidence: i.confidence,
        nutrients: .init(
          kcal: i.kcal, protein: i.protein_g, fat: i.fat_g, carbohydrate: i.carbohydrate_g))
    }
    // 食品を認識できなかった場合は質問だけを表示し、確認保存はFoodMealの検証で拒否します。
    return .init(
      items: items, uncertainty: response.uncertain_points, questions: response.questions)
  }
}
