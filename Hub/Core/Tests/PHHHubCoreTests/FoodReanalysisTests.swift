import Foundation
import Testing
@testable import PHHHubCore

struct FoodReanalysisTests {
  @Test func contextIncludesEditedAmountAndOnlyExplicitAnswers() throws {
    let item = try FoodItemSnapshot(name: "架空の食事", quantity: 0.5, unit: "皿", source: "本人", nutrients: .init(kcal: 210, protein: nil, fat: 0, carbohydrate: nil))
    let draft = FoodDraft(items: [item], questions: ["食べた量は？", "油は？"], answers: ["食べた量は？": " 半分 ", "油は？": "  ", "別の質問": "不採用"])
    let text = try FoodReanalysis.note("ソースを残した", previous: draft)
    let json = Data(text.components(separatedBy: "\n").last!.utf8)
    let context = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    let items = try #require(context["items"] as? [[String: Any]])
    #expect(items[0]["quantity"] as? Double == 0.5)
    #expect(items[0]["source"] as? String == "本人")
    let nutrients = try #require(items[0]["nutrients"] as? [String: Any])
    #expect(nutrients["kcal"] as? Double == 210); #expect(nutrients["fat"] as? Double == 0)
    #expect(nutrients["protein"] == nil)
    let answers = try #require(context["answers"] as? [[String: String]])
    #expect(answers == [["question": "食べた量は？", "answer": "半分"]])
    #expect(text.hasPrefix("ソースを残した")); #expect(draft.items[0].nutrients.kcal == 210)
  }
  @Test func oversizedCombinedContextFailsWithoutTruncatingAnswers() throws {
    let draft = FoodDraft(items: [], questions: ["量は？"], answers: ["量は？": String(repeating: "あ", count: 7900)])
    #expect(throws: FoodReanalysisFailure.inputTooLong) { try FoodReanalysis.note(String(repeating: "い", count: 100), previous: draft) }
    #expect(try FoodReanalysis.note("本文", previous: nil) == "本文")
  }
  @Test func matchingAnswersCarryAndNewQuestionsRequireResolution() throws {
    let previous = FoodDraft(items: [], questions: ["量は？", "油は？"], answers: ["量は？": "半分", "油は？": " "])
    let next = FoodDraft(items: [], questions: ["量は？", "油は？", "商品名は？"])
    let carried = FoodReanalysis.carryingAnswers(next, from: previous)
    #expect(carried.answers == ["量は？": "半分"])
    #expect(throws: FoodFailure.unresolvedQuestions) { try carried.confirm(date: "2026-10-04", slot: "昼食") }
    #expect(previous.answers["量は？"] == "半分")
  }
}
