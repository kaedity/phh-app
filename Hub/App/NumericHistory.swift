import Foundation
import PHHHubCore

/// 入力の前回値は端末内だけ。合成入口は別のUserDefaultsを使います。
enum NumericHistory {
    #if DEBUG
    static func resetSyntheticIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--numeric-reset"), args.contains(where: { $0.hasPrefix("--p") && $0.hasSuffix("-preview") }) else { return }
        defaults.removeObject(forKey: "numeric-entry-defaults")
    }
    #endif
    private static var defaults: UserDefaults {
        let preview = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--p") && $0.hasSuffix("-preview") }
        return preview ? UserDefaults(suiteName: "jp.personalhealthhub.numeric.synthetic")! : .standard
    }
    private static var model: NumericEntryDefaults {
        guard let bytes = defaults.data(forKey: "numeric-entry-defaults"), let value = try? JSONDecoder().decode(NumericEntryDefaults.self, from: bytes) else { return .init() }
        return value
    }
    static func quantity(unit: String) -> String {
        (try? model.previous(.quantity, reference: "food-entry", unit: unit)).map { String($0) } ?? ""
    }
    static func rememberQuantity(_ value: Double, unit: String) {
        var copy = model
        guard (try? copy.remember(.quantity, reference: "food-entry", unit: unit, value: value)) != nil,
            let bytes = try? JSONEncoder().encode(copy) else { return }
        defaults.set(bytes, forKey: "numeric-entry-defaults")
    }
}
