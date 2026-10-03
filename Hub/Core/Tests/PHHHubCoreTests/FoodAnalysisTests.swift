import Foundation
import Testing
@testable import PHHHubCore

struct FoodAnalysisTests {
    let json=#"{"items":[{"name":"架空皿","quantity":1,"unit":"皿","kcal":100,"protein_g":null,"fat_g":0,"carbohydrate_g":15,"source":"推定","confidence":"中"}],"uncertain_points":["量は推定"],"questions":["食べた量は？"]}"#
    @Test func estimateIsOnlyDraftAndZeroAndUnknownRemainDifferent() throws {
        let draft=try FoodDraft.fromAnalysisJSON(Data(json.utf8));#expect(draft.items[0].nutrients.protein==nil);#expect(draft.items[0].nutrients.fat==0);#expect(draft.items[0].confidence=="中");#expect(draft.uncertainty==["量は推定"])
        #expect(throws:FoodFailure.unresolvedQuestions){try draft.confirm(date:"2026-10-02",slot:"朝食")}
    }
    @Test func invalidNumbersSourcesAndConfidenceDoNotBecomeDraft() throws {
        for changed in [json.replacingOccurrences(of:"\"kcal\":100",with:"\"kcal\":-1"),json.replacingOccurrences(of:"\"quantity\":1",with:"\"quantity\":0"),json.replacingOccurrences(of:"\"推定\"",with:"\"不明な出典\""),json.replacingOccurrences(of:"\"confidence\":\"中\"",with:"\"confidence\":\"最高\"")] {#expect(throws:FoodFailure.invalidValue){try FoodDraft.fromAnalysisJSON(Data(changed.utf8))}}
    }
    @Test func nonFoodEmptyItemsAndPartialResponseCannotBeConfirmed() throws {
        let draft=try FoodDraft.fromAnalysisJSON(Data(#"{"items":[],"uncertain_points":[],"questions":["食事の写真ですか？"]}"#.utf8));var resolved=draft;resolved.answers["食事の写真ですか？"]="はい"
        #expect(throws:FoodFailure.invalidValue){try resolved.confirm(date:"2026-10-02",slot:"朝食")};#expect(throws:(any Error).self){try FoodDraft.fromAnalysisJSON(Data(json.dropLast().utf8))}
    }
}
