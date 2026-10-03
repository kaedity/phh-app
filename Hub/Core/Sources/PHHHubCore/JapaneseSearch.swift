import Foundation

public enum JapaneseSearch {
    public static func normalized(_ text: String) -> String {
        let width = text.precomposedStringWithCanonicalMapping.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
        return (width.applyingTransform(.hiraganaToKatakana, reverse: false) ?? width)
            .filter { !$0.isWhitespace }.precomposedStringWithCanonicalMapping
    }
    private static let readings = [
        "全粒粉パン": ["ぜんりゅうふんぱん"], "ゆで卵": ["ゆでたまご", "茹で卵"],
        "野菜スープ": ["やさいすーぷ"], "白米": ["はくまい", "ごはん", "ご飯"],
        "プロテイン": ["ぷろていん", "プロテ"]
    ]
    public static func matches(_ name: String, query: String, aliases: [String] = []) -> Bool {
        let key = normalized(query)
        guard !key.isEmpty else { return true }
        let terms = [name] + aliases + (readings[name] ?? [])
        return terms.contains { normalized($0).contains(key) }
    }
    public static func aliases(from text: String) throws -> [String] {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: ",、\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard parts.count <= 50 else { throw FoodFailure.invalidValue }
        var seen = Set<String>(), result: [String] = []
        for part in parts {
            try FoodRules.text(part, limit: 80)
            if seen.insert(normalized(part)).inserted { result.append(part) }
        }
        return result
    }
}
