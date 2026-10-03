import Foundation
import Testing
@testable import PHHHubCore

struct JapaneseSearchTests {
    @Test func kanaWidthReadingsAndPartialAliasesMatchWithoutChangingVoicing() throws {
        #expect(JapaneseSearch.matches("プロテイン", query: "ﾌﾟﾛﾃ"))
        #expect(JapaneseSearch.matches("全粒粉パン", query: "りゅうふん"))
        #expect(JapaneseSearch.matches("プロテイン", query: "ぷろていん"))
        #expect(JapaneseSearch.matches("ABC１２", query: "abc12"))
        #expect(JapaneseSearch.matches("いつもの朝食", query: "ちょう", aliases: ["いつものちょうしょく", "朝セット"]))
        #expect(!JapaneseSearch.matches("パン", query: "バン"))
        #expect(try JapaneseSearch.aliases(from: "朝セット、あさせっと,\nＢＲＥＡＫＦＡＳＴ,breakfast") == ["朝セット", "あさせっと", "ＢＲＥＡＫＦＡＳＴ"])
        #expect(throws: FoodFailure.invalidValue) { try JapaneseSearch.aliases(from: String(repeating: "長", count: 81)) }
    }
    @Test func searchStillHonorsHiddenCategoryAndPreset() throws {
        let v = try FoodVersion(name: "架空", unit: "個", source: "本人", nutrients: .init(kcal: nil, protein: nil, fat: nil, carbohydrate: nil))
        let category = try FoodCategory(name: "非表示", archived: true)
        let p = try FoodPreset(name: "朝食", components: [.init(versionID: v.id)])
        let hidden = try FoodPreset(name: "朝食2", categoryID: category.id, components: p.components)
        let archived = try FoodPreset(name: "朝食3", components: p.components, archived: true)
        let catalog = try FoodCatalog(versions: [v], categories: [category], presets: [p,hidden,archived])
        #expect(catalog.visiblePresets(query: "ちょう", aliases: [p.id:["ちょうしょく"], hidden.id:["ちょうしょく"], archived.id:["ちょうしょく"]]).map(\.id) == [p.id])
    }
}
