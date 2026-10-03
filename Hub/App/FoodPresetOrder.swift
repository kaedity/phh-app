import PHHHubCore
import SwiftUI

enum PresetDisplayPreferences {
    static var mode: FoodPresetRanking.Mode {
        get { FoodPresetRanking.Mode(rawValue: RecordingPreferences.defaults.string(forKey: "preset-display-mode") ?? "") ?? .mealTime }
        set { RecordingPreferences.defaults.set(newValue.rawValue, forKey: "preset-display-mode") }
    }
    static var fixedOrder: [String] {
        get { RecordingPreferences.defaults.stringArray(forKey: "preset-fixed-order") ?? [] }
        set { RecordingPreferences.defaults.set(newValue, forKey: "preset-fixed-order") }
    }
}

struct FoodPresetOrderPage: View {
    let catalog: FoodCatalog
    @State private var presets: [FoodPreset]
    @State private var fixed: Bool
    init(catalog: FoodCatalog) {
        self.catalog = catalog
        _presets = State(initialValue: FoodPresetRanking.order(catalog.visiblePresets(), meals: [], slot: "朝食", mode: .frequent, fixedOrder: PresetDisplayPreferences.fixedOrder))
        _fixed = State(initialValue: !PresetDisplayPreferences.fixedOrder.isEmpty)
    }
    var body: some View {
        List {
            Section {
                ForEach(presets) { Text($0.name) }
                    .onMove { from, to in presets.move(fromOffsets: from, toOffset: to); fix() }
            } header: { Text("固定する並び") } footer: { Text("編集で行を動かすと、この端末の表示順を固定します。食品の栄養値やGoogleの記録は変更しません。") }
            Section {
                Button("この順で固定") { fix() }.disabled(presets.isEmpty)
                Button("自動の並びに戻す") { PresetDisplayPreferences.fixedOrder=[]; fixed=false }
                Text(fixed ? "固定した並びを優先します" : "食事画面で選んだ自動の並びを使います").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("プリセットの並び").toolbar { EditButton() }
    }
    private func fix() { PresetDisplayPreferences.fixedOrder=presets.map(\.id); fixed=true }
}
