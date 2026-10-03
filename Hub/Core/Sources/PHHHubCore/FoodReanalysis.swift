import Foundation

public enum FoodReanalysisFailure: Error, LocalizedError {
  case inputTooLong
  public var errorDescription: String? { "補足・回答・明細を合わせて8,000文字以内にしてください。現在の入力は残っています。" }
}

/// 再解析へ渡す資料。未回答を補完せず、確認前の数値と本人の回答を区別します。
public enum FoodReanalysis {
  private struct Answer: Encodable { let question: String; let answer: String }
  private struct Item: Encodable {
    let name: String; let quantity: Double; let unit: String
    let source: String
    let nutrients: FoodNutrients
  }
  private struct Context: Encodable { let items: [Item]; let answers: [Answer] }

  public static func note(_ note: String, previous: FoodDraft?) throws -> String {
    guard note.count <= 8000 else { throw FoodReanalysisFailure.inputTooLong }
    guard let previous else { return note }
    guard previous.items.count <= 50, previous.questions.count <= 30 else { throw FoodFailure.invalidValue }
    for item in previous.items { try item.validate() }
    let answers = try previous.questions.compactMap { question -> Answer? in
      let answer = (previous.answers[question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !answer.isEmpty else { return nil }
      try FoodRules.text(question, limit: 8000); try FoodRules.text(answer, limit: 8000)
      return Answer(question: question, answer: answer)
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(Context(items: previous.items.map { Item(name: $0.name, quantity: $0.quantity, unit: $0.unit, source: $0.source, nutrients: $0.nutrients) }, answers: answers))
    guard let json = String(data: data, encoding: .utf8) else { throw FoodFailure.invalidValue }
    let text = note + "\n\n再解析前の確認画面（手直しを含む未確定の明細）と、本人の回答：\n" + json
    guard text.count <= 8000 else { throw FoodReanalysisFailure.inputTooLong }
    return text
  }

  /// 同じ質問だけ回答を引き継ぎ、新しい質問には回答済みの印を付けません。
  public static func carryingAnswers(_ next: FoodDraft, from previous: FoodDraft?) -> FoodDraft {
    var result = next
    for question in next.questions {
      if let answer = previous?.answers[question], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        result.answers[question] = answer
      }
    }
    return result
  }
}
