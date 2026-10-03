import Foundation
import CryptoKit
import Testing
@testable import PHHHubCore

@Suite @MainActor struct FoodCatalogIndexTests {
    func syntheticCatalog(_ count: Int) throws -> [LocalRow] {
        let fixture = try FoodHubTests().fixture()
        let template = fixture.page.changes.filter {
            ["FoodVersions", "FoodNutrients", "Categories", "Presets", "PresetItems"].contains($0.change.table_name)
        }.map { LocalRow(table: $0.change.table_name, values: $0.record) }
        let sourceIDs = Set(template.flatMap { $0.values.values.compactMap { $0.text }.filter { UUID(uuidString: $0) != nil } })
        return (0..<count).flatMap { copy in
            let ids = Dictionary(uniqueKeysWithValues: sourceIDs.sorted().enumerated().map { index, id in (id, String(format: "00000000-0000-4000-a000-%012d", 500_000 + copy * 100 + index)) })
            return template.map { row in
                LocalRow(table: row.table, values: row.values.mapValues { value -> Cell in
                    if let text = value.text, let replacement = ids[text] { return .string(replacement) }
                    return value
                })
            }
        }
    }
    @Test func multipleCatalogsKeepInputOrderReferencesAndRecordedNutrients() throws {
        let rows = Array(try syntheticCatalog(3).reversed()), catalog = try FoodCatalogReader.catalog(rows)
        #expect(catalog.versions.map(\.id) == rows.filter { $0.table == "FoodVersions" }.map(\.entityID))
        #expect(catalog.presets.map(\.id) == rows.filter { $0.table == "Presets" }.map(\.entityID))
        let template = try FoodCatalogReader.catalog(syntheticCatalog(1))
        for version in catalog.versions { #expect(version.nutrients == template.versions[0].nutrients) }
        for preset in catalog.presets {
            #expect(catalog.versions.contains(where: { $0.id == preset.components[0].versionID }))
            #expect(catalog.categories.contains(where: { $0.id == preset.categoryID }))
            #expect(try catalog.snapshot(preset.id)[0].nutrients == template.snapshot(template.presets[0].id)[0].nutrients)
        }
    }
    @Test func distinctVersionsAndPresetsKeepOwnNutrientsAndReferenceIdentity() throws {
        var rows = try syntheticCatalog(3)
        let roots = rows.filter { $0.table == "FoodVersions" }
        var expected: [String: Double] = [:]
        for (index, root) in roots.enumerated() {
            let nutrient = try #require(rows.firstIndex { $0.table == "FoodNutrients" && $0.values["food_version_id"]?.text == root.entityID && $0.values["nutrient_id"]?.text == "kcal" })
            let kcal = Double(200 + index); rows[nutrient].values["value"] = .number(kcal)
            expected[root.entityID] = kcal
        }
        let expectedReferences = Dictionary(uniqueKeysWithValues: rows.filter { $0.table == "PresetItems" }.map { ($0.values["preset_id"]!.text!, $0.values["food_version_id"]!.text!) })
        let catalog = try FoodCatalogReader.catalog(Array(rows.reversed()))
        for version in catalog.versions { #expect(version.nutrients.kcal == expected[version.id]) }
        for preset in catalog.presets {
            let component = try #require(preset.components.first)
            #expect(component.versionID == expectedReferences[preset.id])
            let recorded = try #require(catalog.snapshot(preset.id).first)
            #expect(recorded.versionID == component.versionID)
            #expect(recorded.nutrients.kcal == expected[component.versionID].map { $0 * component.factor })
        }
    }
    @Test func crossVersionNutrientAndMissingPresetReferenceRejectEntireCatalog() throws {
        let rows = try syntheticCatalog(2), versions = rows.filter { $0.table == "FoodVersions" }
        var bad = rows
        let nutrient = try #require(bad.firstIndex { $0.table == "FoodNutrients" && $0.values["food_version_id"]?.text == versions[1].entityID })
        bad[nutrient].values["food_version_id"] = .string(versions[0].entityID)
        #expect(throws: HubError.invalidResponse) { try FoodCatalogReader.catalog(bad) }
        bad = rows
        let component = try #require(bad.firstIndex { $0.table == "PresetItems" })
        bad[component].values["food_version_id"] = .string(UUID().uuidString)
        #expect(throws: HubError.invalidResponse) { try FoodCatalogReader.catalog(bad) }
    }
    @Test func catalogReaderBenchmark() throws {
        guard ProcessInfo.processInfo.environment["PHH_CATALOG_READER_BENCHMARK"] == "1" else { return }
        let rows = try syntheticCatalog(300), clock = ContinuousClock(), start = clock.now
        for _ in 0..<5 { #expect(try FoodCatalogReader.catalog(rows).versions.count == 300) }
        let elapsed = start.duration(to: clock.now), encoding = JSONEncoder(); encoding.outputFormatting = [.sortedKeys]
        let input = rows.map { row in var values = row.values; values["__table"] = .string(row.table); return values }
        let inputHash = SHA256.hash(data: try encoding.encode(input)).map { String(format: "%02x", $0) }.joined()
        let outputHash = SHA256.hash(data: try encoding.encode(FoodCatalogReader.catalog(rows))).map { String(format: "%02x", $0) }.joined()
        print("PHH_CATALOG_READER_BENCHMARK input_sha256=\(inputHash) output_sha256=\(outputHash) versions=300 presets=300 rows=\(rows.count) reads=5 duration=\(elapsed)")
    }
}
